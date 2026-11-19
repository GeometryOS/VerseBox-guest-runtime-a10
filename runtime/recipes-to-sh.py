#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VerseBox contributors
"""把 companion 的 recipes.json 摊成可以直接 eval 的 shell 变量。

配套库单元原本用 jq 读这五份配方的 cflags、cppflags、includes 与 sources。jq 不在本仓库
声明的工具里，CI 与 Windows 上也未必有，所以用同一种语言做同一件事：每份配方输出四个变量，
名字是 <配方>_sources、<配方>_flags、<配方>_cppflags、<配方>_includes。

值用 shlex.quote 包过，交给 sh 的 eval 之后按原来的方式按空白拆词，与 jq 版本的用法一致。
"""
from __future__ import annotations

import json
import shlex
import sys


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: recipes-to-sh.py <recipes.json>", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as handle:
        recipes = json.load(handle)
    for name in recipes:
        recipe = recipes[name]
        key = name.replace("-", "_")
        print("%s_sources=%s" % (key, shlex.quote("\n".join(recipe.get("sources", [])))))
        print("%s_flags=%s" % (key, shlex.quote(" ".join(recipe.get("cflags", [])))))
        print("%s_cppflags=%s" % (key, shlex.quote(" ".join(recipe.get("cppflags", [])))))
        print("%s_includes=%s" % (key, shlex.quote(" ".join(recipe.get("includes", [])))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
