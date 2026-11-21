#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Generate A10 guest.prop from the extracted rootfs and A10 override source."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

MODULE = Path(__file__).resolve().parents[1]
SOURCES = (
    "system/etc/prop.default", "odm/etc/prop.default", "vendor/default.prop",
    "system/build.prop", "vendor/build.prop", "odm/etc/build.prop",
    "odm/build.prop", "system/product/build.prop", "system/product_services/build.prop",
)
PRODUCT_ORDER = ("product", "product_services", "odm", "vendor", "system")


def parse(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, separator, value = line.partition("=")
        name, value = name.strip(), value.strip()
        if not separator or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("Invalid property: " + line)
        result[name] = value
    return result


def merge(rootfs: Path, override: Path) -> dict[str, str]:
    properties = {}
    for relative in SOURCES:
        source = rootfs / relative
        if not source.is_file() and relative.startswith("odm/"):
            source = rootfs / "vendor" / relative
        if source.is_file():
            properties.update(parse(source.read_text(encoding="utf-8")))
    properties.update(parse(override.read_text(encoding="utf-8")))
    order = properties.get("ro.product.property_source_order", ",".join(PRODUCT_ORDER)).split(",")
    if not order or any(item not in PRODUCT_ORDER for item in order):
        order = list(PRODUCT_ORDER)
    for field in ("brand", "device", "manufacturer", "model", "name"):
        name = "ro.product." + field
        if properties.get(name):
            continue
        for partition in order:
            value = properties.get("ro.product." + partition + "." + field)
            if value:
                properties[name] = value
                break
    if not properties.get("ro.build.fingerprint"):
        get = lambda name: properties.get(name) or "unknown"
        properties["ro.build.fingerprint"] = (
            get("ro.product.brand") + "/" + get("ro.product.name") + "/" + get("ro.product.device")
            + ":" + get("ro.build.version.release") + "/" + get("ro.build.id") + "/"
            + get("ro.build.version.incremental") + ":" + get("ro.build.type") + "/" + get("ro.build.tags"))
    return properties


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate A10 merged guest.prop")
    parser.add_argument("--rootfs", type=Path, default=MODULE / "rootfs")
    parser.add_argument("--override", type=Path, default=MODULE / "vendor/runtime-data/guest.prop")
    parser.add_argument("--output", type=Path, default=MODULE / "runtime/build/data/guest.prop")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    if args.plan_only:
        print("rootfs:", args.rootfs)
        print("override:", args.override)
        print("output:", args.output)
        print("property sources:", len(SOURCES))
        return 0
    values = merge(args.rootfs, args.override)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes("".join(name + "=" + value + "\n" for name, value in sorted(values.items())).encode("utf-8"))
    print("guest.prop:", args.output, "bytes:", args.output.stat().st_size, "properties:", len(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
