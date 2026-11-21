#!/bin/sh
# A10 S5 data-only chain: source text + merged guest.prop + system-image paths.
# This script writes runtime/build/data and never modifies prepared/ or the legacy runtime.
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$MODULE"
PY=${PYTHON:-}
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else printf 'build-a10-data.sh: missing python3 or python\n' >&2; exit 1
    fi
fi
PLAN_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --plan-only) PLAN_ONLY=1 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done
if [ "$PLAN_ONLY" = 1 ]; then
    printf 'module: %s\n' "$MODULE"
    printf 'output: %s/runtime/build/data\n' "$MODULE"
    printf 'steps: stage-a10-text-data -> generate-a10-media-policies -> generate-a10-guest-prop -> generate-a10-system-image-paths\n'
    printf 'nothing was executed (plan-only).\n'
    exit 0
fi
"$PY" scripts/stage-a10-text-data.py
"$PY" scripts/generate-a10-media-policies.py
"$PY" scripts/generate-a10-guest-prop.py
"$PY" scripts/generate-a10-system-image-paths.py
printf 'A10 data build finished: %s/runtime/build/data\n' "$MODULE"
