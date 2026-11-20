#!/bin/sh
# A10 的客体图形组：EGL、GLES1、GLES2、gralloc、HWC2 与它们共用的 codec 层。
#
#   sh bridges/build-graphics-a10.sh
#
# 产物（bridges/graphics/lib）：
#   libOpenglSystemCommon.so    codec 客户端、GLES 编码器与纹理状态
#   libEGL_emulation.so         ro.hardware.egl=emulation 时 hw_get_module 加载的 EGL
#   libGLESv1_CM_emulation.so   GLES1 入口
#   libGLESv2_emulation.so      GLES2 入口
#   gralloc.ranchu.so           ro.hardware.gralloc=ranchu 的分配器
#   hwcomposer.ranchu.so        ro.hardware.hwcomposer=ranchu 的合成器
#
# 客体里的 libEGL.so、libGLESv1_CM.so、libGLESv2.so 与 libhardware.so 由镜像提供，
# 这一组补的是它们按 ro.hardware.* 去 hw_get_module 时加载的那个模块。
#
# 与 A9、A15 的差别只有编译目标与链接闭包：目标是 aarch64-linux-android29，
# 链接本仓库自建的 libc、libdl、libm、libunwind 与镜像的 libc++，不链任何别的域的库。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
set +u

SRC="$MODULE/vendor/graphics"
UP="$RT/upstream"
B="$UP/bionic/libc"
G="$UP/device/generic/goldfish-opengl"
Q="$UP/external/qemu/android/android-emugl"
GOUT="$OUT/graphics"
GOBJ="$GOUT/obj"
DER="$GOUT/derived"
DEF="$GOUT/definitions"
GEN="$GOUT/generated"
RCGEN="$GOUT/desktop/generated"
ROM="$MODULE/rootfs/system/lib64"
REG="$OUT/lib/registry"

for required in \
    "$G/system/hwc2/EmuHWC2.cpp" \
    "$G/system/gralloc/gralloc.cpp" \
    "$G/system/egl/egl.cpp" \
    "$G/system/OpenglSystemCommon/ThreadInfo.cpp" \
    "$Q/shared/OpenglCodecCommon/ChecksumCalculator.cpp" \
    "$Q/host/libs/GLESv2_dec/gles2.in" \
    "$Q/host/libs/renderControl_dec/renderControl.in" \
    "$UP/frameworks/native/opengl/include/EGL/egl.h" \
    "$UP/hardware/libhardware/include/hardware/gralloc.h" \
    "$UP/system/core/libsync/include/sync/sync.h" \
    "$SRC/generated/gl2_enc.cpp" \
    "$SRC/generated/renderControl_enc.cpp" ; do
    if [ ! -f "$required" ]; then
        printf 'graphics: 缺 %s\n' "$required" >&2
        printf 'graphics: 上游靠 python runtime/fetch-a10-sources.py 取回\n' >&2
        exit 1
    fi
done

# 派生件、对象与产物每轮重建：这一组的输入全是钉住的上游源，留着上一轮的对象只会
# 让 glob 把别人的 .o 也链进来，换回的是不可复现。
rm -rf "$DER" "$GOBJ" "$GOUT/lib"
mkdir -p "$GOUT/lib" "$GOBJ" "$DEF" "$GEN" "$RCGEN" \
         "$DER/common" "$DER/encoder" "$DER/egl" "$DER/gralloc" "$DER/hwc2"

# emugen 的定义文件由钉住的上游源改名而来，不另存一份。那份产物（generated）是
# emugen 的输出，本仓库按 A15 的先例提交，理由是宿主工具需要宿主的 C++ 链接器。
for suffix in in attrib types; do
    cp "$Q/host/libs/GLESv2_dec/gles2.$suffix" "$DEF/gl2.$suffix"
    cp "$Q/host/libs/renderControl_dec/renderControl.$suffix" "$DEF/renderControl.$suffix"
done
cp "$Q/host/libs/GLESv2_dec/gles2_types.h" "$DEF/gl2_types.h"
cp "$G/system/renderControl_enc/renderControl_types.h" "$DEF/renderControl_types.h"
cp "$SRC/generated/gl2_"* "$GEN/"
cp "$SRC/generated/renderControl_"* "$RCGEN/"

# codec id 必须与宿主渲染器里烧的那一个相同，否则客体与宿主在握手上互相拒绝。
# 公式与 container-probe/graphics/build-desktop.sh 逐字相同：同一批文件、同一批相对路径、
# 同一个 sha256sum 汇总。唯一的改动是给 sha256sum 加 -t：Git for Windows 的 sha256sum
# 默认走二进制模式，输出 "<hash> *<name>" 而不是 "<hash>  <name>"，同一个公式会算出另一个 id，
# 客体与宿主从此互相拒绝。加上 -t 之后两个平台落同一条文本，id 才对得上。
CODEC_ID=$( (cd "$GOUT"; sha256sum -t generated/gl2_enc.cpp generated/gl2_dec.cpp \
    desktop/generated/renderControl_enc.cpp desktop/generated/renderControl_dec.cpp; \
    cd "$SRC/desktop"; sha256sum -t HostConnection.cpp TextureUploadEncoder.h GuestTextureContexts.cpp \
    GuestTextureContexts.h texture-contexts.patch DesktopProtocol.h guest.patch) | sha256sum | cut -d ' ' -f 1 )
case "$CODEC_ID" in
    ????????????????????????????????????????????????????????????????) ;;
    *) printf 'graphics: codec id 算不出来（%s）\n' "$CODEC_ID" >&2; exit 1 ;;
esac
printf '%s\n' "$CODEC_ID" > "$GOUT/codec-id.txt"

# 派生件：被补丁改过的上游文件先复制再打补丁，上游树一个字节不动。
cp "$Q/shared/OpenglCodecCommon/ChecksumCalculator.cpp" \
   "$Q/shared/OpenglCodecCommon/ChecksumCalculator.h" \
   "$Q/shared/OpenglCodecCommon/ChecksumCalculatorThreadInfo.h" "$DER/common/"
cp "$G/shared/OpenglCodecCommon/GLSharedGroup.cpp" \
   "$G/shared/OpenglCodecCommon/GLSharedGroup.h" "$DER/common/"
cp "$G/system/GLESv2_enc/GL2Encoder.cpp" "$DER/encoder/"
cp "$G/system/egl/egl.cpp" "$G/system/egl/eglDisplay.cpp" "$DER/egl/"
cp "$G/system/gralloc/gralloc.cpp" "$DER/gralloc/"
cp "$G/system/OpenglSystemCommon/FormatConversions.cpp" "$DER/"
cp "$G/system/hwc2/EmuHWC2.cpp" "$G/system/hwc2/EmuHWC2.h" \
   "$G/system/hwc2/MiniFence.cpp" "$G/system/hwc2/MiniFence.h" "$DER/hwc2/"

# 这些补丁的 hunk 头是手写裁剪过的，GNU patch 会整份判成 malformed，只有
# git apply --recount 能落地。所以落地与否必须自己判，判据是下面三条 grep。
apply_patch() {
    patch_file=$1
    relative=${DER#"$MODULE"/}
    if (cd "$MODULE" && git apply --recount --unsafe-paths --directory="$relative" "$patch_file"); then
        return 0
    fi
    if (cd "$MODULE" && git apply --recount --unsafe-paths -R --check \
            --directory="$relative" "$patch_file" >/dev/null 2>&1); then
        return 0
    fi
    printf 'graphics: 补丁没落地 %s\n' "$patch_file" >&2
    exit 1
}
apply_patch "$SRC/platform.patch"
for name in guest config-handles texture-contexts format-conversions yuv-rgb-rows hwc \
            native-fence-fallback idle native-image-lifetime; do
    apply_patch "$SRC/desktop/$name.patch"
done
grep -q A10VM_NO_SNAPSHOTS "$DER/common/ChecksumCalculator.cpp" || {
    printf 'graphics: platform.patch 没落到 ChecksumCalculator.cpp\n' >&2; exit 1; }
grep -q kMaxChecksumSize "$DER/common/ChecksumCalculator.h" || {
    printf 'graphics: platform.patch 没落到 ChecksumCalculator.h\n' >&2; exit 1; }
grep -q EGL_KHR_gl_texture_2D_image "$DER/egl/eglDisplay.cpp" || {
    printf 'graphics: guest.patch 没落到 eglDisplay.cpp\n' >&2; exit 1; }
grep -q 'desktopdisplay::vsyncNanos' "$DER/hwc2/EmuHWC2.cpp" || {
    printf 'graphics: hwc.patch 没落到 EmuHWC2.cpp\n' >&2; exit 1; }

# 编译参数从 container-probe/graphics/build-desktop.sh 原样继承，只把 include 路径
# 换成本仓库的落位。PLATFORM_SDK_VERSION 是 29：客体就是这个 API，头也是 AOSP 10 的。
gfx_compile() {
    input=$1
    object=$2
    shift 2
    compile "$input" "$object" -std=gnu++17 \
        -DA10VM_NO_SNAPSHOTS -DA10VM_NO_DMA -DPLATFORM_SDK_VERSION=29 \
        -DEMULATOR_OPENGL_POST_O -DWITH_GLES2 \
        -DEGL_EGLEXT_PROTOTYPES -DGL_GLEXT_PROTOTYPES -DLOG_TAG=\"a10vm-gpu\" \
        -include "$Q/shared/OpenglCodecCommon/ErrorLog.h" \
        "-DA10VM_DESKTOP_CODEC_ID=\"$CODEC_ID\"" -Wno-deprecated-declarations \
        -I"$SRC/compat" -I"$SRC/native" -I"$SRC/desktop" -I"$DER/common" \
        -I"$GEN" -I"$RCGEN" -I"$DEF" \
        -I"$G/system/OpenglSystemCommon" -I"$G/system/GLESv1_enc" \
        -I"$G/system/GLESv2_enc" -I"$G/system/include" -I"$G/system/egl" \
        -I"$G/system/hwc2" -I"$G/shared/OpenglCodecCommon" \
        -I"$Q/shared/OpenglCodecCommon" \
        -I"$UP/frameworks/native/opengl/include" -I"$UP/hardware/libhardware/include" \
        -I"$UP/frameworks/native/libs/nativewindow/include" \
        -I"$UP/frameworks/native/libs/nativebase/include" \
        -I"$UP/frameworks/native/libs/ui/include" \
        -I"$UP/frameworks/native/libs/arect/include" \
        -I"$UP/system/core/libcutils/include" -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libutils/include" -I"$UP/system/core/libsystem/include" \
        -I"$UP/system/core/include" -I"$UP/system/core/libsync/include" \
        -I"$UP/system/libhwbinder/include" "$@"
}

crt_so
# 客体里只有一份 libutils、liblog、libcutils：binder 组刚编出的那三份。
# 图形库链它们，装机后与客体里同名的库是同一个文件，不会出现两份实现。
link_guest() {
    name=$1
    shift
    ld.lld -shared -soname "$name" -z now -z relro -z max-page-size=4096 \
        --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
        "$OUT/obj/crt/crtbegin_so.o" "$@" \
        "$REG/libutils.so" "$REG/liblog.so" "$REG/libcutils.so" \
        "$LIBCXX" "$LIBM" "$LIBUNWIND" "$LIBDL" "$LIBC" "$BUILTINS" \
        "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/$name"
}

# libOpenglSystemCommon 是其余五件的地基：codec 客户端、GLES 编码器、纹理状态都在这。
for source in \
    "$SRC/desktop/HostConnection.cpp" \
    "$SRC/desktop/GuestTextureContexts.cpp" \
    "$SRC/native/SocketStream.cpp" \
    "$SRC/desktop/YuvRgbRows.cpp" \
    "$SRC/native/CodecPlatform.cpp" \
    "$SRC/native/PixelReadback.cpp" \
    "$DER/common/ChecksumCalculator.cpp" \
    "$DER/common/GLSharedGroup.cpp" \
    "$G/system/OpenglSystemCommon/ThreadInfo.cpp" \
    "$DER/FormatConversions.cpp" \
    "$DER/encoder/GL2Encoder.cpp" \
    "$G/system/GLESv2_enc/GL2EncoderUtils.cpp" \
    "$G/system/GLESv2_enc/GLESv2Validation.cpp" \
    "$G/shared/OpenglCodecCommon/GLClientState.cpp" \
    "$G/shared/OpenglCodecCommon/GLESTextureUtils.cpp" \
    "$G/shared/OpenglCodecCommon/IndexRangeCache.cpp" \
    "$G/shared/OpenglCodecCommon/glUtils.cpp" \
    "$G/shared/OpenglCodecCommon/goldfish_dma.cpp" \
    "$G/system/GLESv1_enc/GLEncoder.cpp" \
    "$G/system/GLESv1_enc/gl_enc.cpp" \
    "$G/system/GLESv1_enc/GLEncoderUtils.cpp" \
    "$G/system/GLESv1_enc/gl_client_context.cpp" \
    "$GEN/gl2_enc.cpp" "$GEN/gl2_client_context.cpp" \
    "$RCGEN/renderControl_enc.cpp" "$RCGEN/renderControl_client_context.cpp" ; do
    gfx_compile "$source" "$GOBJ/$(basename "$source" .cpp).o"
done
link_guest libOpenglSystemCommon.so "$GOBJ"/*.o

for api in GLESv1 GLESv2; do
    case "$api" in
        GLESv1) source="$G/system/GLESv1/gl.cpp"; name=libGLESv1_CM_emulation.so ;;
        GLESv2) source="$G/system/GLESv2/gl2.cpp"; name=libGLESv2_emulation.so ;;
    esac
    gfx_compile "$source" "$GOBJ/$api.o"
    link_guest "$name" "$GOBJ/$api.o" "$GOUT/lib/libOpenglSystemCommon.so"
done

for source in "$DER/egl/egl.cpp" "$DER/egl/eglDisplay.cpp" "$G/system/egl/ClientAPIExts.cpp"; do
    gfx_compile "$source" "$GOBJ/$(basename "$source" .cpp).o"
done
link_guest libEGL_emulation.so "$GOBJ/egl.o" "$GOBJ/eglDisplay.o" "$GOBJ/ClientAPIExts.o" \
    "$GOUT/lib/libOpenglSystemCommon.so" "$ROM/libnativewindow.so"

gfx_compile "$DER/gralloc/gralloc.cpp" "$GOBJ/gralloc.o"
link_guest gralloc.ranchu.so "$GOBJ/gralloc.o" "$GOUT/lib/libOpenglSystemCommon.so" \
    "$ROM/libnativewindow.so" "$ROM/libhardware.so"

# hwc2 这两份用 -fno-rtti：镜像的 libutils.so 不导出 android::Thread 的 typeinfo。
gfx_compile "$DER/hwc2/EmuHWC2.cpp" "$GOBJ/EmuHWC2.o" -fno-rtti
gfx_compile "$DER/hwc2/MiniFence.cpp" "$GOBJ/MiniFence.o" -fno-rtti
link_guest hwcomposer.ranchu.so "$GOBJ/EmuHWC2.o" "$GOBJ/MiniFence.o" \
    "$GOUT/lib/libOpenglSystemCommon.so" "$ROM/libhardware.so" "$ROM/libsync.so"

# 依赖闸门：只许落在本仓库的运行时、binder 组的三份与镜像里那几个上，出现 NDK 的库即失败。
allowed='libOpenglSystemCommon.so libutils.so liblog.so libcutils.so libc++.so libm.so
libunwind.so libc.so libdl.so libnativewindow.so libhardware.so libsync.so'
for f in "$GOUT"/lib/*.so; do
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
    for needed in $(llvm-readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'); do
        case " $(printf '%s' "$allowed" | tr '\n' ' ') " in
            *" $needed "*) ;;
            *) printf 'graphics: %s 的 NEEDED 里出现 %s，不在允许清单\n' \
                   "$(basename "$f")" "$needed" >&2; exit 1 ;;
        esac
    done
done

# 入口闸门：prepared 里同名那份导出的符号必须都在，缺一个就说明这一组编错了。
# 反方向不判：多出来的符号来自编译参数与头版本，不影响客体按名字找入口。
for name in libOpenglSystemCommon.so libEGL_emulation.so libGLESv1_CM_emulation.so \
            libGLESv2_emulation.so gralloc.ranchu.so hwcomposer.ranchu.so; do
    reference="$MODULE/prepared/jniLibs/arm64-v8a/liba10vm-guest-$name"
    if [ ! -f "$reference" ]; then
        printf 'graphics: %s 没有对照件，跳过入口比对\n' "$name"
        continue
    fi
    llvm-nm -D --defined-only "$reference" | awk '{print $3}' | sort -u > "$GOBJ/$name.reference"
    llvm-nm -D --defined-only "$GOUT/lib/$name" | awk '{print $3}' | sort -u > "$GOBJ/$name.built"
    if ! diff -q "$GOBJ/$name.reference" "$GOBJ/$name.built" >/dev/null 2>&1; then
        if comm -23 "$GOBJ/$name.reference" "$GOBJ/$name.built" | grep -q .; then
            printf 'graphics: %s 缺 prepared 那份导出的符号：\n' "$name" >&2
            comm -23 "$GOBJ/$name.reference" "$GOBJ/$name.built" >&2
            exit 1
        fi
    fi
done

printf 'graphics finished\n  codec-id %s\n' "$CODEC_ID"
for f in "$GOUT"/lib/*.so; do
    printf '  %s  %s  %s\n' "$(wc -c < "$f" | tr -d ' ')" \
        "$(sha256sum -t "$f" | cut -d ' ' -f 1)" "$(basename "$f")"
done
