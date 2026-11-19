#!/bin/sh
# 属性服务的派生树：把 vendor/properties/sources.txt 取到的文件复制成可编译的 bionic/ 与 core/，
# 再打上 platform.patch 与 runtime.patch。产物落 runtime/build/properties/derived。
set -eu
MODULE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$MODULE/vendor/properties"
OUT="$MODULE/runtime/build/properties"
D="$OUT/derived"
for tool in git; do command -v "$tool" >/dev/null; done
python3 "$MODULE/runtime/fetch-properties.py"
rm -rf "$D"
mkdir -p "$D"
cp -R "$OUT/upstream/bionic" "$OUT/upstream/core" "$D/"
git apply --recount --unsafe-paths --directory="$D" "$SRC/platform.patch"
git apply --recount --unsafe-paths --directory="$D" "$SRC/runtime.patch"
# git apply 在 hunk 头与正文对不上时退出 0 却一个字节不改。少了这三处标记，编出的 libc
# 会去读宿主的 /dev/__properties__，客体的 ro.build.version.sdk 就变成宿主的值，
# 框架入口的 SDK 断言会当场炸掉，而构建日志一路是绿的。
grep -q 'A10VM_PROPERTIES' "$D/bionic/libc/bionic/system_property_api.cpp" \
    && grep -q 'ContextsSerialized' "$D/bionic/libc/system_properties/system_properties.cpp" \
    && grep -q 'LoadPath(info_path)' "$D/bionic/libc/system_properties/contexts_serialized.cpp" \
    || { echo "properties 补丁没有落到派生树，拒绝继续" >&2; exit 1; }
