#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Generate the A10 system-image path catalog from rootfs-index.json."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1]
# These are the root-level virtual directories present in the Android image inventory.
# extract-rootfs records only materialized image entries, so the inventory keeps these
# paths as stable namespace roots for the guest system image.
VIRTUAL_ROOTS = (
    "lost+found", "acct", "bugreports", "cache", "config", "d", "data", "dev",
    "metadata", "mnt", "postinstall", "proc", "sdcard", "storage", "sys",
)
PROJECT_PATHS = (
    "system/bin/a10vm-boot-check",
    "a10vm-init",
    "ipc",
)


def generate(index: Path) -> list[dict[str, str]]:
    data = json.loads(index.read_text(encoding="utf-8"))
    entries = data.get("entries")
    if not isinstance(entries, dict):
        raise ValueError("rootfs-index.json has no entries map")
    # Keep the extracted rootfs index order and insert the project inventory entries
    # at the same anchors used by the legacy image inventory.
    ordered = ["/" + name for name in entries]
    insertions = {
        "/lost+found": None, "/acct": "/lost+found", "/bugreports": "/bin",
        "/cache": "/bugreports", "/config": "/charger", "/d": "/config",
        "/data": "/d", "/dev": "/default.prop", "/metadata": "/init.zygote64_32.rc",
        "/mnt": "/metadata", "/postinstall": "/oem", "/proc": "/postinstall",
        "/sdcard": "/sbin", "/storage": "/sdcard", "/sys": "/storage",
        "/system/bin/a10vm-boot-check": "/system/bin/zcat",
    }
    for value, anchor in insertions.items():
        if value in ordered:
            continue
        if anchor is None:
            ordered.insert(0, value)
        else:
            position = ordered.index(anchor) + 1 if anchor in ordered else len(ordered)
            ordered.insert(position, value)
    ordered.extend(["/a10vm-init", "/ipc"])
    return [{"path": name} for name in ordered]


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate A10 system image path catalog")
    parser.add_argument("--index", type=Path, default=MODULE / "rootfs-index.json")
    parser.add_argument("--output", type=Path, default=MODULE / "runtime/build/data/system-image-paths.json")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    paths = generate(args.index)
    if args.plan_only:
        print("index:", args.index)
        print("output:", args.output)
        print("paths:", len(paths))
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes((json.dumps(paths, ensure_ascii=False) + "\n").encode("utf-8"))
    print("system-image-paths.json:", args.output, "bytes:", args.output.stat().st_size, "paths:", len(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
