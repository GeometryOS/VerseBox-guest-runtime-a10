#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""从 rootfs、本仓库产物与 prebuilt 生成 A10 的 prepared/。

这是 S5 的第二段：prepared 不再从参考 APK 整体抽取，而是按清单的身份逐条落位。
字节有三个来源，优先级从高到低：

1. 本仓库源码现场编出的产物，见 PROJECT；
2. 从 Redroid 10 镜像解出的 rootfs，按清单的 sha256 与字节数逐条核对；
3. 确实没有源码的件，从 prebuilt/ 取，或从参考 prepared 取并标 pinned。

第三条只允许两种情况：没有源码的静态 init，以及旧流水线生成、本仓库还没有生成器的
少量数据件。每一条都写进 prepare-report.json 的 pinned 列表，并在 STATUS.md 的已知限制里
给出替换条件；没有记录就不许使用。

用法（在 guest-runtime-a10 根目录）：

    python scripts/prepare-a10.py              # 只写 prepared.staging 并自检
    python scripts/prepare-a10.py --apply      # 自检通过后换掉 prepared/
    python scripts/prepare-a10.py --check      # 只核对来源，不写文件
    python scripts/prepare-a10.py --from-apk   # 旧路径，交给 extract-a10-inputs.py，留作对照
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 对照清单是旧流水线的身份表，放在 prebuilt/ 而不是 prepared/：prepared 是派生物，
# 一旦被新脚本覆盖，再拿它当身份表就会把上一轮的产物当成下一轮的基准。
INVENTORY = os.path.join(MODULE, "prebuilt", "a10-guest-runtime-inputs.json")
REFERENCE = os.path.join(MODULE, "prepared")
ROOTFS = os.path.join(MODULE, "rootfs")
STAGING = os.path.join(MODULE, "prepared.staging")
DEX = os.path.join(MODULE, "prepared.dex")
REPORT = os.path.join(STAGING, "prepare-report.json")

# logical 名到本仓库产物或 prebuilt 的映射。右边是相对仓库根的路径。
# registry/ 下那六份是 prepared 里的第二份摆放，字节与同名裸库相同，所以指同一份产物。
PROJECT = {
    "libc.so": "runtime/build/lib/libc.so",
    "libdl.so": "runtime/build/lib/libdl.so",
    "libm.so": "runtime/build/lib/libm.so",
    "libunwind.so": "runtime/build/lib/libunwind.so",
    "ld-android.so": "runtime/build/bin/source-linker64",
    "registry/libc++.so": "rootfs/system/lib64/libc++.so",
    # 裸名的 libbinder/libutils/liblog/libcutils/libbinderthreadstate 在参考 prepared 里
    # 与镜像逐字节相同，是 redroid10 的件，不能换成 binder 组那份精简副本。
    # 只有 registry/ 下的第二份摆放是项目产物，binder 组的九个产物服务注册表进程。
    "registry/libbinder.so": "bridges/lib/registry/libbinder.so",
    "registry/libutils.so": "bridges/lib/registry/libutils.so",
    "registry/liblog.so": "bridges/lib/registry/liblog.so",
    # 参考 prepared 的 libbase 是旧流水线打补丁后的 83,552 B，当前源码编出 103,680 B
    # 且少两个导出；首启用参考件，等补丁与源清单对齐再换成自建。
    "libbase.so": "prebuilt/arm64/libbase.so",
    "registry/libbase.so": "bridges/lib/registry/libbase.so",
    "registry/libcutils.so": "bridges/lib/registry/libcutils.so",
    "registry/libbinderthreadstate.so": "bridges/lib/registry/libbinderthreadstate.so",
    "liba10binder.so": "bridges/lib/registry/liba10binder.so",
    "binder-broker": "bridges/bin/binder-broker",
    "binder-registry": "bridges/bin/binder-registry",
    "libOpenglSystemCommon.so": "bridges/graphics/lib/libOpenglSystemCommon.so",
    "libEGL_emulation.so": "bridges/graphics/lib/libEGL_emulation.so",
    "libGLESv1_CM_emulation.so": "bridges/graphics/lib/libGLESv1_CM_emulation.so",
    "libGLESv2_emulation.so": "bridges/graphics/lib/libGLESv2_emulation.so",
    "gralloc.ranchu.so": "bridges/graphics/lib/gralloc.ranchu.so",
    "hwcomposer.ranchu.so": "bridges/graphics/lib/hwcomposer.ranchu.so",
    "property-service": "bridges/properties/bin/property-service",
    "seed-properties": "bridges/properties/bin/seed-properties",
    "liba10vm-property-client.so": "bridges/properties/lib/liba10vm-property-client.so",
    "liba10vm-guest-devices.so": "bridges/devices/lib/liba10vm-guest-devices.so",
    "liba10vm-binder-devices.so": "bridges/devices/lib/liba10vm-binder-devices.so",
    "liba10vm-guest-log.so": "bridges/devices/lib/liba10vm-guest-log.so",
    "liba10vm-hal-modules.so": "bridges/devices/lib/liba10vm-hal-modules.so",
    "liba10vm-manager-policy.so": "bridges/devices/lib/liba10vm-manager-policy.so",
    "libnetd_client.so": "bridges/media/lib/libnetd_client.so",
    "audio.primary.a10vm.so": "bridges/media/lib/audio.primary.a10vm.so",
    "libdexfile.so": "bridges/dex/lib/libdexfile.so",
    "libmediaplayerservice.so": "bridges/media/lib/libmediaplayerservice.so",
    "libstagefright_httplive.so": "bridges/media/lib/libstagefright_httplive.so",
    "libresourcemanagerservice.so": "bridges/media/lib/libresourcemanagerservice.so",
    "drm": "bridges/media/bin/drm",
    "media": "bridges/media/bin/media",
    "media-drm": "bridges/media/bin/media-drm",
    "media-omx": "bridges/media/bin/media-omx",
    "image/a10vm-init": "prebuilt/arm64/a10vm-init",
    "desktop-gpu-host": "prebuilt/arm64/desktop-gpu-host",
    "host-devices": "prebuilt/arm64/host-devices",
}

# 这三件在本仓库没有源码：init 是旧流水线的静态引导件，两个宿主件由 app 的 native-display
# 与共享宿主层编出。它们都按字节钉在 prebuilt/ 下，构建时先核对 .sha256。
PINNED_PROJECT = ("image/a10vm-init", "desktop-gpu-host", "host-devices", "libbase.so")
PINNED_PROJECT_REASON = {
    "image/a10vm-init": "没有源码的静态引导 init",
    "desktop-gpu-host": "宿主渲染器，源码在 app 的 native-display",
    "host-devices": "宿主设备桥，源码在共享宿主层",
    "libbase.so": "旧流水线补丁版，当前源码导出面少两条",
}
# 允许从参考 prepared 取的 data 件。只放旧流水线生成、本仓库还没有生成器的对象。
PINNED_DATA_REASON = {
    "guest-runtime/rootfs/system/framework/services.jar": "旧流水线改过，生成器尚未迁入",
    "guest-runtime/rootfs/system/etc/seccomp_policy/mediacodec.policy": "旧流水线改过，生成器尚未迁入",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediacodec.policy": "旧流水线改过，生成器尚未迁入",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/android.hardware.sensors@2.0.xml": "旧流水线改过，生成器尚未迁入",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/android.hardware.gnss@2.0-service.xml": "旧流水线改过，生成器尚未迁入",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediaextractor.policy": "镜像里没有，旧流水线补的",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediaswcodec.policy": "镜像里没有，旧流水线补的",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/a10vm-host-devices.xml": "项目生成的数据件",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/a10vm-media-codec.xml": "项目生成的数据件",
    "guest-runtime/rootfs/system/bin/a10vm-boot-check": "项目生成的数据件",
    "guest-runtime/system-image-paths.json": "旧流水线生成，生成器尚未迁入",
    "guest-runtime/guest.prop": "旧流水线生成，生成器尚未迁入",
}
CASE_PREFIX = "guest-runtime/rom-encoded/"
GENERATED_DATA = {
    "guest-runtime/runtime-check.dex": "runtime/build/dex/out/runtime-check.dex",
    "guest-runtime/framework-check.dex": "runtime/build/dex/out/framework-check.dex",
    "guest-runtime/guest.prop": "runtime/build/data/guest.prop",
    "guest-runtime/rootfs/system/etc/seccomp_policy/mediacodec.policy": "runtime/build/data/rootfs/system/etc/seccomp_policy/mediacodec.policy",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediacodec.policy": "runtime/build/data/rootfs/vendor/etc/seccomp_policy/mediacodec.policy",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediaextractor.policy": "runtime/build/data/rootfs/vendor/etc/seccomp_policy/mediaextractor.policy",
    "guest-runtime/rootfs/vendor/etc/seccomp_policy/mediaswcodec.policy": "runtime/build/data/rootfs/vendor/etc/seccomp_policy/mediaswcodec.policy",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/a10vm-host-devices.xml": "runtime/build/data/rootfs/vendor/etc/vintf/manifest/a10vm-host-devices.xml",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/a10vm-media-codec.xml": "runtime/build/data/rootfs/vendor/etc/vintf/manifest/a10vm-media-codec.xml",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/android.hardware.sensors@2.0.xml": "runtime/build/data/rootfs/vendor/etc/vintf/manifest/android.hardware.sensors@2.0.xml",
    "guest-runtime/rootfs/vendor/etc/vintf/manifest/android.hardware.gnss@2.0-service.xml": "runtime/build/data/rootfs/vendor/etc/vintf/manifest/android.hardware.gnss@2.0-service.xml",
    "guest-runtime/rootfs/system/bin/a10vm-boot-check": "runtime/build/data/rootfs/system/bin/a10vm-boot-check",
    "guest-runtime/system-image-paths.json": "runtime/build/data/system-image-paths.json",
}


class PrepareError(Exception):
    pass


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def matches(path, entry):
    return (os.path.isfile(path)
            and os.path.getsize(path) == entry["bytes"]
            and digest(path) == entry["sha256"])


def load_inventory():
    with open(INVENTORY, encoding="utf-8") as handle:
        return json.load(handle)


def rootfs_index():
    """sha256 -> 相对 rootfs 的路径列表，用来给没有 image/ 前缀的条目找回源。"""
    index = {}
    for base, _, names in os.walk(ROOTFS):
        for name in names:
            path = os.path.join(base, name)
            if not os.path.isfile(path):
                continue
            relative = os.path.relpath(path, ROOTFS).replace(os.sep, "/")
            index.setdefault(digest(path), []).append(relative)
    return index


def preferred(candidates, logical):
    """同一个哈希可能落在多个 APEX 或 system 目录，按确定的顺序挑一个。"""
    order = (
        "system/lib64/",
        "system/apex/com.android.runtime.debug/lib64/",
        "system/apex/com.android.runtime.debug/lib64/bionic/",
        "system/lib64/vndk-29/",
        "vendor/lib64/",
        "system/product/lib64/",
        "system/apex/com.android.conscrypt/lib64/",
        "system/apex/com.android.media.swcodec/lib64/",
    )
    for prefix in order:
        for candidate in candidates:
            if candidate == prefix + logical:
                return candidate
    return sorted(candidates, key=lambda value: (value.count("/"), value))[0]


def file_source(entry, index):
    """返回 (源文件绝对路径, source, pinned, sourcePath)。"""
    logical = entry["logical"]
    if logical in PROJECT:
        relative = PROJECT[logical]
        if relative is None:
            raise PrepareError("宿主侧条目 %s 不该进 prepared" % logical)
        source = os.path.join(MODULE, relative.replace("/", os.sep))
        if not os.path.isfile(source):
            raise PrepareError("缺少本仓库产物 %s（logical=%s）" % (relative, logical))
        pinned = logical in PINNED_PROJECT
        if pinned:
            check_pin = os.path.join(MODULE, "prebuilt", "arm64", os.path.basename(relative) + ".sha256")
            with open(check_pin, encoding="ascii") as handle:
                fields = handle.read().split()
            if not fields or len(fields[0]) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in fields[0]):
                raise PrepareError("prebuilt/arm64/%s.sha256 格式无效" % os.path.basename(relative))
            expected = fields[0].upper()
            if digest(source).upper() != expected:
                raise PrepareError("prebuilt/arm64/%s 的 sha256 与 .sha256 不符" % os.path.basename(relative))
        if relative.startswith("rootfs/"):
            return source, "redroid10", pinned, "/" + relative[len("rootfs/"):]
        return source, "project-a10", pinned, relative

    if logical.startswith("image/"):
        relative = logical[len("image/"):]
        path = os.path.join(ROOTFS, relative.replace("/", os.sep))
        if matches(path, entry):
            return path, "redroid10", False, "/" + relative
    candidates = index.get(entry["sha256"], [])
    if candidates:
        relative = preferred(candidates, logical)
        return os.path.join(ROOTFS, relative.replace("/", os.sep)), "redroid10", False, "/" + relative
    raise PrepareError("找不到 %s 的来源（%d B，sha256=%s）"
                       % (logical, entry["bytes"], entry["sha256"]))


def resolve_rootfs(relative, entry, entries):
    """按索引把符号链接解析到目标，再按清单核对字节与哈希。"""
    current = relative
    for _ in range(8):
        path = os.path.join(ROOTFS, current.replace("/", os.sep))
        if matches(path, entry):
            return path, current
        record = entries.get(current)
        if not record or record.get("type") != "symlink":
            return None, current
        target = record.get("target") or ""
        if target.startswith("/"):
            current = target.lstrip("/")
        else:
            current = os.path.normpath(os.path.join(os.path.dirname(current), target)).replace(os.sep, "/")
    return None, current


def reference_index():
    """参考 prepared 里 assets 的 sha256 -> 相对 assets 的路径，用来处理大小写转义件。"""
    assets = os.path.join(REFERENCE, "assets")
    index = {}
    for base, _, names in os.walk(assets):
        for name in names:
            path = os.path.join(base, name)
            if not os.path.isfile(path):
                continue
            relative = os.path.relpath(path, assets).replace(os.sep, "/")
            index.setdefault(digest(path), []).append(relative)
    return index


def data_source(entry, entries, ref_index):
    """返回 (源路径, source, pinned, sourcePath, reason)。"""
    name = entry["name"]
    relative = None
    install = entry.get("installPath") or ""
    if install.startswith("rootfs/"):
        relative = install[len("rootfs/"):]
    elif name.startswith("guest-runtime/rootfs/"):
        relative = name[len("guest-runtime/rootfs/"):]
    if relative is not None:
        path, resolved = resolve_rootfs(relative, entry, entries)
        if path is not None:
            return path, "redroid10", False, "/" + resolved, None

    if name in ("guest-runtime/runtime-check.dex", "guest-runtime/framework-check.dex"):
        dex = os.path.join(DEX, os.path.basename(name))
        if matches(dex, entry):
            return dex, "project-a10", False, "prepared.dex/" + os.path.basename(name), None
        reason = "dex 尚未自产，暂用参考件"
    elif name in PINNED_DATA_REASON:
        reason = PINNED_DATA_REASON[name]
    elif name.startswith(CASE_PREFIX):
        reason = "大小写冲突件在 Windows 解包时丢了另一份"
    else:
        reason = "参考 prepared 独有的数据件"

    generated_relative = GENERATED_DATA.get(name)
    if generated_relative:
        generated = os.path.join(MODULE, generated_relative.replace("/", os.sep))
        if matches(generated, entry):
            return generated, "project-a10-generated", False, generated_relative, reason

    path = os.path.join(REFERENCE, "assets", name.replace("/", os.sep))
    if matches(path, entry):
        return path, "redroid10" if name.startswith("guest-runtime/rootfs/") else "project-a10", True, "prepared-reference/" + name, reason
    candidates = ref_index.get(entry["sha256"], [])
    if candidates:
        relative = sorted(candidates, key=lambda value: (value.count("/"), value))[0]
        return (os.path.join(REFERENCE, "assets", relative.replace("/", os.sep)),
                "redroid10" if relative.startswith("rootfs/") else "project-a10",
                True, "prepared-reference/" + relative, reason)
    raise PrepareError("找不到数据件 %s（%d B，sha256=%s）"
                       % (name, entry["bytes"], entry["sha256"]))


def copy_file(source, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(source, target)


def prepare(args):
    inventory = load_inventory()
    files = inventory.get("files") or []
    data = inventory.get("data") or []
    index = rootfs_index()
    with open(os.path.join(MODULE, "rootfs-index.json"), encoding="utf-8") as handle:
        rootfs_entries = json.load(handle)["entries"]
    ref_index = reference_index()
    staged_files, staged_data, pinned = [], [], []

    file_plan = []
    for entry in files:
        source_path_full, source, is_pinned, source_path = file_source(entry, index)
        new = dict(entry)
        new["bytes"] = os.path.getsize(source_path_full)
        new["sha256"] = digest(source_path_full)
        new["source"] = source
        new["sourcePath"] = source_path
        new["pinned"] = is_pinned
        file_plan.append((entry, source_path_full, new))
        if is_pinned:
            pinned.append({"kind": "file", "name": entry["name"], "logical": entry["logical"],
                           "sha256": new["sha256"], "reason": PINNED_PROJECT_REASON[entry["logical"]]})

    # 同一份清单里只差大小写的 data 名字，Windows 暂存目录放不下两份，必须都转义。
    groups = {}
    for entry in data:
        groups.setdefault(entry["name"].lower(), []).append(entry)
    case_names = {item["name"] for group in groups.values()
                  if len({member["name"] for member in group}) > 1 for item in group}

    data_plan = []
    for entry in data:
        source, label, is_pinned, source_path, reason = data_source(entry, rootfs_entries, ref_index)
        new = dict(entry)
        new["source"] = label
        new["sourcePath"] = source_path
        new["pinned"] = is_pinned
        # 大小写冲突件统一转义成 rom-encoded/<sha256(原名)>.asset，并用 installPath 记录原名；
        # 这与旧流水线的命名逐字相同，运行时按 installPath 还原。
        if entry["name"] in case_names:
            original = entry["name"]
            relative = original[len("guest-runtime/rootfs/"):] if original.startswith("guest-runtime/rootfs/") else original
            new["name"] = "guest-runtime/rom-encoded/" + hashlib.sha256(original.encode("utf-8")).hexdigest() + ".asset"
            new["installPath"] = "rootfs/" + relative
        data_plan.append((entry, source, new))
        if is_pinned:
            pinned.append({"kind": "data", "name": entry["name"], "sha256": entry["sha256"],
                           "reason": reason})

    if args.check:
        print("files=%d data=%d pinned=%d" % (len(file_plan), len(data_plan), len(pinned)))
        for item in pinned:
            print("  pinned %-12s %s（%s）" % (item["kind"], item["name"], item["reason"]))
        return 0

    if os.path.isdir(STAGING):
        shutil.rmtree(STAGING)
    assets = os.path.join(STAGING, "assets")
    jni = os.path.join(STAGING, "jniLibs", "arm64-v8a")
    os.makedirs(assets, exist_ok=True)
    os.makedirs(jni, exist_ok=True)

    for entry, source, new in file_plan:
        copy_file(source, os.path.join(jni, new["name"]))
        staged_files.append(new)
    for entry, source, new in data_plan:
        copy_file(source, os.path.join(assets, new["name"].replace("/", os.sep)))
        staged_data.append(new)

    manifest = dict(inventory)
    manifest["files"] = staged_files
    manifest["data"] = staged_data
    manifest["frameworkSdk"] = 29
    manifest["apexAliases"] = True
    manifest["runtimeRoot"] = "/apex/com.android.runtime"
    manifest["assetPrefix"] = "guest-runtime/"
    manifest["generatedBy"] = "scripts/prepare-a10.py"
    write_json(os.path.join(assets, "guest-runtime-inputs.json"), manifest)

    check_staged(manifest, assets, jni)
    changed = [item["logical"] for item in staged_files
               if any(old["logical"] == item["logical"] and old["sha256"] != item["sha256"]
                      for old in files)]
    report = {
        "inventory": "prebuilt/a10-guest-runtime-inputs.json",
        "files": len(staged_files),
        "data": len(staged_data),
        "pinned": pinned,
        "changedFromReference": sorted(changed),
        "guestSdk": manifest.get("guestSdk"),
    }
    write_json(REPORT, report)
    print("files=%d data=%d pinned=%d changed=%d" % (len(staged_files), len(staged_data), len(pinned), len(changed)))
    for item in pinned:
        print("  pinned %-12s %s（%s）" % (item["kind"], item["name"], item["reason"]))
    if args.apply:
        replace_prepared()
        print("prepared 已切换到新内容")
    else:
        print("已写 %s；加 --apply 才切换 prepared/" % STAGING)
    return 0


def check_staged(manifest, assets, jni):
    problems = []
    for entry in manifest["files"]:
        path = os.path.join(jni, entry["name"])
        if not matches(path, entry):
            problems.append("files/" + entry["name"])
    for entry in manifest["data"]:
        path = os.path.join(assets, entry["name"].replace("/", os.sep))
        if not matches(path, entry):
            problems.append("data/" + entry["name"])
    if problems:
        raise PrepareError("自检失败，%d 条不符，例如 %s" % (len(problems), problems[0]))


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def replace_prepared():
    previous = os.path.join(MODULE, "prepared.previous")
    if os.path.isdir(previous):
        shutil.rmtree(previous)
    if os.path.isdir(REFERENCE):
        os.rename(REFERENCE, previous)
    try:
        os.rename(STAGING, REFERENCE)
    except OSError:
        if os.path.isdir(previous) and not os.path.isdir(REFERENCE):
            os.rename(previous, REFERENCE)
        raise
    if os.path.isdir(previous):
        shutil.rmtree(previous, ignore_errors=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="从 rootfs 与项目产物生成 A10 prepared")
    parser.add_argument("--check", action="store_true", help="只核对来源，不写文件")
    parser.add_argument("--apply", action="store_true", help="自检通过后替换 prepared/")
    parser.add_argument("--from-apk", action="store_true", help="走旧路径 extract-a10-inputs.py")
    args = parser.parse_args(argv)
    if args.from_apk:
        print("--from-apk 只作对照：请运行 python scripts/extract-a10-inputs.py")
        return 2
    try:
        return prepare(args)
    except PrepareError as failure:
        print("prepare-a10 失败：%s" % failure)
        return 1


if __name__ == "__main__":
    sys.exit(main())
