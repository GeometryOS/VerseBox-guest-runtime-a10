#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Stage A10-owned text inputs into runtime/build/data without touching prepared."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

MODULE = Path(__file__).resolve().parents[1]
MAPPINGS = (
    ("vendor/runtime-data/vintf/host-devices.xml", "rootfs/vendor/etc/vintf/manifest/a10vm-host-devices.xml"),
    ("vendor/runtime-data/vintf/media-codec.xml", "rootfs/vendor/etc/vintf/manifest/a10vm-media-codec.xml"),
    ("vendor/runtime-data/vintf/image-sensors.xml", "rootfs/vendor/etc/vintf/manifest/android.hardware.sensors@2.0.xml"),
    ("vendor/runtime-data/vintf/image-gnss.xml", "rootfs/vendor/etc/vintf/manifest/android.hardware.gnss@2.0-service.xml"),
    ("vendor/runtime-data/seccomp/media-transport.policy", "rootfs/vendor/etc/seccomp_policy/mediacodec.policy"),
    ("guest-data/system/bin/a10vm-boot-check", "rootfs/system/bin/a10vm-boot-check"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage A10 text data")
    parser.add_argument("--output", type=Path, default=MODULE / "runtime/build/data")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    if args.plan_only:
        print("output:", args.output)
        for source, target in MAPPINGS:
            print(source, "->", target)
        return 0
    for source, target in MAPPINGS:
        source_path = MODULE / source
        target_path = args.output / target
        if not source_path.is_file():
            raise SystemExit("missing source: " + str(source_path))
        target_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_path, target_path)
        if target_path.read_bytes() != source_path.read_bytes():
            raise SystemExit("copy verification failed: " + target)
    print("staged text files:", len(MAPPINGS), "under", args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
