#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""把媒体七件要链接的 ARM64 库从 rootfs 里抽出来，按 DT_NEEDED 递推补齐。

媒体七件不是自成一体的产物：它们链接的是镜像里的 libstagefright、libmedia、libgui 等一整套。
这些库必须与客体里跑的那份一致，所以只从 rootfs 取，不从 NDK 或别的域取。

产物：runtime/build/media/lib/<名字>.so 与同目录 dependencies.json（每件的来源与 sha256）。

用法（在 guest-runtime-a10 根目录）：

    python runtime/media-deps.py
    python runtime/media-deps.py --check
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOTFS = os.path.join(MODULE, "rootfs")
OUT = os.path.join(MODULE, "runtime", "build", "media", "lib")
MANIFEST = os.path.join(MODULE, "runtime", "build", "media", "dependencies.json")
READELF = "llvm-readelf"

# 起点：媒体七件直接要的那几组，rest 由 DT_NEEDED 递推补齐。
SEEDS = (
    "libbase libaudioclient libbinder libcamera_client libcodec2_client libcrypto libcutils "
    "libdl libgui libhidlbase libhidltransport libhidlmemory liblog libmedia libmedia_omx "
    "libmediadrm libmediametrics libmediautils libmemunreachable libnetd_client libpowermanager "
    "libstagefright libstagefright_foundation libstagefright_omx libutils libui libselinux "
    "libandroidicu libmediandk libavservices_minijail libc++ libc libm libunwind "
    "android.hardware.media.c2@1.0 android.hardware.media.omx@1.0 "
    "android.hardware.cas@1.0 android.hardware.cas.native@1.0 "
    "android.hidl.allocator@1.0 android.hidl.memory@1.0"
).split()

SEARCH = (
    "system/lib64",
    "system/lib64/vndk-29",
    "system/lib64/vndk-sp-29",
    "vendor/lib64",
    "system/apex/com.android.runtime.debug/lib64",
    "system/apex/com.android.media/lib64",
    "system/apex/com.android.media.swcodec/lib64",
    "system/apex/com.android.conscrypt/lib64",
    "system/apex/com.android.resolv/lib64",
    "system/apex/com.android.tzdata/lib64",
)


# 这四件由本仓库的运行时闭包提供，不从镜像取：桥在链接时用 runtime/build/lib 的那份，
# 客体里部署的也是同一份。
FROM_RUNTIME = ("libc.so", "libdl.so", "libm.so", "libunwind.so")


def locate(name):
    for relative in SEARCH:
        candidate = os.path.join(ROOTFS, relative.replace("/", os.sep), name)
        if os.path.isfile(candidate):
            return candidate
    return None


def needed(path):
    text = subprocess.run([READELF, "-d", path], capture_output=True, text=True, check=True).stdout
    return re.findall(r"Shared library: \[(.*?)\]", text)


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description="抽取媒体七件的 ARM64 链接依赖")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    if not os.path.isdir(ROOTFS):
        print("缺 rootfs，先跑 scripts/fetch-redroid10.py 与 scripts/extract-rootfs.py")
        return 1
    os.makedirs(OUT, exist_ok=True)
    pending = [name + ".so" for name in SEEDS]
    seen, records, missing = set(), [], []
    while pending:
        name = pending.pop(0)
        if name in seen:
            continue
        seen.add(name)
        if name in FROM_RUNTIME:
            continue
        source = locate(name)
        if source is None:
            missing.append(name)
            continue
        target = os.path.join(OUT, name)
        if not (os.path.isfile(target) and digest(target) == digest(source)):
            shutil.copyfile(source, target)
        records.append({"name": name, "source": os.path.relpath(source, MODULE).replace(os.sep, "/"),
                        "sha256": digest(target)})
        pending.extend(needed(target))
    with open(MANIFEST, "w", encoding="utf-8") as handle:
        json.dump(records, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print("deps=%d missing=%d %s" % (len(records), len(missing), MANIFEST))
    if missing:
        print("  缺 %s" % "、".join(sorted(missing)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
