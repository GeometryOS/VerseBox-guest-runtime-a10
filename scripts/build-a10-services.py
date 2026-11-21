#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Patch the Android 10 services.jar from rootfs using pinned dexlib2 libraries."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

MODULE = Path(__file__).resolve().parents[1]
LOCK = MODULE / "scripts" / "dexlib2-deps.lock.json"
PATCHER = MODULE / "tools" / "dex" / "PatchWifiRelay.java"
SOURCE = MODULE / "rootfs" / "system" / "framework" / "services.jar"
DEPENDENCIES = MODULE / "runtime" / "downloads" / "dexlib2"
WORK = MODULE / "runtime" / "build" / "services-patcher"
OUTPUT = MODULE / "runtime" / "build" / "data" / "rootfs" / "system" / "framework" / "services.jar"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_dependencies(offline: bool) -> list[Path]:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("schema") != "a10-dexlib-dependencies/1":
        raise SystemExit("unsupported dexlib dependency lock schema")
    DEPENDENCIES.mkdir(parents=True, exist_ok=True)
    result = []
    for artifact in lock["artifacts"]:
        target = DEPENDENCIES / artifact["file"]
        valid = (target.is_file() and target.stat().st_size == artifact["bytes"]
                 and sha256(target) == artifact["sha256"])
        if not valid:
            if offline:
                raise SystemExit("missing or invalid cached dependency: " + artifact["file"])
            url = lock["repository"].rstrip("/") + "/" + artifact["path"]
            temporary = target.with_suffix(target.suffix + ".part")
            try:
                with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
                    shutil.copyfileobj(response, output)
                if temporary.stat().st_size != artifact["bytes"] or sha256(temporary) != artifact["sha256"]:
                    raise SystemExit("dependency checksum mismatch: " + artifact["file"])
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
        result.append(target)
    return result


def verify_archive(source: Path, output: Path) -> None:
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as patched:
        old_names, new_names = original.namelist(), patched.namelist()
        if old_names != new_names:
            raise SystemExit("services.jar entry list changed")
        changed = []
        for name in old_names:
            if original.read(name) != patched.read(name):
                changed.append(name)
                if not (name == "classes.dex" or (name.startswith("classes") and name.endswith(".dex"))):
                    raise SystemExit("non-DEX services.jar entry changed: " + name)
        if not changed:
            raise SystemExit("services.jar DEX was not changed")
        print("services.jar entries:", len(old_names), "changed DEX entries:", ", ".join(changed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--services-jar", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--offline", action="store_true", help="use only verified cached Maven jars")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    if args.plan_only:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        print("input:", args.services_jar)
        print("patcher:", PATCHER)
        print("dependency lock:", LOCK)
        print("dependencies:", len(lock["artifacts"]))
        print("output:", args.output)
        return 0
    if not args.services_jar.is_file():
        raise SystemExit("missing rootfs services.jar: " + str(args.services_jar))
    if not PATCHER.is_file():
        raise SystemExit("missing A10 patcher source: " + str(PATCHER))
    dependencies = fetch_dependencies(args.offline)
    javac = shutil.which("javac")
    java = shutil.which("java")
    if not javac or not java:
        raise SystemExit("missing JDK tools javac/java")
    if WORK.exists():
        shutil.rmtree(WORK)
    classes = WORK / "classes"
    classes.mkdir(parents=True)
    classpath = os.pathsep.join(str(item) for item in dependencies)
    subprocess.run([javac, "--release", "8", "-cp", classpath, "-d", str(classes), str(PATCHER)], check=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".part")
    try:
        subprocess.run([java, "-cp", str(classes) + os.pathsep + classpath,
                        "PatchWifiRelay", str(args.services_jar), str(temporary)], check=True)
        verify_archive(args.services_jar, temporary)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print("services.jar:", args.output, "bytes:", args.output.stat().st_size,
          "sha256:", sha256(args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
