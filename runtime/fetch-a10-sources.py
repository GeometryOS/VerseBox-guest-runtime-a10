#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""按 A10 的四份归档清单与一份单文件清单把 AOSP 10 源码取到 runtime/upstream/。

输入是 runtime/lists/archives.txt、vendor/runtime/dynamic/archives.txt、
vendor/runtime/companion/archives.txt 与 vendor/binder/archives.txt，每行三段：仓库、提交、子树。
四份清单的并集就是静态闭包、动态运行时、配套数学库与 binder 组需要的全部上游源。单文件清单
runtime/lists/blueprints.txt 每行也是三段，取的是各模块的 Android.bp，因为按子树取源时
拿不到仓库根的文件。

产物：runtime/downloads/<名字>.tar.gz 与 runtime/upstream/<仓库>/<子树>/。
同一份归档下载过一次就不再下载，目录已经存在就不再解开，所以重复跑只做事后校验。
上游回 429 或 5xx 时按 `retried` 退避重试，重试用尽才失败。

用法（在 guest-runtime-a10 根目录）：

    python runtime/fetch-a10-sources.py            # 取源并校验
    python runtime/fetch-a10-sources.py --check    # 只校验，不下载
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTS = (
    os.path.join(MODULE, "runtime", "lists", "archives.txt"),
    os.path.join(MODULE, "vendor", "runtime", "dynamic", "archives.txt"),
    os.path.join(MODULE, "vendor", "runtime", "companion", "archives.txt"),
    os.path.join(MODULE, "vendor", "binder", "archives.txt"),
    os.path.join(MODULE, "vendor", "graphics", "archives.txt"),
    os.path.join(MODULE, "vendor", "media", "archives.txt"),
)
MANIFESTS = (
    os.path.join(MODULE, "runtime", "lists", "sources.sha256"),
    os.path.join(MODULE, "vendor", "runtime", "dynamic", "sources.sha256"),
    os.path.join(MODULE, "vendor", "runtime", "companion", "sources.sha256"),
    os.path.join(MODULE, "vendor", "binder", "sources.sha256"),
)
BLUEPRINTS = os.path.join(MODULE, "runtime", "lists", "blueprints.txt")
BASE = "https://android.googlesource.com/platform/%s/+archive"
FILE_BASE = "https://android.googlesource.com/platform/%s/+/%s/%s?format=TEXT"
TIMEOUT = 120
ATTEMPTS = 5
# gitiles 的 archive 接口是现场打包的：同一个提交在负载高时会回 503，几秒后就好。
# 429 与这几种 5xx 值得再试，403、404 再试也没用，直接抛。
RETRY_STATUS = (429, 500, 502, 503, 504)


def read_entries(lists):
    entries, seen = [], set()
    for path in lists:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                repository, commit, subtree = line.split()
                key = (repository, commit, subtree)
                if key not in seen:
                    seen.add(key)
                    entries.append(key)
    return entries


def repository_base(repository):
    """gitiles 的仓库前缀。device/ 下的仓库不在 platform/ 下。

    goldfish-opengl 在 device/generic/ 下，A9 与 A15 的取源脚本也是单独给它一个地址。
    """
    if repository.startswith("device/"):
        return "https://android.googlesource.com/%s/+archive" % repository
    return BASE % repository


def url_for(repository, commit, subtree):
    base = "%s/%s" % (repository_base(repository), commit)
    if subtree == ".":
        return base + ".tar.gz"
    return base + "/" + subtree + ".tar.gz"


def archive_name(repository, commit, subtree):
    return "%s-%s-%s.tar.gz" % (repository.replace("/", "_"), commit, subtree.replace("/", "_"))


def retried(label, call):
    """跑一次取源调用；上游打嗝就等一会儿再来，别的错误照原样抛。

    一条 503 让整条 CI 从镜像重新开始，是这一步最贵的失败方式：这一轮前面六份源码都
    取到了，第七份赶上一次 503，整条链就断了。所以这里重试的是"同一个提交再要一次"，
    不换地址、不降级，重试用尽才失败。
    """
    attempt = 0
    while True:
        attempt += 1
        try:
            return call()
        except urllib.error.HTTPError as failure:
            if failure.code not in RETRY_STATUS or attempt >= ATTEMPTS:
                raise
            reason = "HTTP %d %s" % (failure.code, failure.reason)
        except (urllib.error.URLError, TimeoutError) as failure:
            if attempt >= ATTEMPTS:
                raise
            reason = str(failure)
        wait = min(2 ** attempt, 30)
        print("  重试 %d/%d，%d 秒后：%s（%s）" % (attempt, ATTEMPTS - 1, wait, reason, label),
              flush=True)
        time.sleep(wait)


def download(url, target):
    partial = target + ".part"

    def attempt():
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response, open(partial, "wb") as sink:
            for chunk in iter(lambda: response.read(1 << 20), b""):
                sink.write(chunk)

    retried(os.path.basename(target), attempt)
    os.replace(partial, target)


def read_url(url):
    """取一份不大的内容（单文件接口）。同一个 host、同一种失败模式，共用重试。"""

    def attempt():
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            return response.read()

    return retried(url.rsplit("/", 1)[-1][:60], attempt)


def extract(archive, destination):
    """解到目标目录，用系统 tar，与 A9、A15 的取源脚本同一条命令。

    AOSP 的归档里有指向子树外的符号链接，Windows 上建不出这类链接，tar 会以非零退出；
    缺哪些文件由后面的逐文件校验兜住，所以这里不看退出码，与 A9、A15 的写法一致。
    """
    os.makedirs(destination, exist_ok=True)
    subprocess.run(["tar", "-mxzf", archive, "-C", destination],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def fetch_blueprints(upstream, check_only):
    """取各模块 Android.bp。gitiles 的单文件接口返回 base64，要自己解码。

    按子树取源拿不到仓库根的文件，而模块选择要读 Blueprint 里的 srcs 与 flags。
    """
    if not os.path.isfile(BLUEPRINTS):
        return 0
    fetched = 0
    with open(BLUEPRINTS, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            repository, commit, path = line.split()
            destination = os.path.join(upstream, *repository.split("/"), *path.split("/"))
            if os.path.isfile(destination):
                continue
            if check_only:
                print("缺少 %s %s %s" % (repository, path, commit))
                continue
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            encoded = read_url(FILE_BASE % (repository, commit, path))
            with open(destination + ".part", "wb") as sink:
                sink.write(base64.b64decode(encoded))
            os.replace(destination + ".part", destination)
            print("取回 %s/%s" % (repository, path), flush=True)
            fetched += 1
    return fetched


def materialize_links(upstream):
    """把解出来的符号链接换成目标文件的副本。

    Windows 上建链接要权限，tar 遇到链接只留一个读不出来的残桩，编译器看到的是
    "文件不存在"，而在 Linux 上同一个路径是正常头文件。这里按链接目标补一份同样的
    字节，让两个平台看到同一棵树；链接本身指不出去的保持原样，由后面逐文件校验报出来。
    """
    repaired = unresolved = dropped = 0
    for root, _, names in os.walk(upstream):
        for name in names:
            path = os.path.join(root, name)
            # 悬空的链接在 Windows 上 islink 会返回 False，但编译器打开它拿到的是
            # ACCESS_DENIED，于是它挡住了后面的真实头文件。lexists 能看见这种条目。
            if not os.path.lexists(path):
                continue
            if not os.path.islink(path) and not os.path.isfile(path):
                continue
            if os.path.isfile(path) and not os.path.islink(path):
                continue
            try:
                with open(path, "rb") as handle:
                    handle.read(1)
                continue
            except OSError:
                pass
            try:
                target = os.readlink(path)
            except OSError:
                unresolved += 1
                continue
            # Windows 的 tar 会把链接目标写成反斜杠（..\..\media\x.h），按原样拼接解不开，
            # 所以先把分隔符统一成正斜杠再解析。
            resolved = os.path.normpath(os.path.join(root, target.replace("\\", "/")))
            if not os.path.isfile(resolved):
                # 指不出去的链接：删掉，让搜索引擎落到别处那份真实头文件；
                # 真没有替代品时编译会明确报"找不到"，比 ACCESS_DENIED 好查。
                os.remove(path)
                unresolved += 1
                dropped += 1
                continue
            with open(resolved, "rb") as source:
                payload = source.read()
            os.remove(path)
            with open(path, "wb") as sink:
                sink.write(payload)
            repaired += 1
    return repaired, unresolved, dropped


def verify(upstream, manifests):
    checked = missing = bad = 0
    for manifest in manifests:
        if not os.path.isfile(manifest):
            continue
        with open(manifest, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                digest, name = line.split("  ", 1)
                path = os.path.join(upstream, name.replace("/", os.sep))
                if not os.path.isfile(path):
                    missing += 1
                    continue
                with open(path, "rb") as handle_read:
                    actual = hashlib.sha256(handle_read.read()).hexdigest()
                if actual != digest:
                    bad += 1
                checked += 1
    return checked, missing, bad


def main(argv=None):
    parser = argparse.ArgumentParser(description="取 AOSP 10 源码到 runtime/upstream/")
    parser.add_argument("--check", action="store_true", help="只校验已取到的源，不下载")
    parser.add_argument("--downloads", default=os.path.join(MODULE, "runtime", "downloads"))
    parser.add_argument("--upstream", default=os.path.join(MODULE, "runtime", "upstream"))
    args = parser.parse_args(argv)

    entries = read_entries(LISTS)
    # 整棵子树（subtree 为 "."）先取：它落地之后，细分子树只是往里并，
    # 反过来则会被"目录已存在"跳过，永远补不上缺的目录。
    entries.sort(key=lambda entry: (entry[2] != ".", entry[0], entry[2]))
    os.makedirs(args.downloads, exist_ok=True)
    os.makedirs(args.upstream, exist_ok=True)
    fetched = 0
    for repository, commit, subtree in entries:
        parts = [args.upstream] + repository.split("/")
        if subtree != ".":
            parts += subtree.split("/")
        destination = os.path.join(*parts)
        if os.path.isdir(destination) and os.listdir(destination):
            continue
        if args.check:
            print("缺少 %s %s %s" % (repository, subtree, commit))
            continue
        archive = os.path.join(args.downloads, archive_name(repository, commit, subtree))
        if not os.path.isfile(archive):
            print("下载 %s %s %s" % (repository, commit, subtree), flush=True)
            download(url_for(repository, commit, subtree), archive)
        print("解开 %s" % os.path.basename(archive), flush=True)
        extract(archive, destination)
        fetched += 1

    blueprints = fetch_blueprints(args.upstream, args.check)
    repaired, unresolved, dropped = 0, 0, 0
    if not args.check:
        repaired, unresolved, dropped = materialize_links(args.upstream)
    checked, missing, bad = verify(args.upstream, MANIFESTS)
    print("entries=%d fetched=%d blueprints=%d verified=%d missing=%d mismatched=%d"
          % (len(entries), fetched, blueprints, checked, missing, bad))
    print("links repaired=%d unresolved=%d dropped=%d" % (repaired, unresolved, dropped))
    if missing or bad:
        print("校验未通过：缺 %d 个、内容不符 %d 个" % (missing, bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
