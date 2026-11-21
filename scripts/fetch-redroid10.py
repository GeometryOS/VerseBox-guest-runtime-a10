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

## 下载走两段

registry 对 blob 只回一个 307，真正的字节在 CDN 的签名直链上。所以这里自己走第一跳：
Bearer 只发给 registry，CDN 那条只用签名，签名过期就重签一次，从断点接着下。

每层先按区间分块并行；服务端不按 Range 回 206 就整层退回单连接重下。两条路都把
服务端的回话抄一小段进日志，免得下一次 4xx 只留一个状态码。

## 用法（在仓库根）

    python scripts/fetch-redroid10.py --check   # 只解析 manifest 并核对 lock，不下载
    python scripts/fetch-redroid10.py           # 下载每一层，逐层校验 sha256 与字节数

环境变量：`A10_FETCH_WORKERS` 改每层的并发区间数，默认 4；设 1 就完全不用分块。
"""
import hashlib
import json
import os
import sys
import threading
import time
import urllib.error
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
WORKERS = max(1, int(os.environ.get("A10_FETCH_WORKERS", "4")))
RETRIES = 6


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


class RangeRefused(Exception):
    """服务端没有按 Range 回 206。分块没法继续，这一层改用单连接整段下。"""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """第一跳自己走，别让 urllib 顺手把 Bearer 带到 CDN 上。"""

    def redirect_request(self, request, handle, code, message, headers, new_url):
        return None


def body_hint(failure):
    """把服务端的回话抄一小段进日志。4xx 的原因只在正文里，状态码本身说明不了什么。"""
    try:
        text = failure.read(200)
    except Exception:
        return ""
    return text.decode("utf-8", "replace").strip().replace("\n", " ")


def describe(failure):
    if isinstance(failure, urllib.error.HTTPError):
        return "HTTP %d %s %s" % (failure.code, failure.reason, body_hint(failure))
    return "%s: %s" % (type(failure).__name__, failure)


def first_hop(url, bearer):
    """解析这一层在 CDN 上的签名直链。

    registry 对 blob 回的是 307，后面那条直链自己带签名与过期时间，不需要 Bearer。
    自己走第一跳有两个好处：Docker 的 token 不出现在 CDN 的请求里；签名过期时
    可以只重签这一条，不用回头把 token、manifest 全部重来。
    """
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + bearer})
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=120) as response:
            return response.geturl()
    except urllib.error.HTTPError as failure:
        location = failure.headers.get("Location")
        if failure.code in (301, 302, 303, 307, 308) and location:
            return location
        raise SystemExit("解析 %s 的直链失败：%s" % (url.rsplit("/", 1)[-1][:20], describe(failure)))


def blob_locator(repo, layer_digest, bearer):
    """给一层配一个取直链的函数；force 表示签名或 token 已经不作数，重签。"""
    state = {"bearer": bearer, "url": None}

    def locate(force=False):
        if force or not state["url"]:
            if force:
                state["bearer"] = token(repo)
            state["url"] = first_hop(REGISTRY.format(repo=repo) + "/blobs/" + layer_digest,
                                     state["bearer"])
        return state["url"]

    return locate


def splice(response, handle, position, end, on_bytes=None):
    """把这条响应的字节搬进文件，返回搬到的位置。"""
    while position <= end:
        block = response.read(min(1 << 20, end - position + 1))
        if not block:
            raise RuntimeError("区间在 %d 处提前结束" % position)
        handle.seek(position)
        handle.write(block)
        position += len(block)
        if on_bytes:
            on_bytes(len(block))
    return position


def delay(tries):
    """重试间隔递增，上限 30 秒；给同一出口的限流一点退让时间。"""
    time.sleep(min(2 * tries, 30))


def ranged(locate, partial, size, workers):
    """分块并行下载。任何一段判定「不给 Range」就整层交给单连接。"""
    span = (size + workers - 1) // workers
    chunks = []
    for index in range(workers):
        start = index * span
        if start >= size:
            break
        chunks.append((start, min(start + span, size) - 1))

    lock = threading.Lock()
    counted = {"written": 0, "started": time.monotonic(), "reported": time.monotonic()}
    errors = []
    refusals = []

    def on_bytes(added):
        with lock:
            counted["written"] += added
            now = time.monotonic()
            if now - counted["reported"] >= 5:
                rate = counted["written"] / (now - counted["started"]) / (1 << 20)
                print("  %5.1f%%  %.1f/%.1f MiB  %.1f MiB/s" % (
                    counted["written"] * 100.0 / size, counted["written"] / (1 << 20),
                    size / (1 << 20), rate), flush=True)
                counted["reported"] = now

    def worker(start, end, number):
        position = start
        tries = 0
        while position <= end:
            try:
                request = urllib.request.Request(
                    locate(), headers={"Range": "bytes=%d-%d" % (position, end)})
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 206:
                        raise RangeRefused("HTTP %d" % response.status)
                    handle = partial.open("r+b")
                    try:
                        position = splice(response, handle, position, end, on_bytes)
                    finally:
                        handle.close()
                tries = 0
            except RangeRefused as refusal:
                with lock:
                    refusals.append(str(refusal))
                return
            except (SystemExit, Exception) as failure:
                # 直链解析失败在 main 里是 SystemExit；它在子线程里会悄悄结束这个线程，
                # 所以这里一并接住，转成"某一段失败"再往上抛，别让调用方只看到字节数不符。
                tries += 1
                if tries > RETRIES:
                    with lock:
                        errors.append("第 %d 段在 %d 处失败：%s"
                                      % (number, position, describe(failure)))
                    return
                if isinstance(failure, urllib.error.HTTPError) and failure.code in (400, 401, 403):
                    locate(force=True)
                delay(tries)

    threads = [threading.Thread(target=worker, args=(start, end, number), daemon=True)
               for number, (start, end) in enumerate(chunks)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if refusals:
        raise RangeRefused("、".join(refusals))
    if errors:
        raise SystemExit("层下载失败：" + "；".join(errors))


def whole(locate, partial, size):
    """单连接整段下载，从 0 重写。

    这是分块被拒之后的退路，目标只有一个：这一层能下完。断点续传的代价在这里
    不值当，中断就从 0 再来，写进的是同一个 .part，sha256 由调用方核对。
    """
    tries = 0
    while True:
        try:
            with urllib.request.urlopen(locate(), timeout=120) as response:
                with partial.open("r+b") as handle:
                    done = splice(response, handle, 0, size - 1)
            if done != size:
                raise RuntimeError("整段下载停在 %d" % done)
            return
        except Exception as failure:
            tries += 1
            if tries > RETRIES:
                raise SystemExit("整段下载失败：%s" % describe(failure))
            print("  重试 %d：%s" % (tries, describe(failure)), flush=True)
            if isinstance(failure, urllib.error.HTTPError) and failure.code in (400, 401, 403):
                locate(force=True)
            delay(tries)


def download(locate, target, size, workers):
    """下载一层。先分块并行，服务端不给 Range 就整层退回单连接；校验交给调用方。"""
    partial = target.with_suffix(target.suffix + ".part")
    partial.unlink(missing_ok=True)
    with partial.open("wb") as stream:
        stream.truncate(size)
    if workers > 1:
        try:
            ranged(locate, partial, size, workers)
        except RangeRefused as refusal:
            print("  服务端不支持分段（%s），改用单连接" % refusal, flush=True)
            whole(locate, partial, size)
    else:
        whole(locate, partial, size)
    if partial.stat().st_size != size:
        raise SystemExit("下载字节数不符：%d != %d" % (partial.stat().st_size, size))
    os.replace(partial, target)


def resolve(bearer, repo, pinned, arch):
    """按 lock 的 digest 解析。若它指向 manifest list，再挑 linux/<arch> 那一份。

    arch 从 lock 的 architecture 传入，不写死在模块里：这条分支只有 manifest 是 list
    时才会走到，写死一个名字会让另一份 lock 在 CI 上才炸出一句 NameError。
    """
    url = REGISTRY.format(repo=repo) + "/manifests/" + pinned
    document, document_digest = get_json(url, bearer, MANIFEST_ACCEPT)
    if "manifests" not in document:
        return document_digest or pinned, pinned, document
    matches = [item for item in document["manifests"]
               if item.get("platform", {}).get("architecture") == arch
               and item.get("platform", {}).get("os") == "linux"]
    if not matches:
        available = sorted({
            "%s/%s" % (item.get("platform", {}).get("os"),
                       item.get("platform", {}).get("architecture"))
            for item in document["manifests"]})
        raise SystemExit("lock 的 manifest 里没有 linux/%s（可用：%s）"
                         % (arch, "、".join(available)))
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
    index_digest, manifest_digest, manifest = resolve(bearer, repo, entry["manifest"], arch)
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
            download(blob_locator(repo, layer["digest"], bearer), target, layer["size"], WORKERS)
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
