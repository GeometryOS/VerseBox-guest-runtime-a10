#!/bin/bash
# A10 媒体七件的宿主生成器：hidl-gen 与 aidl，以及它们生成的接口头。
#
#   sh runtime/build-media-tools.sh
#
# 为什么单独一步：hidl-gen 与 aidl 是**宿主**工具，不是交叉编译出来的。hidl-gen 的解析器
# 要用 bison 与 flex 生成，所以这一步只能在有 bison/flex 的 Linux 上跑（CI 的 ubuntu-24.04
# 或 WSL）；产物是纯文本头，后面的编译在哪个平台都行。
#
# 产物：
#   runtime/build/media/tools/hidl-gen
#   runtime/build/media/generated/include/**      28 个 HIDL 包的 C++ 头加 AIDL 头
#
# 试过但不采用的路：在 Windows 的 MSYS2 上编 hidl-gen。MSYS2 能给 bison 3.8.2、flex 2.6.4、
# g++ 16.2.0，但 AOSP 10 的 libbase 只认 __linux__、__APPLE__、_WIN32 三条分支，
# file.cpp 直接 #error unknown OS；为它加一条 Windows 分支等于给宿主生成器添第二个平台，
# 与本项目的平台纪律相反。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
UP="$MODULE/runtime/upstream"
HIDL="$UP/system/tools/hidl"
BASE="$UP/system/core/base"
HW="$UP/hardware/interfaces"
LIBHIDL="$UP/system/libhidl/transport"
OUT="$MODULE/runtime/build/media/tools"
GEN="$MODULE/runtime/build/media/generated/include"
AIDLGEN="$MODULE/runtime/build/media/generated/aidl"
AV="$UP/frameworks/av"
NATIVE="$UP/frameworks/native"

for tool in bison flex clang++ g++; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'build-media-tools.sh: 缺 %s；这一步要 Linux 上的 bison 与 flex\n' "$tool" >&2
        exit 1
    }
done
for required in "$HIDL/hidl-gen_y.yy" "$HW/media/omx/1.0/IOmx.hal" "$AV/camera/aidl"; do
    [ -e "$required" ] || {
        printf 'build-media-tools.sh: 缺 %s，先跑 python runtime/fetch-a10-sources.py\n' "$required" >&2
        exit 1
    }
done

mkdir -p "$OUT/obj" "$OUT/generated" "$GEN" "$AIDLGEN"
GENP="$OUT/generated"

sed '/^%pure-parser$/d' "$HIDL/hidl-gen_y.yy" > "$GENP/hidl-gen_y.yy"
bison --defines="$GENP/hidl-gen_y.h" -o "$GENP/hidl-gen_y.cpp" "$GENP/hidl-gen_y.yy" 2>/dev/null
sed '/#include "hidl-gen_y.h"/a\
#define YYSTYPE yy::parser::semantic_type\
#define YYLTYPE yy::parser::location_type' "$HIDL/hidl-gen_l.ll" > "$GENP/hidl-gen_l.ll"
flex -o "$GENP/hidl-gen_l.cpp" "$GENP/hidl-gen_l.ll"

# AOSP 10 的这份代码是给当年的 clang 写的：现代 clang 要显式带上这几个 C 头，
# 否则 std::strlen、strerror 这类名字找不到。宿主工具上的这种补偿不影响产物。
compile() {
    clang++ -std=gnu++17 -O2 -fPIC -DNDEBUG -w \
        -include string.h -include stdint.h -include cstdint \
        -include cstring -include cstdio -include cstdlib \
        -I"$BASE/include" -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libutils/include" \
        -I"$HIDL" -I"$HIDL/host_utils/include" -I"$HIDL/host_utils/include/hidl-util" \
        -I"$HIDL/utils/include" -I"$HIDL/utils/include/hidl-util" \
        -I"$HIDL/hashing/include" -I"$UP/external/boringssl/src/include" -I"$GENP" \
        -c "$1" -o "$2"
}

objs=
for name in file logging stringprintf strings errors_unix threads; do
    compile "$BASE/$name.cpp" "$OUT/obj/base-$name.o"
    objs="$objs $OUT/obj/base-$name.o"
done
for src in "$HIDL"/*.cpp "$HIDL/host_utils"/*.cpp "$HIDL/utils"/*.cpp "$HIDL/hashing/Hash.cpp" \
           "$GENP/hidl-gen_y.cpp" "$GENP/hidl-gen_l.cpp"; do
    object="$OUT/obj/hidl-$(basename "$src" .cpp).o"
    compile "$src" "$object"
    objs="$objs $object"
done
clang++ $objs -lcrypto -o "$OUT/hidl-gen"
printf 'hidl-gen 就位：%s\n' "$OUT/hidl-gen"

for package in android.hidl.base@1.0 android.hidl.manager@1.0 android.hidl.manager@1.1 \
    android.hidl.manager@1.2 android.hidl.memory@1.0 android.hidl.memory.token@1.0 \
    android.hidl.memory.block@1.0 android.hidl.allocator@1.0 android.hidl.token@1.0 \
    android.hidl.safe_union@1.0 android.hardware.graphics.common@1.0 \
    android.hardware.graphics.common@1.1 android.hardware.graphics.common@1.2 \
    android.hardware.graphics.bufferqueue@1.0 android.hardware.graphics.bufferqueue@2.0 \
    android.hardware.graphics.mapper@2.0 android.hardware.graphics.mapper@2.1 \
    android.hardware.graphics.mapper@3.0 android.hardware.media@1.0 \
    android.hardware.media.omx@1.0 android.hardware.media.c2@1.0 \
    android.hardware.media.bufferpool@1.0 android.hardware.media.bufferpool@2.0 \
    android.hardware.cas@1.0 android.hardware.cas.native@1.0 \
    android.hardware.drm@1.0 android.hardware.drm@1.1 android.hardware.drm@1.2; do
    "$OUT/hidl-gen" -Lc++-headers -o "$GEN" -randroid.hardware:"$HW" -randroid.hidl:"$LIBHIDL" \
        "$package"
done
# 这份头在 C++17 下要 inline，否则多个翻译单元各有一份定义。
for header in $(grep -rl 'template<> constexpr std::array' "$GEN" || true); do
    sed -i 's/template<> constexpr std::array/template<> inline constexpr std::array/g' "$header"
done
printf 'HIDL 头：%s 个\n' "$(find "$GEN" -name '*.h' | wc -l)"

# AIDL：SDK 的 build-tools 里就有官方 aidl，先试它；没有再用 AOSP 的。
aidl_bin=${A10_AIDL:-}
if [ -z "$aidl_bin" ]; then
    for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        [ -n "$candidate" ] || continue
        found=$(ls -1 "$candidate"/build-tools/*/aidl 2>/dev/null | sort -V | tail -1 || true)
        if [ -n "$found" ]; then aidl_bin=$found; break; fi
    done
fi
[ -n "$aidl_bin" ] || {
    printf 'build-media-tools.sh: 找不到 aidl，用 A10_AIDL 指一个，或装 Android build-tools\n' >&2
    exit 1
}
"$aidl_bin" --lang=cpp -I"$AV/camera/aidl" -I"$NATIVE/aidl/gui" -o"$AIDLGEN" -h"$GEN" \
    "$AV/camera/aidl/android/hardware/ICameraService.aidl" \
    "$AV/camera/aidl/android/hardware/ICameraServiceListener.aidl" \
    "$AV/camera/aidl/android/hardware/ICameraServiceProxy.aidl" \
    "$AV/camera/aidl/android/hardware/camera2/ICameraDeviceCallbacks.aidl" \
    "$AV/camera/aidl/android/hardware/camera2/ICameraDeviceUser.aidl"
"$aidl_bin" --lang=cpp -I"$AV/media/libaudioclient/aidl" -o"$AIDLGEN" -h"$GEN" \
    "$AV/media/libaudioclient/aidl/android/media/IAudioRecord.aidl" \
    "$AV/media/libaudioclient/aidl/android/media/IPlayer.aidl"
"$aidl_bin" --lang=cpp -I"$AV/media/libmedia/aidl" -o"$AIDLGEN" -h"$GEN" \
    "$AV/media/libmedia/aidl/android/IGraphicBufferSource.aidl" \
    "$AV/media/libmedia/aidl/android/IOMXBufferSource.aidl"
cp "$AV/media/libmedia/aidl/android/IOMXNode.h" "$GEN/android/IOMXNode.h"
printf '接口头就位：%s 个\n' "$(find "$GEN" -name '*.h' | wc -l)"
