#!/usr/bin/env python3
import hashlib
import json
import pathlib
import shlex
import shutil
import subprocess
import sys

object_path = pathlib.Path(sys.argv[1])
command = sys.argv[2:]
dependency_path = pathlib.Path(str(object_path) + ".d")
cache_path = pathlib.Path(str(object_path) + ".cache.json")
compiler = pathlib.Path(shutil.which(command[0])).resolve()
compiler_stat = compiler.stat()
identity = [str(compiler), compiler_stat.st_size, compiler_stat.st_mtime_ns]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dependency_names():
    """从 -MD 生成的 .d 里取出依赖列表。

    .d 的第一段是"目标:"，去掉它要按目标名定位，不能按冒号切：Windows 的盘符本身
    就是冒号，按冒号切会把 D:/... 切成 "/..." 这种半截路径。
    """
    text = dependency_path.read_text(encoding="utf-8").replace("\\\n", " ")
    # 目标在 .d 的第一段，形如 "<某个斜杠形式的 .o>: "；按 ".o:" 定位，
    # 这样不依赖 Windows 盘符冒号，也不依赖 ../ 还是 \\ 的分隔符写法。
    index = text.find(".o:")
    if index >= 0:
        text = text[index + 3:]
    return sorted({name.replace("\\", "/") for name in text.split()})


def signature():
    inputs = {name: digest(pathlib.Path(name)) for name in dependency_names()}
    return {"command": command, "compiler": identity, "inputs": inputs,
            "object": digest(object_path)}


try:
    cached = json.loads(cache_path.read_text(encoding="utf-8"))
    if cached == signature():
        sys.exit(0)
except (OSError, ValueError, IndexError):
    pass

cache_path.unlink(missing_ok=True)
result = subprocess.run(command)
if result.returncode:
    sys.exit(result.returncode)
cache_path.write_text(json.dumps(signature(), sort_keys=True) + "\n", encoding="utf-8")
