#!/bin/sh
# A10 的配套运行库：libm.so 与 libunwind.so，产物落 runtime/build/lib。
#
# 配方来自 vendor/runtime/companion 的 select-sources.py：它读 bionic/libm、
# external/arm-optimized-routines 与 external/libunwind_llvm 的 Android.bp，取出 srcs 与 flags。
# 这一份只编 math、optimized、unwind 三份配方，cxx 与 abi 不编：A10 的 libc++ 由镜像提供，
# 自建会多出第二份 libc++，而 837 个客体库都按镜像那份链接。
# libm 与 libunwind 必须自建：镜像里的 libm 绑的是镜像 libc，镜像里根本没有 libunwind.so，
# 而客体侧的 liba10binder 与 liba10vm-guest-devices 都依赖它。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RT="$MODULE/runtime"
SRC="$MODULE/vendor/runtime/companion"
OUT="$RT/build"
UP="$RT/upstream"
B="$UP/bionic/libc"
CACHE="$RT/compile-source.py"

PY=${PYTHON:-}
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else printf 'build-companion.sh: 找不到 python3 或 python\n' >&2; exit 1
    fi
fi
# 单元里的脚本写死 python3，这里用函数遮蔽，复制品一个字节都不改。
# PY 先换成绝对路径：遮蔽之后 "$PY" 若仍叫 python3 就会调回自己，递归到死。
PY=$(command -v "$PY" 2>/dev/null || printf '%s' "$PY")
python3() { "$PY" "$@"; }

for tool in clang clang++ ld.lld llvm-ar llvm-readelf llvm-nm git python3; do
    command -v "$tool" >/dev/null
done
unset LD_LIBRARY_PATH LD_PRELOAD
if [ ! -f "$OUT/lib/libc.so" ] || [ ! -f "$OUT/lib/libdl.so" ]; then
    printf 'build-companion.sh: 先跑 build-libc.sh，libm 与 libunwind 要链接源码 libc\n' >&2
    exit 1
fi

# s_sincosl 的 binary128 修正：上游在 iy != 0 的分支把 sine 结果写进了 *cs，这里只改这一行。
# 派生件落 build/derived，上游原件不动。
DERIVED="$OUT/derived/bionic/libm/upstream-freebsd/lib/msun/src"
mkdir -p "$DERIVED" "$OUT/obj/companion" "$OUT/companion" "$OUT/generated"
cp "$UP/bionic/libm/upstream-freebsd/lib/msun/src/k_sincosl.h" \
   "$UP/bionic/libm/upstream-freebsd/lib/msun/src/s_sincosl.c" "$DERIVED/"
git apply --recount --unsafe-paths --directory="$OUT/derived" "$SRC/platform.patch"

. "$SRC/compile.sh"
# -B：这个脚本要 import 单元里的 select-libc-sources.py，别在源码树里留 __pycache__。
"$PY" -B "$SRC/select-sources.py" "$UP" > "$OUT/companion/recipes.json"
"$PY" "$RT/recipes-to-sh.py" "$OUT/companion/recipes.json" > "$OUT/companion/recipes.sh"
. "$OUT/companion/recipes.sh"

builtins=$(clang --target=aarch64-linux-android29 --print-libgcc-file-name)
test -f "$builtins"
clang --version > "$OUT/companion/compiler.txt"

compile "$B/arch-common/bionic/crtbegin_so.c" "$OUT/obj/companion/crtbegin_so.o"
compile "$B/arch-common/bionic/crtend_so.S" "$OUT/obj/companion/crtend_so.o"

for recipe in math optimized unwind; do
    case "$recipe" in
        math)
            sources=$math_sources
            cppflags=
            flags="$math_flags -D_LIBC=1 -I$UP/bionic/libm -I$B/upstream-freebsd/android/include -Wno-macro-redefined -Wno-deprecated-non-prototype -Wno-implicit-const-int-float-conversion"
            includes=$math_includes
            ;;
        optimized)
            sources=$optimized_sources
            cppflags=
            flags="$optimized_flags -I$UP/external/arm-optimized-routines/math/include"
            includes=$optimized_includes
            ;;
        unwind)
            sources=$unwind_sources
            flags=$unwind_flags
            cppflags="$unwind_cppflags -D_LIBUNWIND_IS_NATIVE_ONLY -fno-rtti"
            includes=$unwind_includes
            ;;
    esac
    for directory in $includes; do flags="$flags -I$UP/$directory"; done
    objects=
    for path in $sources; do
        object="$OUT/obj/companion/$(printf '%s' "$path" | tr / _).o"
        case "$path" in
            bionic/libm/*.S) compile "$UP/$path" "$object" -D_LIBC=1 -Werror ;;
            */s_sincosl.c) compile "$DERIVED/s_sincosl.c" "$object" $flags -Wno-unused-but-set-variable ;;
            *.cpp|*.cc) compile "$UP/$path" "$object" $flags $cppflags ;;
            *) compile "$UP/$path" "$object" $flags ;;
        esac
        objects="$objects $object"
    done
    rm -f "$OUT/lib/liba10vm-$recipe.a"
    llvm-ar rcD "$OUT/lib/liba10vm-$recipe.a" $objects
done

# 版本脚本由上游工具生成，Windows 上写出来是 CRLF，ld.lld 会把 \r 当成名字的一部分。
"$PY" "$UP/bionic/tools/generate-version-script.py" arm64 "$UP/bionic/libm/libm.map.txt" \
    "$OUT/generated/libm.map.raw"
tr -d '\r' < "$OUT/generated/libm.map.raw" > "$OUT/generated/libm.map"

link_shared() {
    soname=$1
    shift
    ld.lld -shared -soname "$soname" -z max-page-size=4096 -z now -z relro \
        --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined \
        --exclude-libs "$(basename "$builtins")" \
        "$OUT/obj/companion/crtbegin_so.o" "$@" "$builtins" \
        "$OUT/obj/companion/crtend_so.o" -o "$OUT/lib/$soname"
    llvm-readelf -hlWd "$OUT/lib/$soname" > "$OUT/companion/$soname-elf.txt"
    llvm-nm -u "$OUT/lib/$soname" > "$OUT/companion/$soname-undefined.txt"
}

link_shared libm.so --version-script "$OUT/generated/libm.map" -Bsymbolic-functions \
    --whole-archive "$OUT/lib/liba10vm-math.a" "$OUT/lib/liba10vm-optimized.a" \
    --no-whole-archive "$OUT/lib/libc.so"
link_shared libunwind.so --whole-archive "$OUT/lib/liba10vm-unwind.a" \
    --no-whole-archive "$OUT/lib/libc.so" "$OUT/lib/libdl.so"
sha256sum "$OUT/lib/libm.so" "$OUT/lib/libunwind.so" > "$OUT/companion-libraries.sha256"
printf 'companion libraries finished\n  %s\n  %s\n' "$OUT/lib/libm.so" "$OUT/lib/libunwind.so"
