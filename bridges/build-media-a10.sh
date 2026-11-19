#!/bin/sh
# A10 的媒体与网络组：客体侧的 netd 客户端、音频 HAL，以及媒体服务的七件。
#
#   sh bridges/build-media-a10.sh
#
# 产物（bridges/media/lib 与 bridges/media/bin）：
#   libnetd_client.so            客体里 libnetd_client 的替换件，把 DNS 与 socket 打到宿主
#   audio.primary.a10vm.so       ro.hardware.audio=primary.a10vm 时 hw_get_module 加载的音频 HAL
#   libresourcemanagerservice.so 媒体资源管理服务
#   libstagefright_httplive.so   HTTP Live 播放路径
#   libmediaplayerservice.so     mediaserver 的播放服务
#   media / media-drm / drm / media-omx   四支可执行文件
#
# 七件要 AOSP 10 的接口头：HIDL 由 hidl-gen 生成，AIDL 由 aidl 生成，两者都不是交叉编译出来的，
# 是宿主编出来的（见 runtime/build-media-tools.sh）。生成好的头落在 runtime/build/media/generated，
# 本脚本只消费它，不重新生成。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
set +u
. "$MODULE/vendor/binder/compile.sh"

NATIVE="$MODULE/vendor/native"
GOUT="$OUT/media"
GOBJ="$GOUT/obj"
UP="$RT/upstream"
AV="$UP/frameworks/av"
FN="$UP/frameworks/native"
SYSMI="$UP/system/media"
LIBHIDL="$UP/system/libhidl"
GEN="$MODULE/runtime/build/media/generated/include"
AIDLGEN="$MODULE/runtime/build/media/generated/aidl"
DEPS="$MODULE/runtime/build/media/lib"
mkdir -p "$GOUT/lib" "$GOUT/bin" "$GOBJ"

for required in "$NATIVE/HostNetdClient.cpp" "$NATIVE/HostConnect.cpp" \
                 "$NATIVE/HostAudioHal.cpp" "$NATIVE/HostAudioPcm.cpp" \
                 "$UP/system/netd/include/FwmarkCommand.h" \
                 "$UP/system/media/audio/include/system/audio.h" ; do
    if [ ! -f "$required" ]; then
        printf 'media: 缺 %s\n' "$required" >&2
        printf 'media: 上游靠 python runtime/fetch-a10-sources.py\n' >&2
        exit 1
    fi
done

crt_so
crt_pie
link_guest() {
    name=$1
    shift
    ld.lld -shared -soname "$name" -z now -z relro -z max-page-size=4096 \
        --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL --as-needed \
        "$OUT/obj/crt/crtbegin_so.o" "$@" \
        "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC" "$BUILTINS" \
        "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/$name"
}

platform_compile "$NATIVE/HostNetdClient.cpp" "$GOBJ/host-netd.o" -I"$NATIVE"
platform_compile "$NATIVE/HostConnect.cpp" "$GOBJ/host-connect.o" -I"$NATIVE" \
    -I"$UP/system/netd/include"
link_guest libnetd_client.so "$GOBJ/host-netd.o" "$GOBJ/host-connect.o"

platform_compile "$NATIVE/HostAudioHal.cpp" "$GOBJ/host-audio.o" -I"$NATIVE" \
    -I"$UP/hardware/libhardware/include" \
    -I"$UP/system/media/audio/include" -I"$UP/system/media/audio/include/system" \
    -I"$UP/frameworks/native/libs/nativebase/include" \
    -I"$UP/system/core/libsystem/include"
platform_compile "$NATIVE/HostAudioPcm.cpp" "$GOBJ/host-audio-pcm.o" -I"$NATIVE" \
    -I"$UP/system/media/audio/include" -I"$UP/system/media/audio/include/system" \
    -I"$UP/system/core/libsystem/include"
link_guest audio.primary.a10vm.so "$GOBJ/host-audio.o" "$GOBJ/host-audio-pcm.o"

# ---------------------------------------------------------------- 媒体七件
# 接口头与镜像里的 ARM64 依赖必须在位，缺了就停，不去找替代。
for required in "$GEN/android/hardware/media/omx/1.0/IOmx.h" \
                 "$AIDLGEN/android/hardware/ICameraService.cpp" \
                 "$DEPS/libstagefright.so" "$DEPS/libmedia.so" "$DEPS/libgui.so" ; do
    if [ ! -f "$required" ]; then
        printf 'media: 缺 %s\n' "$required" >&2
        printf 'media: 接口头靠 runtime/build-media-tools.sh，依赖靠 python runtime/media-deps.py\n' >&2
        exit 1
    fi
done

# 编译参数照 guest-runtime/build-media.sh 的 media_compile，include 换成本仓库的落位。
media_compile() {
    input=$1
    object=$2
    shift 2
    # 这里不能用 platform_compile：它带 -D__ANDROID_VNDK__，而媒体服务要读 android/IMediaResourceMonitor.h
    # 这类"只对系统可见"的头，VNDK 一开就被拦成 "This header is not visible to vendors"。
    # 参数照 build-media.sh 的 media_compile，用通用 compile 叠自己的 define 与 include。
    compile "$input" "$object" -std=gnu++17 -fno-exceptions -fno-rtti -fno-sized-deallocation \
        -DA10VM_PRIVATE_RUNTIME -D_FILE_OFFSET_BITS=64 -DLOG_NDEBUG=1 \
        -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484 -Wno-deprecated-declarations \
        -D__ANDROID_APEX__ -Wno-multichar \
        -I"$UP/system/core/base/include" -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libcutils/include" -I"$UP/system/core/libutils/include" \
        -I"$UP/system/core/libsystem/include" -I"$UP/system/core/libprocessgroup/include" \
        -I"$UP/system/core/libbacktrace/include" -I"$UP/system/core/include" \
        -I"$FN/libs/binderthreadstate/include" -I"$UP/system/libhwbinder/include" \
        -I"$GEN" -I"$AIDLGEN" -I"$AV/include" -I"$FN/include" \
        -I"$FN/headers/media_plugin/media/openmax" -I"$FN/headers/media_plugin" \
        -I"$FN/libs/gui/include" \
        -I"$FN/libs/ui/include" -I"$FN/libs/nativewindow/include" \
        -I"$FN/libs/nativebase/include" -I"$FN/libs/arect/include" \
        -I"$FN/libs/binder/include" -I"$FN/libs/math/include" \
        -I"$UP/hardware/libhardware/include" -I"$UP/system/core/libsync/include" \
        -I"$FN/opengl/include" \
        -I"$SYSMI/audio/include" -I"$SYSMI/audio_utils/include" \
        -I"$SYSMI/camera/include" -I"$SYSMI/private/camera/include" \
        -I"$LIBHIDL/base/include" -I"$LIBHIDL/transport/include" \
        -I"$LIBHIDL/transport/token/1.0/utils/include" -I"$LIBHIDL/libhidlmemory/include" \
        -I"$UP/system/libfmq/include" -I"$UP/system/netd/include" \
        -I"$UP/external/boringssl/src/include" -I"$UP/external/selinux/libselinux/include" \
        -I"$UP/external/icu/libandroidicu/include" -I"$UP/system/core/libmemunreachable/include" \
        -I"$AV/media/libaudiofoundation/include" -I"$AV/media/libaudioclient/include" \
        -I"$AV/media/libmedia/include" -I"$AV/media/libmedia/aidl" \
        -I"$AV/media/libmediaextractor/include" -I"$AV/media/libmediandk/include" \
        -I"$AV/media/ndk/include" -I"$AV/media/libmediametrics/include" \
        -I"$AV/media/libmediautils/include" -I"$AV/media/utils/include" \
        -I"$AV/media/libmediaplayerservice/include" -I"$AV/media/libmediaplayerservice" \
        -I"$AV/media/libmediaplayerservice/nuplayer" -I"$AV/media/libmediadrm/include" \
        -I"$AV/media/libstagefright/include" -I"$AV/media/libstagefright/foundation/include" \
        -I"$AV/media/libstagefright/xmlparser/include" -I"$AV/media/libstagefright/omx/include" \
        -I"$AV/media/libstagefright" -I"$AV/media/libstagefright/httplive" \
        -I"$AV/media/libstagefright/mpeg2ts" -I"$AV/media/libstagefright/rtsp" \
        -I"$AV/media/libstagefright/timedtext" -I"$AV/media/libstagefright/webm" \
        -I"$AV/media/codec2/core/include" -I"$AV/media/codec2/vndk/include" \
        -I"$AV/media/codec2/hidl/client/include" -I"$AV/media/bufferpool/2.0/include" \
        -I"$AV/media/codec2/hidl/1.0/utils/include" \
        -I"$AV/camera/include" -I"$AV/camera/include/camera" \
        -I"$AV/drm/common/include" -I"$AV/drm/drmserver" \
        -I"$AV/drm/libdrmframework/plugins/common/include" \
        -I"$AV/services/mediaresourcemanager" -I"$AV/services/minijail" "$@"
}

# 链接闭包：镜像里那一整套媒体库（除自己）加本仓库的运行时闭包与 linker。
# 链接闭包是两批的并集：镜像里那一整套（$DEPS），加本脚本刚编出来的同组库（$GOUT/lib）。
# 后者不能漏：libmediaplayerservice 要的 LiveSession 就在同组的 libstagefright_httplive 里。
media_libraries() {
    self=$1
    for path in "$DEPS"/*.so "$GOUT/lib"/*.so; do
        [ -f "$path" ] || continue
        if [ "$(basename "$path")" != "$self" ]; then printf '%s\n' "$path"; fi
    done
}
media_build() {
    name=$1
    kind=$2
    shift 2
    objects=
    for source in "$@"; do
        case "$source" in *'*'*) set -- $source ;; esac
        object="$GOBJ/media-$(printf '%s' "${source#"$AV"/}" | tr / _).o"
        media_compile "$source" "$object"
        objects="$objects $object"
    done
    libraries=$(media_libraries "$name")
    if [ "$kind" = library ]; then
        ld.lld -shared -soname "$name" -z now -z relro -z max-page-size=4096 \
            --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --as-needed \
            "$OUT/obj/crt/crtbegin_so.o" $objects $libraries \
            "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC" \
            "$LINKER" "$BUILTINS" "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/$name"
    else
        ld.lld -pie -e _start -dynamic-linker /system/bin/linker64 \
            -z now -z relro -z max-page-size=4096 --hash-style=gnu --eh-frame-hdr \
            --build-id=sha1 --no-undefined --as-needed \
            "$OUT/obj/crt/crtbegin.o" $objects $libraries \
            "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC" \
            "$LINKER" "$BUILTINS" "$OUT/obj/crt/crtend.o" -o "$GOUT/bin/$name"
    fi
    printf 'media: %s\n' "$name"
}

media_build libresourcemanagerservice.so library \
    "$AV/services/mediaresourcemanager/ResourceManagerService.cpp" \
    "$AV/services/mediaresourcemanager/ServiceLog.cpp"
media_build libstagefright_httplive.so library \
    "$AV/media/libstagefright/httplive/"*.cpp \
    "$AV/media/libstagefright/mpeg2ts/"*.cpp \
    "$AV/media/libstagefright/id3/ID3.cpp" \
    "$AV/media/libstagefright/MetaDataUtils.cpp"
rtsp_sources=
for source in AAMRAssembler AAVCAssembler AH263Assembler AMPEG2TSAssembler \
    AMPEG4AudioAssembler AMPEG4ElementaryAssembler APacketSource ARawAudioAssembler \
    ARTPAssembler ARTPConnection ARTPSource ARTPWriter ARTSPConnection ASessionDescription; do
    rtsp_sources="$rtsp_sources $AV/media/libstagefright/rtsp/$source.cpp"
done
media_build libmediaplayerservice.so library \
    "$AV/media/libmediaplayerservice/"*.cpp \
    "$AV/media/libmediaplayerservice/nuplayer/"*.cpp \
    $rtsp_sources \
    "$AV/media/libstagefright/rtsp/SDPLoader.cpp" \
    "$AV/media/libstagefright/rtsp/NetworkUtils.cpp" \
    "$AV/media/libstagefright/timedtext/TextDescriptions.cpp"
media_build media program "$AV/media/mediaserver/main_mediaserver.cpp" \
    "$AV/media/mediaserver/register.cpp"
media_build media-drm program "$AV/services/mediadrm/"*.cpp
media_build drm program "$AV/drm/drmserver/"*.cpp "$AV/drm/common/"*.cpp
media_build media-omx program "$AV/services/mediacodec/main_codecservice.cpp"

allowed='libc++.so libm.so libunwind.so libc.so libdl.so'
for f in "$GOUT"/lib/*.so "$GOUT"/bin/media "$GOUT"/bin/media-drm "$GOUT"/bin/drm "$GOUT"/bin/media-omx; do
    [ -f "$f" ] || continue
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
done
printf 'media finished\n'
for f in "$GOUT"/lib/*.so "$GOUT"/bin/media "$GOUT"/bin/media-drm "$GOUT"/bin/drm "$GOUT"/bin/media-omx; do
    [ -f "$f" ] || continue
    printf '  %s  %s  %s\n' "$(wc -c < "$f" | tr -d ' ')" \
        "$(sha256sum -t "$f" | cut -d ' ' -f 1)" "$(basename "$f")"
done
