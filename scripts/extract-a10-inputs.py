#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""把一份 A10 参考 APK（或已解包的 runtime-inputs）变成 `prepared/`。

## 为什么 A10 的 `prepared` 要从 APK 来

A9 / A15 的 `prepared` 由各自的 `prepare-*.py` 从**镜像 + 源码**生成；A10 不是——
A10 的客体内容（Redroid 10 rootfs + 项目自建运行时 + 桥接库）目前唯一的**完整成品**
就是参考 APK `_bin/A10VM.apk` 里那份（`docs/rom-package/05` §4：从成品 APK 抽取）。
`guest-runtime/stage.py` 那条源码链需要 `artifacts/container/**` 全套产物，普通开发机没有。

所以本脚本做的是**保真搬运**：把 APK 里的

    assets/guest-runtime-inputs.json      → prepared/assets/guest-runtime-inputs.json
    assets/<其余>                          → prepared/assets/<其余>
    lib/arm64-v8a/<客体 .so>              → prepared/jniLibs/arm64-v8a/<name>

搬成和 A9/A15 一模一样的 `prepared/` 形状，之后 `rom/stage-apk-payload.py` 与
`rom/pack-rom.py` 就能原样处理。**它不生成内容、不改 content 的字节**。

## 四条与参考 APK 对齐的规则（与 app 仓库的 bootstrapBundledRuntime 同一套）

1. **宿主侧的两个库不抽**：`liba10vm-desktop-window.so` / `liba10vm-p1-client.so` 是
   渲染器与 p1 客户端，属于 APK（`System.loadLibrary`），属于 `:native-display`，不属于 ROM；
2. **大小写冲突的资产要转义**：Windows/NTFS 不区分大小写，而 ROM 里存在只差大小写的文件
   （`Arcturus.ogg` / `arcturus.ogg`）。命中的条目改名为
   `guest-runtime/rom-encoded/<sha256(原名)>.asset` 并补 `installPath`（运行时按它还原）；
3. **清单逐条校验**：抽出来的每个文件必须与清单的 `bytes`/`sha256` 一致，否则**失败**
   （`_audit/00` §4.4：构建条件缺失就失败，不许降级）。
4. **先校验来源，再动 `prepared/`**：来源不可用时直接失败，旧的 `prepared/` 原样留着；新内容先写
   `prepared.staging`，逐条校验通过之后才换上去。旧版在确认来源之前就 `rmtree(prepared)`，
   来源一空，1.5 GB 的 prepared 先被删掉，然后才报错。

## 用法（在 guest-runtime-a10 根目录）

    # 从参考 APK 抽（默认找 ../../_bin/A10VM.apk）
    python scripts/extract-a10-inputs.py

    # 指定 APK / 复用 app 仓库已解包的 runtime-inputs（快，1.4 GB 不用再解一次）
    python scripts/extract-a10-inputs.py --apk /path/to/A10VM.apk
    python scripts/extract-a10-inputs.py --from-runtime-inputs ../../runtime-inputs/guest-runtime
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.dirname(HERE)
ROOT = os.path.dirname(MODULE)
DEFAULT_APK = os.path.join(ROOT, "_bin", "A10VM.apk")
PREFIX = "guest-runtime/"
# 宿主侧（:native-display）的两个库，不进 ROM。
DISPLAY_LIBRARIES = ("liba10vm-desktop-window.so", "liba10vm-p1-client.so")
MANIFEST = "guest-runtime-inputs.json"


class ExtractError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def escape_case_collisions(manifest, renamed):
    """同名不同大小写的 data[] 条目改成 rom-encoded/<sha256>.asset + installPath。"""
    data = manifest.get("data");
    if not isinstance(data, list):
        raise ExtractError("清单缺少 data[]")
    groups = {}
    for item in data:
        groups.setdefault(item["name"].lower(), []).append(item)
    for group in groups.values():
        if len({item["name"] for item in group}) < 2:
            continue
        for item in group:
            original = item["name"]
            encoded = PREFIX + "rom-encoded/" + digest_bytes(original.encode("utf-8")) + ".asset"
            item["installPath"] = original[len(PREFIX):] if original.startswith(PREFIX) else original
            item["name"] = encoded
            renamed[original] = encoded
    return len(renamed)


def verify_against_manifest(manifest, assets_dir, jni_dir):
    """逐条核对 bytes/sha256；任何一条不符就失败（不产出、不降级）。"""
    problems = []
    for section, directory in (("data", assets_dir), ("files", jni_dir)):
        for item in manifest.get(section) or []:
            path = os.path.join(directory, item["name"])
            if not os.path.isfile(path):
                problems.append("缺少 %s：%s" % (section, item["name"]))
                continue
            if os.path.getsize(path) != item["bytes"]:
                problems.append("字节数不符：%s" % item["name"])
                continue
            if sha256_file(path) != item["sha256"]:
                problems.append("SHA-256 不符：%s" % item["name"])
    if problems:
        raise ExtractError("参考 APK 与清单不一致（%d 条），例如：\n  - %s"
                           % (len(problems), problems[0]))
    return sum(len(manifest.get(name) or []) for name in ("data", "files"))


def replace_directory(staging, out):
    """用校验过的 staging 换掉 out：先给旧目录改名，再换上去，最后删旧的。"""
    previous = out + ".previous"
    if os.path.isdir(previous):
        shutil.rmtree(previous)
    if os.path.isdir(out):
        os.replace(out, previous)
    os.replace(staging, out)
    if os.path.isdir(previous):
        shutil.rmtree(previous, ignore_errors=True)


def check_source(from_runtime_inputs, apk):
    """在动 prepared/ 之前确认来源可用，并把规范化后的路径返回。"""
    if from_runtime_inputs:
        source = os.path.abspath(from_runtime_inputs)
        if not os.path.isfile(os.path.join(source, "assets", MANIFEST)):
            raise ExtractError("不是 runtime-inputs 目录（缺 assets/%s）：%s" % (MANIFEST, source))
        return source
    source = os.path.abspath(apk)
    if not os.path.isfile(source):
        raise ExtractError("找不到参考 APK：%s（用 --apk 指定）" % source)
    with zipfile.ZipFile(source) as probe:
        if "assets/" + MANIFEST not in probe.namelist():
            raise ExtractError("APK 里没有 assets/%s：%s" % (MANIFEST, source))
    return source


def write_manifest(path, manifest):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def extract_from_apk(apk, out):
    if not os.path.isfile(apk):
        raise ExtractError("找不到参考 APK：%s（用 --apk 指定）" % apk)
    assets = os.path.join(out, "assets")
    jni = os.path.join(out, "jniLibs", "arm64-v8a")
    os.makedirs(assets, exist_ok=True)
    os.makedirs(jni, exist_ok=True)
    with zipfile.ZipFile(apk) as archive:
        manifest = json.loads(archive.read("assets/" + MANIFEST).decode("utf-8"))
        renamed = {}
        escaped = escape_case_collisions(manifest, renamed)
        copied = 0
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if name == "assets/" + MANIFEST:
                continue
            if name.startswith("assets/"):
                relative = name[len("assets/"):]
                target = os.path.join(assets, renamed.get(relative, relative))
            elif name.startswith("lib/arm64-v8a/"):
                library = name.rsplit("/", 1)[-1]
                if library in DISPLAY_LIBRARIES:
                    continue
                target = os.path.join(jni, library)
            else:
                continue
            os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
            with archive.open(info) as source, open(target, "wb") as sink:
                shutil.copyfileobj(source, sink, 1 << 20)
            copied += 1
    write_manifest(os.path.join(assets, MANIFEST), manifest)
    return manifest, copied, escaped


def extract_from_runtime_inputs(source, out):
    """复用 app 仓库已解包的 runtime-inputs/guest-runtime（形状与 prepared 相同）。"""
    manifest_path = os.path.join(source, "assets", MANIFEST)
    if not os.path.isfile(manifest_path):
        raise ExtractError("不是 runtime-inputs 目录（缺 assets/%s）：%s" % (MANIFEST, source))
    assets = os.path.join(out, "assets")
    jni = os.path.join(out, "jniLibs", "arm64-v8a")
    os.makedirs(jni, exist_ok=True)
    if os.path.isdir(assets):
        shutil.rmtree(assets)
    shutil.copytree(os.path.join(source, "assets"), assets)
    for library in os.listdir(os.path.join(source, "jniLibs", "arm64-v8a")):
        if library in DISPLAY_LIBRARIES:
            continue
        shutil.copyfile(os.path.join(source, "jniLibs", "arm64-v8a", library),
                        os.path.join(jni, library))
    with open(os.path.join(assets, MANIFEST), encoding="utf-8") as handle:
        manifest = json.load(handle)
    return manifest, 0, 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="A10 参考 APK → prepared/")
    parser.add_argument("--apk", default=DEFAULT_APK)
    parser.add_argument("--from-runtime-inputs", default=None)
    parser.add_argument("--out", default=os.path.join(MODULE, "prepared"))
    args = parser.parse_args(argv)

    out = os.path.abspath(args.out)
    staging = out + ".staging"
    try:
        source = check_source(args.from_runtime_inputs, args.apk)
        if os.path.isdir(staging):
            shutil.rmtree(staging)
        os.makedirs(staging)
        if args.from_runtime_inputs:
            manifest, copied, escaped = extract_from_runtime_inputs(source, staging)
        else:
            manifest, copied, escaped = extract_from_apk(source, staging)
        checked = verify_against_manifest(
            manifest, os.path.join(staging, "assets"), os.path.join(staging, "jniLibs", "arm64-v8a"))
        replace_directory(staging, out)
    except ExtractError as failure:
        if os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)
        print("A10 prepared 生成失败：%s" % failure)
        return 1

    report = {
        "source": os.path.abspath(source),
        "prepared": out,
        "guestSdk": manifest.get("guestSdk"),
        "files": len(manifest.get("files") or []),
        "data": len(manifest.get("data") or []),
        "verified": checked,
        "copied": copied,
        "caseEscaped": escaped,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
