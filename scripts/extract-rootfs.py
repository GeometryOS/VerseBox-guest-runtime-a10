#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""把 Redroid 10（arm64）的镜像层解成普通文件树，并把每一项的类型、权限与链接目标记进索引。

## 为什么只解普通文件

Windows 建不出客体要的设备节点，创建符号链接通常还要提权。所以这里只落普通文件，
其余项目的类型、mode、uid、gid、链接目标全部记进 `rootfs-index.json`；后续的 prepared
按索引还原符号链接与硬链接，不靠文件系统本身。

## 层与 whiteout

镜像是一串层，按 manifest 的顺序叠加，OCI 的 whiteout 按规则执行，也就是先删下层同名项
再继续。Redroid 10 的 arm64 镜像当前只有一层，但仍然读 manifest 而不是写死文件名，
这样镜像换版时这份脚本不需要改。

## 32 位条目

A10 的镜像同时带 32 位与 64 位内容。这里一律照原样落地，不做筛选：
哪些 32 位条目进 prepared 是 S5 的策略，不在解包这一步定。

## 产物

    rootfs/                  普通文件树（符号链接与硬链接不落盘，记在索引里）
    rootfs-index.json        layers、entries、以及本次所用 manifest 的层 digest

用法（在仓库根）：

    python scripts/extract-rootfs.py
    python scripts/extract-rootfs.py --layer downloads/redroid10-layer0-47a4595f.tar.gz
"""
import json
import os
import posixpath
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOWNLOAD = ROOT / "downloads"
MANIFEST = DOWNLOAD / "manifest.json"
TREE = ROOT / "rootfs"
INDEX = ROOT / "rootfs-index.json"

# 这几个目录由宿主或运行时在启动时准备，镜像层里的内容不作数。
VIRTUAL = {"dev", "proc", "sys", "data", "mnt", "acct", "cache", "config", "d",
           "bugreports", "metadata", "storage", "sdcard", "tmp", "run", "lost+found",
           "postinstall", "second_stage_resources"}


def normalize(name):
    name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    name = name.lstrip("/")
    return posixpath.normpath(name) if name else ""


def allowed(path):
    if not path or path == ".":
        return True
    return path.split("/", 1)[0] not in VIRTUAL


def long_path(path):
    absolute = str(path.resolve())
    if os.name == "nt" and not absolute.startswith("\\\\?\\"):
        return "\\\\?\\" + absolute
    return absolute


def layer_files(argv):
    if "--layer" in argv:
        return [Path(argv[argv.index("--layer") + 1])]
    if not MANIFEST.is_file():
        raise SystemExit("缺少 %s，先跑 scripts/fetch-redroid10.py" % MANIFEST)
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    layers = []
    for entry in manifest.get("layers", []):
        path = Path(entry.get("path", ""))
        if not path.is_file():
            fallback = DOWNLOAD / entry.get("name", "")
            if fallback.is_file():
                path = fallback
        if not path.is_file():
            raise SystemExit("缺少层文件：%s" % path)
        layers.append(path)
    if not layers:
        raise SystemExit("manifest 里没有 layers")
    return layers


def remove_path(path):
    target = TREE / path
    if target.is_dir() and not target.is_symlink():
        for child in sorted(target.rglob("*"), reverse=True):
            if child.is_dir() and not child.is_symlink():
                child.rmdir()
            else:
                child.unlink(missing_ok=True)
        target.rmdir()
    elif target.exists() or target.is_symlink():
        target.unlink(missing_ok=True)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    layers = layer_files(argv)
    TREE.mkdir(parents=True, exist_ok=True)
    entries = {}
    hardlinks = []
    total = 0
    for layer in layers:
        print("layer: %s（%.1f MiB）" % (layer.name, layer.stat().st_size / (1 << 20)),
              flush=True)
        with tarfile.open(layer, "r:*") as archive:
            for member in archive:
                path = normalize(member.name)
                if not allowed(path):
                    continue
                base = posixpath.basename(path)
                if base == ".wh..wh..opq":
                    directory = posixpath.dirname(path)
                    for key in [key for key in entries if key == directory or
                                key.startswith(directory + "/")]:
                        remove_path(key)
                        entries.pop(key, None)
                    continue
                if base.startswith(".wh."):
                    gone = posixpath.join(posixpath.dirname(path), base[4:])
                    remove_path(gone)
                    entries.pop(gone, None)
                    continue
                mode = member.mode & 0o7777
                record = {"path": path, "mode": mode, "uid": member.uid, "gid": member.gid,
                          "mtime": int(member.mtime)}
                if member.isdir():
                    record["type"] = "dir"
                    entries[path] = record
                    (TREE / path).mkdir(parents=True, exist_ok=True)
                    continue
                if member.islnk():
                    record["type"] = "hardlink"
                    record["target"] = normalize(member.linkname)
                    entries[path] = record
                    hardlinks.append(record)
                    continue
                if member.issym():
                    record["type"] = "symlink"
                    record["target"] = member.linkname
                    entries[path] = record
                    continue
                if not member.isfile():
                    record["type"] = "special"
                    entries[path] = record
                    continue
                record["type"] = "file"
                record["bytes"] = member.size
                entries[path] = record
                destination = TREE / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise SystemExit("层里的 %s 读不出来" % path)
                with open(long_path(destination), "wb") as output:
                    while True:
                        block = source.read(8 << 20)
                        if not block:
                            break
                        output.write(block)
                total += member.size
                if len(entries) % 2000 == 0:
                    print("  entries=%d files=%.1f MiB" % (len(entries), total / (1 << 20)),
                          flush=True)
    for record in hardlinks:
        source = TREE / record["target"]
        destination = TREE / record["path"]
        if not source.is_file():
            record["type"] = "unresolved-hardlink"
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            destination.unlink()
        try:
            os.link(long_path(source), long_path(destination))
        except OSError:
            destination.write_bytes(source.read_bytes())

    apex = sorted(path for path in entries if path.startswith("system/apex/")
                  and path.endswith(".apex") and entries[path]["type"] == "file")
    recorded = []
    for number, layer in enumerate(layers):
        recorded.append({"path": str(layer), "bytes": layer.stat().st_size,
                         "sha256": layer_sha(number)})
    INDEX.write_text(json.dumps({"layers": recorded, "entries": entries},
                                indent=1) + "\n", encoding="utf-8")

    counts = {}
    for record in entries.values():
        counts[record["type"]] = counts.get(record["type"], 0) + 1
    print(json.dumps({"entries": len(entries), "types": counts,
                      "bytes": sum(item.get("bytes", 0) for item in entries.values()),
                      "apexArchives": len(apex)}, indent=2))
    return 0


def layer_sha(number):
    """层 digest 以 downloads/manifest.json 为准；没有 manifest 时留空。"""
    if not MANIFEST.is_file():
        return ""
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    layers = manifest.get("layers") or []
    if number >= len(layers):
        return ""
    return layers[number].get("sha256", "")


if __name__ == "__main__":
    sys.exit(main())
