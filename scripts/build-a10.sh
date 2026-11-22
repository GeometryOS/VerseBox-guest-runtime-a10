#!/bin/sh
# Android 10 运行时仓库的一条链：prepared → ROM 包 → APK 侧 payload。
#
#   scripts/build-a10.sh                 # prepared（参考 APK）→ ROM 包 → prepared-apk
#   scripts/build-a10.sh --from-sources  # rootfs + A10 源生成 prepared → ROM 包 → prepared-apk
#   scripts/build-a10.sh --skip-extract   # 只跳过 prepared，复用 prepared/（改过 rom/ 配置时用这个）
#   scripts/build-a10.sh --skip-rom       # 只出 prepared 与 prepared-apk，不产 zip
#   scripts/build-a10.sh --rom-version 1.1.0 --lib-mode rom
#   scripts/build-a10.sh --plan-only      # 只打印要跑的段与产物路径，一步都不执行
#
# A10 的 prepared 当前从参考 APK 或 app 仓库的 runtime-inputs 保真抽取。
# 打包器与 stager 都在本仓库 rom/ 里，A9/A15 的脚本一律不引用（三个独立仓库）。
# 本脚本不跑 Gradle：APK 由 app 仓库消费 prepared-apk/ 编出来。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
# 仓库父目录：参考 APK 的默认位置在它的 _bin/ 下，只 clone 本仓库时这个文件不存在。
: "${ROOT:=$(CDPATH= cd -- "$MODULE/.." && pwd)}"
cd "$MODULE"

# 解释器探测：ubuntu-24.04 与部分发行版只有 python3，写死 python 会让第一步就失败。
# PYTHON 可以覆盖，便于在只有解释器别名不同的机器上复现。
PY=${PYTHON:-}
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else printf 'build-a10.sh: 找不到 python3 或 python，可用 PYTHON=... 指定\n' >&2; exit 1
    fi
fi

step() { printf '\n== %s\n' "$1"; }
SKIP_EXTRACT=0
SKIP_ROM=0
FROM_SOURCES=0
PLAN_ONLY=${A10_PLAN_ONLY:-0}
LIB_MODE=
ROM_VERSION=
APK=
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-extract) SKIP_EXTRACT=1 ;;
        --from-sources) FROM_SOURCES=1 ;;
        --skip-rom) SKIP_ROM=1 ;;
        --rom-version) shift; ROM_VERSION=${1:?--rom-version 需要参数} ;;
        --lib-mode) shift; LIB_MODE=${1:?--lib-mode 需要参数} ;;
        --apk) shift; APK=${1:?--apk 需要参数} ;;
        --plan-only) PLAN_ONLY=1 ;;
        -h|--help)
            printf 'usage: build-a10.sh [--from-sources] [--skip-extract] [--skip-rom] [--rom-version X.Y.Z] [--lib-mode apk|rom|both] [--apk PATH] [--plan-only]\n'
            printf '\n'
            printf '  --from-sources  从 rootfs 和 A10 源生成 prepared，不读取参考 APK\n'
            printf '  --skip-extract  只跳过 prepared 这一步，复用现有 prepared/；ROM 包与 prepared-apk 照常重做\n'
            printf '  --skip-rom      不产 ROM 包，只出 prepared 与 prepared-apk\n'
            printf '  --rom-version   覆盖 rom/rom.properties.yaml 的 defaultRomVersion\n'
            printf '  --lib-mode      覆盖 libMode，取值 apk、rom、both\n'
            printf '  --apk           prepared 的参考 APK 路径，默认 <仓库父目录>/_bin/A10VM.apk\n'
            printf '  --plan-only     只打印要跑的段与产物路径，一步都不执行；A10_PLAN_ONLY=1 同义\n'
            printf '\n'
            printf 'APK 由 app 仓库消费 prepared-apk/ 编出，本脚本不跑 Gradle。\n'
            exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

for tool in rom/pack-rom.py rom/stage-apk-payload.py scripts/extract-a10-inputs.py; do
    if [ ! -f "$tool" ]; then
        printf '\n! 缺少本仓库的工具：%s\n' "$tool" >&2
        exit 1
    fi
done

# ROM 身份与输出路径：命令行与环境变量优先，其次 rom/rom.properties.yaml。
ROM_ID=$(sed -n 's/^id:[[:space:]]*//p' rom/rom.properties.yaml 2>/dev/null | head -n 1 || true)
ROM_DEFAULT_VERSION=$(sed -n 's/^defaultRomVersion:[[:space:]]*//p' rom/rom.properties.yaml 2>/dev/null | head -n 1 || true)
ROM_VERSION=${ROM_VERSION:-$ROM_DEFAULT_VERSION}
ROM_OUT=${ROM_OUT:-dist/$ROM_ID@$ROM_VERSION/versebox-$ROM_ID-$ROM_VERSION.zip}

# --plan-only / A10_PLAN_ONLY=1：只打印要跑的段与产物路径，一步都不执行。
# 排障时先看这一段，能确认会不会动 prepared、产物落在哪、停在哪个仓库。
if [ "$PLAN_ONLY" = 1 ]; then
    step "plan-only"
    printf '  module        : %s\n' "$MODULE"
    printf '  ROM identity  : %s %s\n' "${ROM_ID:-（未读到）}" "${ROM_VERSION:-（未读到）}"
    if [ "$SKIP_EXTRACT" = 1 ]; then
        printf '  prepared      : 复用 %s/prepared（--skip-extract）\n' "$MODULE"
    elif [ "$FROM_SOURCES" = 1 ]; then
        printf '  prepared      : rootfs + A10 source generators -> prepare-a10.py --apply\n'
    else
        if [ -n "$APK" ]; then
            prepare_source=$APK
            prepare_kind='参考 APK'
        elif [ -f ../runtime-inputs/guest-runtime/assets/guest-runtime-inputs.json ]; then
            prepare_source=$(CDPATH= cd -- ../runtime-inputs/guest-runtime && pwd)
            prepare_kind=runtime-inputs
        else
            prepare_source=$ROOT/_bin/A10VM.apk
            prepare_kind='参考 APK'
        fi
        if [ -e "$prepare_source" ]; then prepare_state=存在; else prepare_state=缺失; fi
        printf '  prepared      : %s（%s，%s）\n' "$prepare_source" "$prepare_kind" "$prepare_state"
    fi
    if [ "$SKIP_ROM" = 1 ]; then
        printf '  ROM package   : 跳过（--skip-rom）\n'
    else
        printf '  ROM package   : %s\n' "$ROM_OUT"
    fi
    printf '  APK payload   : %s/prepared-apk（旧格式 assets/guest-runtime/lib/**）\n' "$MODULE"
    printf '  image chain   : scripts/fetch-redroid10.py -> scripts/extract-rootfs.py（source mode requires rootfs ready）\n'
    printf '  APK           : 由 app 仓库消费 prepared-apk/ 编出，本脚本不跑 Gradle\n'
    printf '  nothing was executed (plan-only).\n'
    exit 0
fi

if [ "$SKIP_EXTRACT" = 1 ]; then
    step "prepared: 复用现有（--skip-extract）"
    if [ ! -f prepared/assets/guest-runtime-inputs.json ]; then
        printf '! prepared 不存在，去掉 --skip-extract 先跑抽取\n' >&2
        exit 1
    fi
elif [ "$FROM_SOURCES" = 1 ]; then
    step "A10 source chain: runtime data, DEX and services.jar"
    sh scripts/build-a10-data.sh
    step "prepared（rootfs + A10 source outputs → prepared/）"
    "$PY" scripts/prepare-a10.py --apply
else
    step "prepared（参考 APK → prepared/）"
    if [ -n "$APK" ]; then
        "$PY" scripts/extract-a10-inputs.py --apk "$APK"
    elif [ -f ../runtime-inputs/guest-runtime/assets/guest-runtime-inputs.json ]; then
        # app 仓库已经把参考 APK 解过一次：直接搬，省 1.4 GB 的解包。
        # 判据是清单在不在，不是目录在不在：空目录会把来源抢走，然后 prepared 先被清掉再报错。
        "$PY" scripts/extract-a10-inputs.py --from-runtime-inputs ../runtime-inputs/guest-runtime
    else
        "$PY" scripts/extract-a10-inputs.py
    fi
fi

if [ "$SKIP_ROM" = 1 ]; then
    step "ROM package: skipped (--skip-rom)"
else
    step "ROM package ($ROM_OUT)"
    # prepared/assets 里除了本域清单，还有一份 native-display 的宿主清单，pack-rom 不会替你挑，
    # 所以这里显式指定；少这一行，打包容错成"无法自动确定清单"。
    set -- --prepared prepared --probe guest-runtime-inputs.json         --properties rom/rom.properties.yaml --out "$ROM_OUT"
    if [ -n "$LIB_MODE" ]; then set -- "$@" --lib-mode "$LIB_MODE"; fi
    GIT_REV=$(git rev-parse --short HEAD 2>/dev/null || true)
    if [ -n "$GIT_REV" ]; then set -- "$@" --git-rev "$GIT_REV"; fi
    "$PY" rom/pack-rom.py "$@"
    step "ROM package self-check"
    "$PY" rom/pack-rom.py --verify-only "$ROM_OUT"
fi

step "APK payload（旧格式：assets/guest-runtime/lib/**）"
"$PY" rom/stage-apk-payload.py --prepared prepared --out prepared-apk \
    --manifest guest-runtime-inputs.json --prefix guest-runtime/

printf '\nbuild finished\n  prepared     : %s/prepared\n  APK payload  : %s/prepared-apk\n  ROM package  : %s\n' \
    "$MODULE" "$MODULE" "$( [ "$SKIP_ROM" = 1 ] && echo '（已跳过）' || echo "$MODULE/$ROM_OUT" )"
printf '  APK          : 由 app 仓库消费 prepared-apk/ 编出，本脚本不跑 Gradle\n'
