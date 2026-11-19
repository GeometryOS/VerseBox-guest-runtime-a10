#!/bin/sh
# 共享 libc 与 libdl：产物 runtime/build/lib/{libc.so,libdl.so}。
# 走 AOSP 10 的源码闭包，属性服务用 runtime/build/properties/derived 那份派生树。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RT="$MODULE/runtime"
SRC="$MODULE/vendor/runtime/dynamic"
FS="$MODULE/vendor/runtime/filesystem"
OUT="$RT/build"
UP="$RT/upstream"
B="$UP/bionic/libc"
PROPS="$OUT/properties/derived"
P="$PROPS/bionic/libc"
C="$PROPS/core/property_service/libpropertyinfoparser"
for tool in clang clang++ ld.lld llvm-readelf llvm-nm git python3; do command -v "$tool" >/dev/null; done
unset LD_LIBRARY_PATH LD_PRELOAD
sh "$RT/prepare-properties.sh"
# 派生树（bionic_systrace.cpp 等）由 build-static 生成，libc 的源清单里会引用它，
# 所以这一步不能因为 linker 已存在就跳过。
sh "$RT/build-static.sh"
test -f "$OUT/bin/source-linker64" || sh "$RT/build-linker.sh"
mkdir -p "$OUT/obj/libc" "$OUT/obj/libdl" "$OUT/lib" "$OUT/generated"
mkdir -p "$OUT/derived/bionic/libc/bionic"
cp "$B/bionic/grp_pwd.cpp" "$OUT/derived/bionic/libc/bionic/"
git apply --recount --unsafe-paths --directory="$OUT/derived" "$SRC/legacy-oem-accounts.patch"
BUILD_KIND=shared
PROPERTY_INCLUDE="$P/system_properties/include"
. "$RT/compile-platform.sh"
python3 "$SRC/select-libc-sources.py" "$UP" | tr -d '\r' > "$OUT/generated/libc-sources.txt"
python3 "$UP/bionic/tools/generate-version-script.py" arm64 "$B/libc.map.txt" "$OUT/generated/libc.map.raw"
tr -d '\r' < "$OUT/generated/libc.map.raw" > "$OUT/generated/libc.map"
python3 "$UP/bionic/tools/generate-version-script.py" arm64 \
    "$UP/bionic/libdl/libdl.map.txt" "$OUT/generated/libdl.map.raw"
tr -d '\r' < "$OUT/generated/libdl.map.raw" > "$OUT/generated/libdl.map"
builtins=$(clang --target=aarch64-linux-android29 --print-libgcc-file-name)
test -f "$builtins"
dl_objects=
for path in libdl.cpp libdl_cfi.cpp; do
    object="$OUT/obj/libdl/$path.o"
    compile "$UP/bionic/libdl/$path" "$object"
    dl_objects="$dl_objects $object"
done
ld.lld -shared -soname libdl.so -z max-page-size=4096 -z now -z relro \
    --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
    --version-script "$OUT/generated/libdl.map" $dl_objects "$OUT/bin/source-linker64" \
    "$builtins" -o "$OUT/lib/libdl.so"
objects=
. "$FS/sources.sh"
while read -r path; do
    if guest_fs_replaces "$path"; then continue; fi
    object="$OUT/obj/libc/$(printf '%s' "$path" | tr / _).o"
    case "$path" in
        bionic/libc/system_properties/*|bionic/libc/bionic/system_property_api.cpp|bionic/libc/async_safe/async_safe_log.cpp)
            input="$P/${path#bionic/libc/}" ;;
        bionic/libc/bionic/bionic_systrace.cpp|bionic/libc/bionic/grp_pwd.cpp)
            input="$OUT/derived/$path" ;;
        *) input="$UP/$path" ;;
    esac
    case "$path" in
        bionic/libc/bionic/grp_pwd.cpp)
            compile "$input" "$object" -I"$C/include" -I"$B/bionic" ;;
        bionic/libc/arch-arm64/bionic/syscall.S)
            compile "$input" "$object" -Dsyscall=a10vm_kernel_syscall ;;
        bionic/libc/arch-arm64/syscalls/prctl.S)
            continue ;;
        bionic/libc/upstream-freebsd/lib/libc/stdlib/realpath.c)
            compile "$input" "$object" -I"$C/include" -Drealpath=a10vm_host_realpath \
                -Dlstat=a10vm_host_lstat -Dreadlink=a10vm_host_readlink -Dgetcwd=a10vm_host_getcwd ;;
        *) compile "$input" "$object" -I"$C/include" ;;
    esac
    objects="$objects $object"
done < "$OUT/generated/libc-sources.txt"
for path in GuestPaths GuestFileCalls GuestProcMaps GuestExec GuestRealpath GuestOwnership GuestIdentity GuestXattrs GuestTimers GuestSockets GuestSandbox GuestSyscalls; do
    object="$OUT/obj/libc/$path.o"
    if [ "$path" = GuestSyscalls ]; then
        compile "$FS/$path.cpp" "$object"
    else
        compile "$FS/$path.cpp" "$object" -Dsyscall=a10vm_kernel_syscall
    fi
    objects="$objects $object"
done
object="$OUT/obj/libc/GuestSyscalls.S.o"
compile "$FS/GuestSyscalls.S" "$object"
objects="$objects $object"
object="$OUT/obj/libc/property_info_parser.cpp.o"
compile "$C/property_info_parser.cpp" "$object" -I"$C/include"
objects="$objects $object"
object="$OUT/obj/libc/libdl_android.cpp.o"
compile "$UP/bionic/libdl/libdl_android.cpp" "$object"
objects="$objects $object"
# 五百多个对象直接铺在命令行上会超过 Windows 的 argv 上限（Argument list too long），
# 写成响应文件交给 ld.lld 读。
# 响应文件里的路径不会被 MSYS 转成 Windows 形式，ld.lld 是原生程序，读 /d/... 会当成 D:\d\...，
# 所以在这里自己转一次盘符。
printf '%s\n' $objects | sed 's|^/\([a-z]\)/|\1:/|' > "$OUT/generated/libc-objects.rsp"
ld.lld -shared -soname libc.so -z max-page-size=4096 -z now -z relro \
    --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
    --version-script "$OUT/generated/libc.map" -Map "$OUT/libc.map" --error-limit=0 \
    @"$OUT/generated/libc-objects.rsp" "$OUT/lib/libdl.so" "$OUT/bin/source-linker64" \
    "$builtins" -o "$OUT/lib/libc.so"
llvm-readelf -hlWd "$OUT/lib/libc.so" > "$OUT/libc-elf.txt"
llvm-nm -u "$OUT/lib/libc.so" > "$OUT/libc-undefined.txt"
llvm-readelf -hlWd "$OUT/lib/libdl.so" > "$OUT/libdl-elf.txt"
sha256sum "$OUT/lib/libc.so" "$OUT/lib/libdl.so" > "$OUT/dynamic-libraries.sha256"
