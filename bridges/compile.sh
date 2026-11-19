#!/bin/sh
# A10 客体桥的公共编译环境，被 bridges/build-*.sh 引用，不单独执行。
#
# 编译参数与链接对象跟 runtime/build 那一套对齐：头来自 runtime/upstream 的 bionic，
# 链接 runtime/build/lib 里自建的 libc、libdl、libm、libunwind，C++ 用镜像里的 libc++。
# 自建 libc++ 会多出第二份，而客体里 837 个库都按镜像那份链接。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
# Git Bash 会把像 Unix 路径的参数改写成 Windows 路径，-dynamic-linker 后面的 /system 要原样留下。
export MSYS2_ARG_CONV_EXCL='/system'
BR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$MODULE/bridges"
RT="$MODULE/runtime"
UP="$RT/upstream"
B="$UP/bionic/libc"
CACHE="$RT/compile-source.py"
TARGET=aarch64-linux-android29

PY=${PYTHON:-}
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else printf 'bridges/compile.sh: 找不到 python3 或 python\n' >&2; exit 1
    fi
fi
# 单元里的脚本写死 python3，这里用函数遮蔽，复制品一个字节都不改。
# PY 先换成绝对路径：遮蔽之后 "$PY" 若仍叫 python3 就会调回自己，递归到死。
PY=$(command -v "$PY" 2>/dev/null || printf '%s' "$PY")
python3() { "$PY" "$@"; }

. "$RT/toolchain.sh"
if ! a10_use_ndk_path; then
    exit 1
fi
unset LD_LIBRARY_PATH LD_PRELOAD || true

LIBC="$RT/build/lib/libc.so"
LIBDL="$RT/build/lib/libdl.so"
LIBM="$RT/build/lib/libm.so"
LIBUNWIND="$RT/build/lib/libunwind.so"
LINKER="$RT/build/bin/source-linker64"
LIBCXX="$MODULE/rootfs/system/lib64/libc++.so"
for product in "$LIBC" "$LIBDL" "$LIBM" "$LIBUNWIND" "$LINKER"; do
    if [ ! -f "$product" ]; then
        printf 'bridges/compile.sh: 缺 %s，先跑 sh runtime/build-a10-runtime.sh\n' "$product" >&2
        exit 1
    fi
done
if [ ! -f "$LIBCXX" ]; then
    printf 'bridges/compile.sh: 缺 %s，先跑 scripts/fetch-redroid10.py 与 scripts/extract-rootfs.py\n' "$LIBCXX" >&2
    exit 1
fi
BUILTINS=$(clang --target=$TARGET --print-libgcc-file-name)

mkdir -p "$OUT/lib" "$OUT/bin" "$OUT/obj" "$OUT/generated" "$OUT/derived"

# 单元里的 compile() 是通用编译函数，参数由各单元的 compile.sh 在它之上叠加。
. "$MODULE/vendor/runtime/companion/compile.sh"

# 共享库与可执行文件的 crt 由 bionic 源码编出，与运行时闭包用同一份。
crt_so() {
    mkdir -p "$OUT/obj/crt"
    if [ ! -f "$OUT/obj/crt/crtbegin_so.o" ]; then
        compile "$B/arch-common/bionic/crtbegin_so.c" "$OUT/obj/crt/crtbegin_so.o"
        compile "$B/arch-common/bionic/crtend_so.S" "$OUT/obj/crt/crtend_so.o"
    fi
}

crt_pie() {
    mkdir -p "$OUT/obj/crt"
    if [ ! -f "$OUT/obj/crt/crtbegin.o" ]; then
        compile "$B/arch-common/bionic/crtbegin.c" "$OUT/obj/crt/crtbegin.o"
        compile "$B/arch-common/bionic/crtend.S" "$OUT/obj/crt/crtend.o"
    fi
}

# link_shared <soname> <输出目录> <对象...>
link_shared() {
    soname=$1
    directory=$2
    shift 2
    mkdir -p "$directory"
    ld.lld -shared -soname "$soname" -z max-page-size=4096 -z now -z relro \
        --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
        "$OUT/obj/crt/crtbegin_so.o" "$@" "$BUILTINS" \
        "$OUT/obj/crt/crtend_so.o" -o "$directory/$soname"
    llvm-readelf -hlWd "$directory/$soname" > "$directory/$soname.elf.txt"
    llvm-nm -u "$directory/$soname" > "$directory/$soname.undefined.txt"
}
