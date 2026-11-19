#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""按 sources.lock.json 固定的 digest 下载 Redroid 10（arm64）的镜像层。

## 为什么按 digest 而不是按 tag

Redroid 的 `<版本>-latest` 是滚动 tag，同一个名字今天和明天可能指向两份不同的镜像。
`sources.lock.json` 已经把 manifest 与主层的 digest、字节数固定下来，所以这里直接按
digest 拉 manifest，再把每一层的 sha256 与字节数和 lock 对一遍。对不上就失败，
不写"编不出来就用旧产物"那种降级。

## 产物

    downloads/redroid10-layer<N>-<层 digest 前 8 位>.tar.gz
    downloads/redroid10-config.json      镜像 config 里的 Entrypoint、Cmd、Env
    downloads/manifest.json              解析结果、层清单，以及本次所用 lock 的 sha256

`manifest.json` 是 `scripts/extract-rootfs.py` 的唯一输入。文件名带层 digest，
不拿滚动 tag 当身份。

## 用法（在仓库根）

    python scripts/fetch-redroid10.py --check   # 只解析 manifest 并核对 lock，不下载
    python scripts/fetch-redroid10.py           # 下载每一层，逐层校验 sha256 与字节数

环境变量：`A10_FETCH_WORKERS` 改每层的并发区间数，默认 8。
"""
import hashlib
import json
import os
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "sources.lock.json"
DOWNLOAD = ROOT / "downloads"

AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
REGISTRY = "https://registry-1.docker.io/v2/{repo}"
MANIFEST_ACCEPT = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json, "
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)
IMAGE_ACCEPT = (
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)
WORKERS = max(1, int(os.environ.get("A10_FETCH_WORKERS", "8")))


def read_lock():
    """读 redroid10 条目，并给出整份 lock 的 sha256，写进产物便于回查来源。"""
    if not LOCK.is_file():
        raise SystemExit("找不到 sources.lock.json：%s" % LOCK)
    text = LOCK.read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except ValueError as failure:
        raise SystemExit("sources.lock.json 不是合法 JSON：%s" % failure)
    entry = data.get("redroid10")
    if not isinstance(entry, dict):
        raise SystemExit("sources.lock.json 里没有 redroid10 条目")
    for key in ("repository", "architecture", "manifest", "layer", "bytes"):
        if not entry.get(key):
            raise SystemExit("sources.lock.json 的 redroid10 缺 %s" % key)
    return entry, hashlib.sha256(text.encode("utf-8")).hexdigest()


def token(repo):
    with urllib.request.urlopen(AUTH.format(repo=repo), timeout=60) as response:
        return json.load(response)["token"]


def get_json(url, bearer, accept):
    request = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + bearer,
        "Accept": accept,
    })
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response), (response.headers.get("Docker-Content-Digest") or "").strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 << 20), b""):
            value.update(block)
    return value.hexdigest()


def download(url, bearer, target, size):
    """按 HTTP Range 分块下载一层，失败重试；校验交给调用方。"""
    partial = target.with_suffix(target.suffix + ".part")
    partial.unlink(missing_ok=True)
    with partial.open("wb") as stream:
        stream.truncate(size)
    span = (size + WORKERS - 1) // WORKERS
    chunks = []
    for index in range(WORKERS):
        start = index * span
        if start >= size:
            break
        chunks.append((start, min(start + span, size) - 1))
    lock = threading.Lock()
    written = [0]
    errors = []
    started = time.monotonic()
    last_report = [started]

    def worker(start, end, number):
        position = start
        tries = 0
        while position <= end:
            try:
                headers = {"Authorization": "Bearer " + bearer,
                           "Range": "bytes=%d-%d" % (position, end)}
                request = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 206:
                        raise RuntimeError("服务端忽略了 Range：HTTP %d" % response.status)
                    handle = open(partial, "r+b")
                    try:
                        while position <= end:
                            block = response.read(min(1 << 20, end - position + 1))
                            if not block:
                                raise RuntimeError("区间在 %d 处提前结束" % position)
                            handle.seek(position)
                            handle.write(block)
                            position += len(block)
                            with lock:
                                written[0] += len(block)
                                now = time.monotonic()
                                if now - last_report[0] >= 5:
                                    rate = written[0] / (now - started) / (1 << 20)
                                    print("  %5.1f%%  %.1f/%.1f MiB  %.1f MiB/s" % (
                                        written[0] * 100.0 / size, written[0] / (1 << 20),
                                        size / (1 << 20), rate), flush=True)
                                    last_report[0] = now
                    finally:
                        handle.close()
                tries = 0
            except Exception as failure:
                tries += 1
                if tries > 6:
                    with lock:
                        errors.append("第 %d 段在 %d 处失败：%s" % (number, position, failure))
                    return
                time.sleep(2 * tries)

    threads = [threading.Thread(target=worker, args=(start, end, number), daemon=True)
               for number, (start, end) in enumerate(chunks)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if errors:
        raise SystemExit("层下载失败：" + "；".join(errors))
    if partial.stat().st_size != size:
        raise SystemExit("下载字节数不符：%d != %d" % (partial.stat().st_size, size))
    os.replace(partial, target)


def resolve(bearer, repo, pinned):
    """按 lock 的 digest 解析。若它指向 manifest list，再挑 linux/<arch> 那一份。"""
    url = REGISTRY.format(repo=repo) + "/manifests/" + pinned
    document, document_digest = get_json(url, bearer, MANIFEST_ACCEPT)
    if "manifests" not in document:
        return document_digest or pinned, pinned, document
    matches = [item for item in document["manifests"]
               if item.get("platform", {}).get("architecture") == ARCH
               and item.get("platform", {}).get("os") == "linux"]
    if not matches:
        available = sorted({
            "%s/%s" % (item.get("platform", {}).get("os"),
                       item.get("platform", {}).get("architecture"))
            for item in document["manifests"]})
        raise SystemExit("lock 的 manifest 里没有 linux/%s（可用：%s）"
                         % (ARCH, "、".join(available)))
    chosen = matches[0]
    image, image_digest = get_json(
        REGISTRY.format(repo=repo) + "/manifests/" + chosen["digest"], bearer, IMAGE_ACCEPT)
    return document_digest, image_digest or chosen["digest"], image


def layer_name(number, layer_digest, media):
    """文件名带层 digest，滚动 tag 改名也指不到别的层上。"""
    suffix = ".tar.gz" if media.endswith("gzip") else ".tar"
    return "redroid10-layer%d-%s%s" % (number, layer_digest.split(":")[-1][:8], suffix)


def fetch_config(bearer, repo, config, path):
    wanted = (config.get("digest") or "").split(":")[-1]
    if not wanted:
        return None
    if path.is_file() and digest(path) == wanted:
        return json.loads(path.read_text(encoding="utf-8"))
    request = urllib.request.Request(
        REGISTRY.format(repo=repo) + "/blobs/" + config["digest"],
        headers={"Authorization": "Bearer " + bearer})
    with urllib.request.urlopen(request, timeout=120) as response:
        path.write_bytes(response.read())
    actual = digest(path)
    if actual != wanted:
        raise SystemExit("config 的 sha256 不符：%s != %s" % (actual, wanted))
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    check = "--check" in argv
    unknown = [item for item in argv if item != "--check"]
    if unknown:
        raise SystemExit("未知参数：%s（只支持 --check）" % "、".join(unknown))

    entry, lock_digest = read_lock()
    repo, arch = entry["repository"], entry["architecture"]
    print("lock     = %s sha256=%s" % (LOCK, lock_digest))
    print("repository=%s arch=%s" % (repo, arch))
    print("pinned   = manifest %s" % entry["manifest"])
    print("           layer    %s  %d bytes" % (entry["layer"], entry["bytes"]))

    bearer = token(repo)
    index_digest, manifest_digest, manifest = resolve(bearer, repo, entry["manifest"])
    layers = manifest.get("layers") or []
    if not layers:
        raise SystemExit("解析出的 manifest 里没有 layers")
    print("resolved = index %s" % (index_digest or "（无）"))
    print("           image %s" % manifest_digest)
    print("layers   = %d，合计 %.1f MiB" % (
        len(layers), sum(item["size"] for item in layers) / (1 << 20)))

    pinned = [item for item in layers if item["digest"] == entry["layer"]]
    if not pinned:
        raise SystemExit("lock 固定的层 %s 不在这次解析的 manifest 里" % entry["layer"])
    if pinned[0]["size"] != entry["bytes"]:
        raise SystemExit("lock 固定的层字节数不符：manifest %d != lock %d"
                         % (pinned[0]["size"], entry["bytes"]))
    for number, layer in enumerate(layers):
        media = layer.get("mediaType", "")
        if not media.endswith("tar+gzip") and not media.endswith("tar"):
            raise SystemExit("第 %d 层的 mediaType 不认识：%s" % (number, media))
        print("  layer %d %s %d bytes" % (number, layer["digest"], layer["size"]))
    if check:
        print("check ok：lock 的主层在这份 manifest 里，字节数一致；没有下载。")
        return 0

    DOWNLOAD.mkdir(parents=True, exist_ok=True)
    records = []
    for number, layer in enumerate(layers):
        media = layer["mediaType"]
        target = DOWNLOAD / layer_name(number, layer["digest"], media)
        expected = layer["digest"].split(":")[-1]
        if target.is_file() and digest(target) == expected:
            print("cached    " + target.name, flush=True)
        else:
            print("download  %s（%.1f MiB）" % (target.name, layer["size"] / (1 << 20)), flush=True)
            download(REGISTRY.format(repo=repo) + "/blobs/" + layer["digest"], bearer,
                     target, layer["size"])
            actual = digest(target)
            if actual != expected:
                raise SystemExit("层 %d 的 sha256 不符：%s != %s" % (number, actual, expected))
            print("verified  " + target.name, flush=True)
        records.append({"path": str(target), "name": target.name, "sha256": expected,
                        "bytes": layer["size"], "mediaType": media})

    config = manifest.get("config") or {}
    config_path = DOWNLOAD / "redroid10-config.json"
    image_config = fetch_config(bearer, repo, config, config_path) or {}
    fields = image_config.get("config") or {}

    report = {
        "repository": repo,
        "architecture": arch,
        "lock": {
            "path": "sources.lock.json",
            "sha256": lock_digest,
            "manifest": entry["manifest"],
            "layer": entry["layer"],
            "bytes": entry["bytes"],
        },
        "indexDigest": index_digest,
        "manifestDigest": manifest_digest,
        "config": {"name": config_path.name, "sha256": (config.get("digest") or "").split(":")[-1]},
        "entrypoint": fields.get("Entrypoint"),
        "cmd": fields.get("Cmd"),
        "env": fields.get("Env"),
        "layers": records,
    }
    manifest_path = DOWNLOAD / "manifest.json"
    manifest_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
    print("done: %s" % manifest_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
