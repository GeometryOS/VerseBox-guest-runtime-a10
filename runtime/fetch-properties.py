#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""按 vendor/properties/sources.txt 逐个文件取属性服务的上游源。

properties 只用到 bionic 与 system/core 里的 28 个文件，整棵子树取下来浪费带宽，
所以这里按 gitiles 的单文件接口取，落到 runtime/build/properties/upstream/。
取完按 vendor/properties/sources.sha256 逐文件校验，不符就失败。

用法（在 guest-runtime-a10 根目录）：

    python runtime/fetch-properties.py
    python runtime/fetch-properties.py --check
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import sys
import urllib.request

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST = os.path.join(MODULE, "vendor", "properties", "sources.txt")
MANIFEST = os.path.join(MODULE, "vendor", "properties", "sources.sha256")
OUT = os.path.join(MODULE, "runtime", "build", "properties", "upstream")
BASES = {
    "bionic": "https://android.googlesource.com/platform/bionic/+/290c0cb5044b643e5d6cbcb1a5b275541ca3a89e",
    "core": "https://android.googlesource.com/platform/system/core/+/1dea9a052b7f214c10a77d5ed6ffd3602722a817",
}


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return base64.b64decode(response.read())


def main(argv=None):
    parser = argparse.ArgumentParser(description="取属性服务的上游源")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    fetched = skipped = 0
    with open(LIST, encoding="utf-8") as handle:
        entries = [line.split() for line in handle if line.strip()]
    for repository, relative in entries:
        destination = os.path.join(OUT, repository, relative.replace("/", os.sep))
        if os.path.isfile(destination) and os.path.getsize(destination) > 0:
            skipped += 1
            continue
        if args.check:
            print("缺少 %s/%s" % (repository, relative))
            continue
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        data = fetch(BASES[repository] + "/" + relative + "?format=TEXT")
        with open(destination, "wb") as sink:
            sink.write(data)
        fetched += 1
    checked = bad = 0
    with open(MANIFEST, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            digest, name = line.split("  ", 1)
            path = os.path.join(OUT, name.replace("/", os.sep))
            if not os.path.isfile(path):
                bad += 1
                continue
            with open(path, "rb") as handle_read:
                if hashlib.sha256(handle_read.read()).hexdigest() != digest:
                    bad += 1
            checked += 1
    print("files=%d fetched=%d skipped=%d verified=%d bad=%d"
          % (len(entries), fetched, skipped, checked, bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
