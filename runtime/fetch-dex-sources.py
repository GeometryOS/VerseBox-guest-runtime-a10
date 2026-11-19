#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""按钉住的提交取 LineageOS 的 art 源码，只要 libdexfile、libartbase、libartpalette 三个目录。

dex-cache 单元换的是客体里的 libdexfile：`cache.patch` 打在这份源码上，编出带
`DexArchiveCache` 的那一份。提交是 `2311566b…`，通过 GitHub 的 tar.gz 接口按提交取，
不用 clone，也就不需要整条历史。

产物：runtime/build/dex/upstream/art/{libdexfile,libartbase,libartpalette} 与同目录的 COMMIT。

用法（在 guest-runtime-a10 根目录）：

    python runtime/fetch-dex-sources.py
    python runtime/fetch-dex-sources.py --check
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import urllib.request

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "2311566b9f24023b84501b8429c40c69f6f6be23"
URL = "https://codeload.github.com/LineageOS/android_art/tar.gz/" + COMMIT
ROOT = os.path.join(MODULE, "runtime", "build", "dex")
UPSTREAM = os.path.join(ROOT, "upstream")
ART = os.path.join(UPSTREAM, "art")
MARKER = os.path.join(ART, "COMMIT")


def download(url, target):
    partial = target + ".part"
    with urllib.request.urlopen(url, timeout=600) as response, open(partial, "wb") as sink:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            sink.write(chunk)
    os.replace(partial, target)


def main(argv=None):
    parser = argparse.ArgumentParser(description="取 LineageOS art 的 dex 子树")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    if os.path.isfile(MARKER):
        with open(MARKER, encoding="utf-8") as handle:
            recorded = handle.read().strip()
        if recorded == COMMIT:
            print("art 已在位，提交 %s" % COMMIT)
            return 0
        print("art 在位但提交不符（%s），先删 %s" % (recorded, ART))
        return 1
    if args.check:
        print("缺少 %s" % MARKER)
        return 1
    os.makedirs(ROOT, exist_ok=True)
    archive = os.path.join(ROOT, "android_art-%s.tar.gz" % COMMIT)
    if not os.path.isfile(archive):
        print("下载 %s" % URL, flush=True)
        download(URL, archive)
    with open(archive, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    print("archive sha256 %s" % digest, flush=True)
    staging = os.path.join(ROOT, "extract")
    os.makedirs(staging, exist_ok=True)
    subprocess.run(["tar", "-xzf", archive, "-C", staging], check=True)
    inner = os.path.join(staging, "android_art-" + COMMIT)
    if not os.path.isdir(inner):
        found = [name for name in os.listdir(staging) if os.path.isdir(os.path.join(staging, name))]
        if not found:
            print("解出来的目录里没有源码", file=sys.stderr)
            return 1
        inner = os.path.join(staging, found[0])
    os.makedirs(ART, exist_ok=True)
    for name in ("libdexfile", "libartbase", "libartpalette", "tools"):
        source = os.path.join(inner, name)
        if os.path.isdir(source):
            subprocess.run(["cp", "-R", source, ART], check=True)
    with open(MARKER, "w", encoding="utf-8") as handle:
        handle.write(COMMIT + "\n")
    with open(os.path.join(ART, "ARCHIVE.sha256"), "w", encoding="utf-8") as handle:
        handle.write("%s  %s\n" % (digest, os.path.basename(archive)))
    print("art 就位：%s" % ART)
    return 0


if __name__ == "__main__":
    sys.exit(main())
