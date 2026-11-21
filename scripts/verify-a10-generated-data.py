#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Verify A10-generated runtime data against the source inventory."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

MODULE = Path(__file__).resolve().parents[1]
PREPARE = MODULE / "scripts" / "prepare-a10.py"
INVENTORY = MODULE / "prebuilt" / "a10-guest-runtime-inputs.json"


def load_prepare():
    spec = importlib.util.spec_from_file_location("a10_prepare", PREPARE)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + str(PREPARE))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    prepare = load_prepare()
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    entries = {item["name"]: item for item in inventory.get("data", [])}
    checked = []
    for name, relative in prepare.GENERATED_DATA.items():
        entry = entries.get(name)
        if entry is None:
            raise SystemExit("generated mapping missing from identity table: " + name)
        source = MODULE / relative
        if not prepare.matches(str(source), entry):
            raise SystemExit("generated data does not match bytes/sha256: " + name)
        checked.append(name)
    if len(checked) != 14:
        raise SystemExit("expected 14 verified generated data entries, got %d" % len(checked))
    print("A10 generated data verified:", len(checked))
    for name in checked:
        print("  ", name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
