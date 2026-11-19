#!/bin/sh
# A10 原生产物共用的工具链定位，被 runtime/build-a10-runtime.sh 与 bridges/compile.sh 引用，
# 不单独执行，也不改调用方的 PATH 之外的任何东西。
#
# clang 系工具来自 NDK。PATH 上已经有 clang 就用现成的；否则按 A10_NDK、ANDROID_NDK_HOME、
# ANDROID_NDK_ROOT、SDK 下唯一版本依次找。SDK 下有多个版本时直接失败并列出候选，不替人挑，
# 因为挑错版本编出来的字节与符号跟镜像对不上，比报错更难查。

a10_ndk_host() {
    case "$(uname -s 2>/dev/null || echo Linux)" in
        MINGW*|MSYS*|CYGWIN*) printf '%s' windows-x86_64 ;;
        Darwin) printf '%s' darwin-x86_64 ;;
        *) printf '%s' linux-x86_64 ;;
    esac
}

# Windows 上这几个变量通常写成 C:\...，MSYS 的 test -d 认不了，先转成 /c/...。
a10_posix_path() {
    case "$1" in
        [A-Za-z]:[\\/]*)
            if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; return 0; fi ;;
    esac
    printf '%s' "$1"
}

# 成功时把 NDK 根目录打到 stdout，失败返回 1 并把原因打到 stderr。
a10_locate_ndk() {
    ndk=$(a10_posix_path "${A10_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}")
    host=$(a10_ndk_host)
    if [ -n "$ndk" ]; then
        if [ -d "$ndk/toolchains/llvm/prebuilt/$host/bin" ]; then
            printf '%s' "$ndk"
            return 0
        fi
        printf 'A10 工具链：%s 下没有 %s 工具链\n' "$ndk" "$host" >&2
        return 1
    fi
    for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        [ -n "$root" ] || continue
        root=$(a10_posix_path "$root")
        [ -d "$root/ndk" ] || continue
        versions=$(ls -1 "$root/ndk" 2>/dev/null || true)
        count=$(printf '%s\n' "$versions" | grep -c . || true)
        if [ "$count" = 1 ]; then
            printf '%s' "$root/ndk/$versions"
            return 0
        fi
        if [ "$count" -gt 1 ]; then
            printf 'A10 工具链：%s/ndk 下有多个版本，用 A10_NDK 指定：\n%s\n' "$root" "$versions" >&2
            return 1
        fi
    done
    printf 'A10 工具链：找不到 NDK，把路径给 A10_NDK 或 ANDROID_NDK_HOME\n' >&2
    return 1
}

# 把 NDK 的 clang 系工具接到 PATH 前头。PATH 上已有 clang 时什么都不做并把 A10_NDK_DIR 置空，
# 调用方据此显示"用现成的工具"。
a10_use_ndk_path() {
    A10_NDK_DIR=
    if command -v clang >/dev/null 2>&1; then
        return 0
    fi
    ndk=$(a10_locate_ndk) || return 1
    PATH="$ndk/toolchains/llvm/prebuilt/$(a10_ndk_host)/bin:$PATH"
    export PATH
    if ! command -v clang >/dev/null 2>&1; then
        printf 'A10 工具链：%s 里没有 clang\n' "$ndk" >&2
        return 1
    fi
    A10_NDK_DIR=$ndk
    return 0
}
