#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""Build A10 check DEX files from the A10-owned Java source closure.

The source files under framework/src/main/java were copied from the legacy A10
runtime without changing the legacy tree. This script only writes runtime/build
after the Java and D8 steps succeed; it does not modify prepared/.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

MODULE = Path(__file__).resolve().parents[1]
SOURCE_ROOT = MODULE / "framework" / "src" / "main" / "java"
OUTPUT_ROOT = MODULE / "runtime" / "build" / "dex"

RUNTIME_SOURCES = {"RuntimeCheck.java", "DirectoryCheck.java", "ProcessEvidence.java"}


def find_tool(name: str, windows_name: str | None = None) -> Path:
    candidates = []
    if os.name == "nt" and windows_name:
        candidates.append(windows_name)
    candidates.append(name)
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            return Path(found)
    raise SystemExit("missing tool: " + ", ".join(candidates))


def run(argv: list[str]) -> None:
    print("+", " ".join(argv))
    subprocess.run(argv, check=True)


def d8_argv(d8: Path, args: list[str]) -> list[str]:
    if os.name == "nt" and d8.suffix.lower() in {".bat", ".cmd"}:
        return ["cmd", "/d", "/c", str(d8), *args]
    return [str(d8), *args]


def main() -> int:
    parser = argparse.ArgumentParser(description="Build A10 runtime and framework check DEX")
    parser.add_argument("--android-jar", type=Path, default=None)
    parser.add_argument("--d8-lib", type=Path, default=None)
    parser.add_argument("--build-tools", type=Path, default=None)
    parser.add_argument("--min-api", type=int, default=29)
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()

    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or "")
    android_jar = args.android_jar or Path(os.environ.get("A10_ANDROID_JAR") or
        (sdk / "platforms" / "android-29" / "android.jar"))
    d8_lib = args.d8_lib or Path(os.environ.get("A10_D8_LIB") or
        (sdk / "platforms" / "android-35" / "android.jar"))
    build_tools = args.build_tools or Path(os.environ.get("A10_BUILD_TOOLS") or
        (sdk / "build-tools" / "35.0.0"))
    javac = find_tool("javac", "javac.exe")
    d8 = build_tools / ("d8.bat" if os.name == "nt" else "d8")
    if not d8.is_file():
        d8 = build_tools / ("d8.cmd" if os.name == "nt" else "d8")
    if not android_jar.is_file():
        raise SystemExit("missing Android API 29 javac jar: " + str(android_jar))
    if not d8_lib.is_file():
        raise SystemExit("missing D8 platform library jar: " + str(d8_lib))
    if not d8.is_file():
        raise SystemExit("missing d8: " + str(d8))

    sources = sorted(SOURCE_ROOT.rglob("*.java"))
    if not sources:
        raise SystemExit("no A10 Java sources under " + str(SOURCE_ROOT))
    runtime_sources = [p for p in sources if p.name in RUNTIME_SOURCES]
    # ProcessEvidence is shared by both DEX files; compile it once and stage its class into both inputs.
    framework_sources = [p for p in sources if p.name not in {"RuntimeCheck.java", "DirectoryCheck.java"}]
    if {p.name for p in runtime_sources} != RUNTIME_SOURCES:
        raise SystemExit("runtime source closure is incomplete")
    if args.plan_only:
        print("module:", MODULE)
        print("javacAndroidJar:", android_jar)
        print("d8LibraryJar:", d8_lib)
        print("d8:", d8)
        print("javac:", javac)
        print("frameworkSources:", len(framework_sources))
        print("runtimeSources:", len(runtime_sources))
        print("output:", OUTPUT_ROOT)
        return 0

    framework_classes = OUTPUT_ROOT / "framework-classes"
    runtime_classes = OUTPUT_ROOT / "runtime-classes"
    for directory in (framework_classes, runtime_classes):
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True, exist_ok=True)

    # Compile the closures separately so every top-level and nested class emitted by
    # each source is present. ProcessEvidence is intentionally compiled in both DEXes.
    for source_set, output in ((framework_sources, framework_classes), (runtime_sources, runtime_classes)):
        run([str(javac), "--release", "8", "-cp", str(android_jar), "-d", str(output),
             *[str(source) for source in source_set]])

    prepared_dex = OUTPUT_ROOT / "out"
    if prepared_dex.exists():
        shutil.rmtree(prepared_dex)
    prepared_dex.mkdir(parents=True)
    framework_out = prepared_dex / "framework-out"
    runtime_out = prepared_dex / "runtime-out"
    framework_out.mkdir(parents=True)
    runtime_out.mkdir(parents=True)
    framework_jar = prepared_dex / "framework-classes.jar"
    runtime_jar = prepared_dex / "runtime-classes.jar"
    for directory, archive in ((framework_classes, framework_jar), (runtime_classes, runtime_jar)):
        class_files = sorted(directory.rglob("*.class"))
        if not class_files:
            raise SystemExit("javac produced an empty DEX input set: " + str(directory))
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as jar_file:
            for class_file in class_files:
                jar_file.write(class_file, class_file.relative_to(directory).as_posix())
    run(d8_argv(d8, ["--min-api", str(args.min_api), "--lib", str(d8_lib),
                     "--output", str(framework_out), str(framework_jar)]))
    run(d8_argv(d8, ["--min-api", str(args.min_api), "--lib", str(d8_lib),
                     "--output", str(runtime_out), str(runtime_jar)]))
    framework_dex = prepared_dex / "framework-check.dex"
    runtime_dex = prepared_dex / "runtime-check.dex"
    shutil.copy2(framework_out / "classes.dex", framework_dex)
    shutil.copy2(runtime_out / "classes.dex", runtime_dex)
    print("framework-check.dex:", framework_dex)
    print("runtime-check.dex:", runtime_dex)
    return 0


if __name__ == "__main__":
    sys.exit(main())
