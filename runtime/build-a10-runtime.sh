#!/bin/sh
# A10 客体运行时的唯一入口：源码 → 运行时产物。
#
#   sh runtime/build-a10-runtime.sh              依次跑：取源 → 静态归档 → linker → libc → 配套库
#   sh runtime/build-a10-runtime.sh --plan-only  只打印每一步做什么、输入在不在、产物落在哪
#
# 本脚本只读本仓库：vendor/runtime/{dynamic,filesystem,companion}、vendor/properties、
# runtime/lists、runtime/upstream。不引用 app 仓库的任何路径，所以第三方只 clone 本仓库也能跑。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RT="$MODULE/runtime"
PLAN_ONLY=${A10_PLAN_ONLY:-0}
case "${1:-}" in
    --plan-only) PLAN_ONLY=1 ;;
    "") ;;
    *) printf 'usage: build-a10-runtime.sh [--plan-only]\n' >&2; exit 2 ;;
esac

PY=${PYTHON:-}
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else printf 'build-a10-runtime.sh: 找不到 python3 或 python\n' >&2; exit 1
    fi
fi

# 工具链定位与 bridges/compile.sh 共用一份，见 runtime/toolchain.sh。
. "$RT/toolchain.sh"
if ! a10_use_ndk_path; then
    printf 'build-a10-runtime.sh: 找不到 clang，把 NDK 指给 A10_NDK 或 ANDROID_NDK_HOME\n' >&2
    exit 1
fi
NDK_DIR=$A10_NDK_DIR

step() { printf '\n== %s\n' "$1"; }
state() { if [ -e "$2" ]; then printf '  %-12s %s\n' "$1" "$2"; else printf '  %-12s %s（缺）\n' "$1" "$2"; fi }

if [ "$PLAN_ONLY" = 1 ]; then
    step "plan-only"
    printf '  module       : %s\n' "$MODULE"
    printf '  interpreter  : %s\n' "$PY"
    printf '  archives     : %s\n' "$RT/lists/archives.txt"
    printf '  upstream     : %s\n' "$RT/upstream"
    printf '  build        : %s\n' "$RT/build"
    state "properties" "$MODULE/vendor/properties/sources.txt"
    state "static list" "$RT/lists/static-sources.txt"
    state "linker list" "$MODULE/vendor/runtime/dynamic/linker-sources.txt"
    state "filesystem"  "$MODULE/vendor/runtime/filesystem/sources.sh"
    printf '  ndk          : %s\n' "${NDK_DIR:-（PATH 上已有 clang）}"
    printf '  steps        : fetch-a10-sources -> build-static -> build-linker -> build-libc -> build-companion\n'
    printf '  products     : %s\n' "$RT/build/bin/source-linker64"
    printf '                 %s\n' "$RT/build/lib/libc.so libdl.so"
    printf '                 %s\n' "$RT/build/lib/libm.so libunwind.so"
    printf '  nothing was executed (plan-only).\n'
    exit 0
fi

step "fetch sources"
"$PY" "$RT/fetch-a10-sources.py"
step "static bootstrap archive"
sh "$RT/build-static.sh"
step "private linker"
sh "$RT/build-linker.sh"
step "libc and libdl"
sh "$RT/build-libc.sh"
step "companion libraries (libm, libunwind)"
sh "$RT/build-companion.sh"
printf '\nruntime build finished\n  %s\n  %s\n' "$RT/build/bin/source-linker64" "$RT/build/lib"
