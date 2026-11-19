#!/bin/sh
# Android 10 静态 Bionic 自举闭包：liba10vm-bootstrap.a 与 bin/bootstrap-probe。
# 源在 vendor/runtime 与 runtime/upstream，产物落 runtime/build。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RT="$MODULE/runtime"
SRC="$MODULE/vendor/runtime"
UP="$RT/upstream"
OUT="$RT/build"
PROPS="$OUT/properties/derived"
for tool in clang clang++ llvm-ar llvm-readelf llvm-nm git python3; do command -v "$tool" >/dev/null; done
unset LD_LIBRARY_PATH LD_PRELOAD
sh "$RT/prepare-properties.sh"
mkdir -p "$OUT/obj/static" "$OUT/bin" "$OUT/lib"
B="$UP/bionic/libc"
P="$PROPS/bionic/libc"
C="$PROPS/core/property_service/libpropertyinfoparser"
mkdir -p "$OUT/derived/bionic/libc/bionic"
cp "$B/bionic/bionic_systrace.cpp" "$OUT/derived/bionic/libc/bionic/"
( cd "$OUT/derived" && patch -p1 --no-backup-if-mismatch < "$RT/platform.patch" )
compile() {
    input=$1
    object=$2
    shift 2
    case "$input" in
        */linker_memory.cpp|*/cxa_thread_atexit.cpp) cxx_include="$UP/external/libcxx/include" ;;
        *) cxx_include="$UP/bionic/libstdc++/include" ;;
    esac
    set -- --target=aarch64-linux-android29 -nostdinc \
        -isystem "$cxx_include" \
        -isystem "$(clang -print-resource-dir)/include" \
        -isystem "$B/include" -isystem "$B/kernel/uapi/asm-arm64" \
        -isystem "$B/kernel/uapi" -isystem "$B/kernel/android/uapi" \
        -I"$B" -I"$B/async_safe/include" -I"$B/private" \
        -I"$B/stdio" \
        -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libcutils/include" \
        -I"$UP/external/libcxxabi/include" \
        -I"$P/system_properties/include" -I"$C/include" \
        -I"$B/upstream-openbsd/android/include" \
        -I"$B/upstream-openbsd/lib/libc/include" \
        -fPIC -fno-stack-protector -fno-exceptions -fno-rtti -fno-sized-deallocation \
        -fno-emulated-tls \
        -ffunction-sections -fdata-sections -mno-outline-atomics \
        -O2 -D_LIBC=1 -DLIBC_STATIC -Wno-main \
        -MD -MF "$object.d" "$@"
    case "$input" in
        */cxa_thread_atexit.cpp) set -- "$@" -DHAVE___CXA_THREAD_ATEXIT_IMPL ;;
    esac
    case "$input" in
        *.cpp) clang++ "$@" -nostdinc++ -std=gnu++17 -c "$input" -o "$object" ;;
        *.c) clang "$@" -std=gnu99 -c "$input" -o "$object" ;;
        *.S) clang "$@" -c "$input" -o "$object" ;;
    esac
}
objects=
. "$SRC/filesystem/sources.sh"
while read -r path; do
    if guest_fs_replaces "$path"; then continue; fi
    object="$OUT/obj/static/$(printf '%s' "$path" | tr / _).o"
    case "$path" in
        */upstream-openbsd/*) compile "$UP/$path" "$object" -include openbsd-compat.h ;;
        *) compile "$UP/$path" "$object" ;;
    esac
    objects="$objects $object"
done < "$RT/lists/static-sources.txt"
for path in GuestPaths GuestFileCalls GuestExec GuestOwnership GuestIdentity GuestXattrs GuestTimers GuestSockets; do
    object="$OUT/obj/static/$path.o"
    compile "$SRC/filesystem/$path.cpp" "$object"
    objects="$objects $object"
done
object="$OUT/obj/static/bionic_systrace.o"
compile "$OUT/derived/bionic/libc/bionic/bionic_systrace.cpp" "$object"
objects="$objects $object"
for path in system_properties/context_node.cpp system_properties/contexts_serialized.cpp \
    system_properties/prop_area.cpp system_properties/prop_info.cpp \
    system_properties/system_properties.cpp bionic/system_property_api.cpp async_safe/async_safe_log.cpp; do
    object="$OUT/obj/static/property_$(basename "$path" .cpp).o"
    compile "$P/$path" "$object"
    objects="$objects $object"
done
# 属性服务这一组在链接 linker 时会引出三个符号，它们必须由同一个归档提供：
#   ContextsSplit 的 vtable  ← system_properties.cpp 的 Init 需要它
#   fsetxattr / ___fsetxattr ← prop_area.cpp 写属性区时调用
# 这三份不在 static-sources.txt 里，是链接错误指名要的，漏了 linker 就过不了 --no-undefined。
object="$OUT/obj/static/contexts_split.o"
compile "$UP/bionic/libc/system_properties/contexts_split.cpp" "$object"
objects="$objects $object"
object="$OUT/obj/static/fsetxattr.o"
compile "$UP/bionic/libc/bionic/fsetxattr.cpp" "$object"
objects="$objects $object"
object="$OUT/obj/static/syscalls___fsetxattr.o"
compile "$UP/bionic/libc/arch-arm64/syscalls/___fsetxattr.S" "$object"
objects="$objects $object"
# contexts_split.cpp 用 strndup，它和 strdup 一样在 upstream-openbsd 的 string 组里，清单里只有后者。
object="$OUT/obj/static/strndup.o"
compile "$UP/bionic/libc/upstream-openbsd/lib/libc/string/strndup.c" "$object" -include openbsd-compat.h
objects="$objects $object"
object="$OUT/obj/static/property_info_parser.o"
compile "$C/property_info_parser.cpp" "$object"
objects="$objects $object"
rm -f "$OUT/lib/liba10vm-bootstrap.a"
llvm-ar rcD "$OUT/lib/liba10vm-bootstrap.a" $objects
# 静态探针可执行文件要用 stdio 的 fputs 校验缓冲刷新，那会把 vfprintf、wcsrtombs 整条链拉进来，
# 属于测试件不属于运行时产物，单独一轮处理。这里只出归档，linker 只要这一份。
