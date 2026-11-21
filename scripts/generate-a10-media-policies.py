#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Generate Android 10 media seccomp policy data from AOSP sources."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

MODULE = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate A10 media policy data")
    parser.add_argument("--upstream", type=Path, default=MODULE / "runtime/upstream")
    parser.add_argument("--transport", type=Path, default=MODULE / "vendor/runtime-data/seccomp/media-transport.policy")
    parser.add_argument("--output", type=Path, default=MODULE / "runtime/build/data")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    mediaextractor = args.upstream / "frameworks/av/services/mediaextractor/seccomp_policy/mediaextractor-arm64.policy"
    mediaswcodec = args.upstream / "frameworks/av/services/mediacodec/seccomp_policy/mediaswcodec-arm64.policy"
    outputs = {
        "rootfs/system/etc/seccomp_policy/mediacodec.policy": mediaswcodec,
        "rootfs/vendor/etc/seccomp_policy/mediaextractor.policy": args.transport,
        "rootfs/vendor/etc/seccomp_policy/mediaswcodec.policy": args.transport,
        "rootfs/vendor/etc/seccomp_policy/mediacodec.policy": args.transport,
    }
    if args.plan_only:
        print("upstream:", args.upstream)
        print("transport:", args.transport)
        for target, source in outputs.items(): print(source, "->", target)
        return 0
    if not mediaextractor.is_file() or not mediaswcodec.is_file():
        raise SystemExit("missing AOSP 10 media seccomp source")
    if not args.transport.is_file():
        raise SystemExit("missing media transport policy")
    # Reading mediaextractor here is an input check: the legacy pipeline verifies this
    # source even though the private transport policy is the installed vendor payload.
    mediaextractor.read_bytes()
    for target, source in outputs.items():
        destination = args.output / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        if destination.read_bytes() != source.read_bytes():
            raise SystemExit("copy verification failed: " + target)
    print("media policies:", len(outputs), "under", args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
