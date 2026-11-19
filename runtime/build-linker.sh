#!/bin/sh
# 私有 linker：ld-android.so，产物 runtime/build/bin/source-linker64。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RT="$MODULE/runtime"
SRC="$MODULE/vendor/runtime/dynamic"
FS="$MODULE/vendor/runtime/filesystem"
OUT="$RT/build"
UP="$RT/upstream"
B="$UP/bionic/libc"
D="$OUT/derived"
for tool in clang clang++ ld.lld llvm-ar llvm-readelf llvm-nm git python3; do command -v "$tool" >/dev/null; done
unset LD_LIBRARY_PATH LD_PRELOAD
sh "$RT/build-static.sh"
rm -rf "$D"
mkdir -p "$OUT/obj/linker" "$OUT/bin" "$OUT/generated" "$D/bionic/linker" "$D/build/tools/fs_config"
cp "$UP/build/tools/fs_config/fs_config_generator.py" "$D/build/tools/fs_config/"
cp "$UP/bionic/linker/linker.cpp" "$UP/bionic/linker/linker_main.cpp" \
    "$UP/bionic/linker/dlfcn.cpp" "$UP/bionic/linker/linker_config.cpp" \
    "$UP/bionic/linker/linker_phdr.cpp" "$UP/bionic/linker/linker_utils.cpp" "$D/bionic/linker/"
# 这份补丁的 hunk 头与正文行数对不上，git apply 会整份判成"无可应用"（退出码 0 却一个字节不改），
# GNU patch 在行数改正之后能逐块应用并打 fuzz，所以这里用它。
( cd "$D" && patch -t -p1 --no-backup-if-mismatch < "$SRC/platform.patch" )
# android_ids：AOSP 10 自带的生成器是 Python 2 语法，本机只有 Python 3。
# A9 的 runtime/gen-android-ids.py 就是为这件事写的，输出契约照上游，A15 用的是同一份，
# 所以这里复用它，不改上游工具。
python3 "$RT/gen-android-ids.py" \
    "$UP/system/core/libcutils/include/private/android_filesystem_config.h" \
    > "$OUT/generated/generated_android_ids.h"
builtins=$(clang --target=aarch64-linux-android29 --print-libgcc-file-name)
test -f "$builtins"
clang --version > "$OUT/linker-compiler.txt"
sha256sum "$builtins" > "$OUT/linker-builtins.sha256"
BUILD_KIND=linker
. "$RT/compile-platform.sh"
objects=
while read -r path; do
    object="$OUT/obj/linker/$(printf '%s' "$path" | tr / _).o"
    if [ -f "$D/$path" ]; then input="$D/$path"; else input="$UP/$path"; fi
    compile "$input" "$object" -I"$FS" -I"$SRC"
    objects="$objects $object"
done < "$SRC/linker-sources.txt"
object="$OUT/obj/linker/LinkerFileStat.o"
compile "$SRC/LinkerFileStat.cpp" "$object" -I"$FS"
objects="$objects $object"
support_objects=
. "$FS/sources.sh"
while read -r path; do
    if guest_fs_replaces "$path"; then continue; fi
    object="$OUT/obj/linker/$(printf '%s' "$path" | tr / _).o"
    compile "$UP/$path" "$object"
    support_objects="$support_objects $object"
done < "$SRC/support-sources.txt"
rm -f "$OUT/lib/liba10vm-linker-support.a"
llvm-ar rcD "$OUT/lib/liba10vm-linker-support.a" $support_objects
ld.lld -shared -e _start -Bsymbolic --exclude-libs ALL -soname ld-android.so \
    --gc-sections -z max-page-size=4096 -z now -z relro --hash-style=gnu \
    --eh-frame-hdr --build-id=sha1 --no-undefined \
    --version-script "$UP/bionic/linker/linker.generic.map" \
    -Map "$OUT/linker.map" --error-limit=0 \
    $objects --start-group "$OUT/lib/liba10vm-linker-support.a" \
    "$OUT/lib/liba10vm-bootstrap.a" "$builtins" --end-group \
    -o "$OUT/bin/source-linker64"
llvm-readelf -hlWd "$OUT/bin/source-linker64" > "$OUT/linker-elf.txt"
llvm-nm -u "$OUT/bin/source-linker64" > "$OUT/linker-undefined.txt"
