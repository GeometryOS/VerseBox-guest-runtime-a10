# A10 运行时构建说明（API 29）

本文说明本仓库怎么出 prepared、ROM 包与 APK 侧 payload，每件产物从哪来、按什么顺序跑、失败先看哪里。
规范化目标与阶段计划在 app 仓库的 `docs/android10-port/`，当前进度与下一步只看 [`STATUS.md`](STATUS.md)。

本仓库只管 ROM 侧的产品链。APK 由 app 仓库的 `:guest-runtime` 加 Gradle 编出来，两者唯一的交界是
`prepared-apk/`。编 ROM 与编 APK 是两条链，红线见 `_audit/10`。

## 1. 今天的一条链

现阶段的 `prepared` 来自参考 APK 的保真抽取，来源决定沿用 `docs/rom-package/05` §4 那次过渡决定。
抽取只搬运字节，不生成内容，也不改客体任何文件。

```text
参考 APK（<仓库父目录>/_bin/A10VM.apk）或 app 仓库的 runtime-inputs/guest-runtime
        │  scripts/extract-a10-inputs.py      逐条核对 bytes 与 sha256，不符就失败
        ▼
   prepared/                                assets + jniLibs/arm64-v8a + guest-runtime-inputs.json
        ├── rom/pack-rom.py            → dist/versebox-android10-<ver>.zip
        │                                dist/versebox-android10-<ver>-min.zip
        │                                dist/apk-resident-libs-android10.tar
        │                                dist/pack-android10-<ver>.json
        └── rom/stage-apk-payload.py   → prepared-apk/
                                          ├── assets/guest-runtime/lib/**     其余 1055 个客体 .so
                                          └── jniLibs/arm64-v8a/*.so          只留 resident 那 3 个
```

下一步在 app 仓库：Gradle 消费 `prepared-apk/` 与 `apk-resident-libs-android10.tar`，产出 `app-debug.apk`。
本仓库到此结束，不调用 `gradlew`，也不识读 app 工程。

### 1.1 镜像材料链（2026-11-19 落地，还没接进 prepared）

这条链是规范化要换上的来源。它今天能独立跑通，但 `build-a10.sh` 还没有调用它：
把 prepared 的来源换掉属于 S5，切换之前两条来源并存，旧的那条不动。

```text
sources.lock.json（redroid10 的 manifest、层 digest、字节数）
        │  scripts/fetch-redroid10.py      按 digest 解析 manifest，逐层核对 sha256 与字节数
        ▼
downloads/redroid10-layer0-47a4595f.tar.gz
downloads/redroid10-config.json            Entrypoint、Cmd、Env
downloads/manifest.json                    这次解析到的 digest 与所用 lock 的 sha256
        │  scripts/extract-rootfs.py       只落普通文件，类型、权限与链接目标进索引
        ▼
rootfs/                                    412 个目录、3458 个文件、573 个符号链接
rootfs-index.json                          4443 条
```

这两步每次都重跑，没有“产物在就跳过”的判断：解包一次约两分钟，比判断索引与树是否同步更省事。
接进入口时（S5）再加按产物存在性跳过的分支。

2026-11-19 实测：层 701,673,445 B，sha256 与 lock 的 `47a4595f…` 一致；解出 1,572,657,491 B。
redroid 10 的镜像已经把 APEX 摊成 `system/apex/<name>/` 目录，里面没有 `.apex` 压缩包，
所以这条链不需要 A15 那样的 `extract-apex.py`。

### 1.2 源码运行时（2026-11-19：闭包齐了，还没进 prepared）

这一段是 L1 与 L2 的料。源码从 app 仓库的 `container-probe/runtime/` 原样复制进来，逐字节未改，
入口脚本已经改到本仓库的路径，五个产物都编出来了。

闭包一共六件，五件自建、一件取自镜像：

| 件 | 来源 | 判据 |
| --- | --- | --- |
| `ld-android.so`、`libc.so`、`libdl.so` | 自建，源在 `vendor/runtime/{dynamic,filesystem}` | SONAME 与 `DT_NEEDED` 见下表 |
| `libm.so`、`libunwind.so` | 自建，源在 `vendor/runtime/companion` | 导出的具名符号集与 prepared 那份完全相同，分别是 286 与 37 个 |
| `libc++.so` | 镜像 `system/lib64/libc++.so`，841,888 B | 与 prepared 里那份 sha256 都是 `d7416af0…`，837 个客体库按它链接 |

`libc++.so` 不自建的理由是取证出来的，不是省事：装机那一份就是镜像那份，自建会多出第二份 libc++，
而 `_LIBCPP_VERSION` 与 ABI 一旦漂移，受影响的不是一两个库。

```text
container-probe/runtime/              迁入后                          作用
  dynamic/ 25 个文件        ──▶  vendor/runtime/dynamic/             linker、libc 的动态构建
  filesystem/ 24 个文件     ──▶  vendor/runtime/filesystem/          路径与身份替换源
  companion/ 24 个文件      ──▶  vendor/runtime/companion/           配套数学与展开库的配方
  archives.txt              ──▶  runtime/lists/archives.txt         四条 AOSP 10 pin
  static-sources.txt        ──▶  runtime/lists/static-sources.txt   静态闭包的源清单
  sources.sha256            ──▶  runtime/lists/sources.sha256       逐文件哈希
  build-native.sh           ──▶  runtime/legacy/build-native.sh      旧入口，已被 build-a10-runtime.sh 取代
  fetch-sources.sh          ──▶  runtime/legacy/fetch-sources.sh     旧取源，已被 fetch-a10-sources.py 取代
  record-sources.py         ──▶  runtime/record-sources.py          按编译依赖重算哈希清单
  test-native.py            ──▶  runtime/test-native.py             本机跑三个探针
  platform.patch            ──▶  runtime/platform.patch             bionic_systrace 的格式化补丁
  arm64-tls.ld              ──▶  runtime/arm64-tls.ld               TLS 段 64 字节对齐
  prepare-apk.sh            ──▶  runtime/legacy/                    旧流水线，对照，不在链上
  README.md                 ──▶  runtime/legacy/                    旧的 P2 记录，对照
```

旧入口 `build-native.sh` 与 `fetch-sources.sh` 已经移到 `runtime/legacy/`，构建链不再调用它们。
现在的入口是 `runtime/build-a10-runtime.sh`，五步一条链，只读本仓库：

```sh
sh runtime/build-a10-runtime.sh --plan-only   # 打印输入是否存在、五步顺序与产物路径，不执行
sh runtime/build-a10-runtime.sh              # fetch → static → linker → libc → companion
```

运行时五个产物都已从源码产出：

| 产物 | 字节 | 判据 |
| --- | --- | --- |
| `runtime/build/lib/liba10vm-bootstrap.a` | 587,466 | 清单原样，另加四个链接错误点名的闭包成员；字节数与本轮之前的记录对不上，见 `STATUS.md` §3 |
| `runtime/build/bin/source-linker64` | 813,696 | `llvm-nm -u` 空，SONAME `ld-android.so`，无 `DT_NEEDED` |
| `runtime/build/lib/libc.so` | 1,316,488 | SONAME `libc.so`，`DT_NEEDED` 只有 `libdl.so` 与 `ld-android.so` |
| `runtime/build/lib/libdl.so` | 11,744 | SONAME `libdl.so`，`DT_NEEDED` 只有 `ld-android.so` |
| `runtime/build/lib/libm.so` | 287,504 | SONAME `libm.so`，`DT_NEEDED` 只有 `libc.so`，导出 286 个具名符号 |
| `runtime/build/lib/libunwind.so` | 57,480 | SONAME `libunwind.so`，`DT_NEEDED` 是 `libc.so` 与 `libdl.so`，导出 37 个 |

两份源码补丁的 hunk 头与正文行数对不上，脚本按正文重算后用 GNU `patch -p1 -t` 应用，
`git apply` 会整份判成"无可应用"并静默跳过。

打包工具来自 NDK。入口在 `clang` 不在 PATH 时自己找：`A10_NDK` 优先，其次 `ANDROID_NDK_HOME`、
`ANDROID_NDK_ROOT`，最后看 `ANDROID_HOME/ndk` 或 `ANDROID_SDK_ROOT/ndk` 下是不是只有一个版本。
有多个版本时不替人挑，直接失败并把候选列出来，因为挑错版本编出来的运行时符号与镜像对不上。
Windows 上 `A10_NDK` 写成 `C:\\…` 也可以，入口先用 `cygpath` 转成 `/c/…` 再判存在。

## 2. 入口

一条命令跑完三步，参数只决定跑哪几段，不改变内容来源。

```sh
sh scripts/build-a10.sh                  # prepared → ROM 包 → prepared-apk
sh scripts/build-a10.sh --plan-only      # 只打印要跑的段与产物路径，一步都不执行
sh scripts/build-a10.sh --skip-extract   # 只跳过 prepared，复用 prepared/
sh scripts/build-a10.sh --skip-rom       # 不产 ROM 包，只出 prepared 与 prepared-apk
```

| 参数 | 影响 | 不影响 |
| --- | --- | --- |
| `--plan-only` 或 `A10_PLAN_ONLY=1` | 打印 module、ROM 身份、prepared 来源与是否存在、ROM 包路径、payload 路径、镜像链状态，退出码 0 | 任何产物，任何解包与打包 |
| `--skip-extract` | 跳过 prepared 这一步，要求 `prepared/assets/guest-runtime-inputs.json` 已存在 | ROM 包与 prepared-apk，这两步照常重做 |
| `--skip-rom` | 不产 ROM 包 | prepared 与 prepared-apk |
| `--rom-version` | 覆盖 `rom/rom.properties.yaml` 的 `defaultRomVersion` | 内容与清单 |
| `--lib-mode` | 覆盖 `libMode`，取值 `apk`、`rom`、`both` | 内容与清单 |
| `--apk` | 指定参考 APK 路径 | 抽取规则 |

解释器按 `PYTHON` 环境变量、`python3`、`python` 的顺序探测，写死 `python` 会让只有 `python3` 的发行版第一步就失败。
退出码约定：0 成功，1 缺工具或缺 prepared，2 未知参数。

只 clone 本仓库时，`--plan-only` 必须能说清会跑到哪一步并返回 0，这是第三方排障的第一个入口。
参考 APK 不在时它打印“缺失”，不会替你去猜。

## 3. 产物

| 文件 | 内容 | 谁用 |
| --- | --- | --- |
| `downloads/` | 镜像层、镜像 config、`manifest.json` | `extract-rootfs.py` 的唯一输入 |
| `rootfs/` | 从层解出的文件树，只有普通文件 | S5 之后 prepared 的来源 |
| `rootfs-index.json` | 4443 条，记类型、mode、uid、gid、链接目标与层 digest | 还原符号链接与硬链接，复核来源 |
| `prepared/` | 清单加 `assets/guest-runtime/**` 与 `jniLibs/arm64-v8a/*.so` | 下面两条链的共同输入 |
| `dist/versebox-android10-<ver>.zip` | `versebox_properties.yaml`、`versebox_inputs.json`、`payload/{rootfs,lib,rom-encoded}` | 用户导入，或进 app 的 `assets/kanadex-rom/` |
| `dist/versebox-android10-<ver>-min.zip` | 只有自述的占位包，`placeholder: true` | 让 APK 声明支持这个系统而不背 payload |
| `dist/apk-resident-libs-android10.tar` | 必须进 APK `lib/arm64-v8a` 的 `.so`，平铺 0755 | app 构建时解到 `build/rom-dist/apk-libs` |
| `prepared-apk/` | 旧格式 payload，客体 .so 在 `assets/guest-runtime/lib/**` | `:guest-runtime` 的 `verifyRuntime` |
| `dist/pack-android10-<ver>.json` | 打包自检报告 | 排查“这包怎么来的” |

2026-11-19 实测的产物身份，只用内容标识，不用版本号：

| 文件 | 字节 | sha256 |
| --- | --- | --- |
| `dist/versebox-android10-1.0.0.zip` | 665,625,441 | `db546331be3bddffafc809e7c6bb08d9c8ec80220fc74c5ee054093a269bd38a` |
| `dist/versebox-android10-1.0.0-min.zip` | 756 | `5486a08cea24b1aacb4419ef6592186c2408b0ca0a07a9466a353350d30abf61` |
| `dist/apk-resident-libs-android10.tar` | 7,956,480 | `46fb05d2707f15e34a1ba6a9ce25c20487a6f2401973a7994a214eeed1cb99bf` |

`dist/pack-android10-1.0.0.json` 里记着 `payloadBytes=1521501037`、`payloadFiles=3267`、
`payloadSha256=96ad350e…`、`manifestFiles=1058`、`manifestData=2209`、`libMode=rom`、`bundledLibs=1058`、
`packSeconds=45.1`。打包器把报告写在自己旁边，不要在别处手抄这些数字。

## 4. 十层：今天进了哪几层

分层编号沿用 app 仓库的 `docs/android9-port/02-A10构建契约.md`，契约细节见 `docs/android10-port/02`。

| 层 | 内容 | 今天的产出者 | 状态 |
| --- | --- | --- | --- |
| L0 | Redroid 10 镜像与 rootfs | `scripts/fetch-redroid10.py` 与 `scripts/extract-rootfs.py` | 有（2026-11-19），还没接进 prepared，S5 |
| L1 | 源码运行时 linker、libc、libdl、libm、libunwind，以及取自镜像的 libc++ | `runtime/build-a10-runtime.sh`，产物在 `runtime/build/{bin,lib}`；libc++ 用 `rootfs/system/lib64/libc++.so` | 有（2026-11-19）：五件自建产物齐，第六件取证后定成镜像提供 |
| L2 | 路径、身份、属性补丁 | `vendor/runtime/filesystem` 的 18 个 C/C++，由 `runtime/build-static.sh` 与 `build-libc.sh` 编进归档与 libc | 有（2026-11-19） |
| L3 | 属性服务 | `bridges/build-properties-a10.sh`，源码在 `vendor/native` 与 `vendor/properties`，产物在 `bridges/properties` | 有（2026-11-19）：三件，`property-service` 的 NEEDED 与未定义集合和 `prepared` 那份一致 |
| L4 | Binder 与 HwBinder 传输 | `bridges/build-binder-a10.sh`，源码在 `vendor/binder`，产物在 `bridges/{lib/registry,bin}` | 有（2026-11-19）：七个库加两个进程，符号面与 `prepared` 那份相同 |
| L5 | 设备、日志、管理器策略 | `bridges/build-devices-a10.sh`，源码在 `vendor/native`，产物在 `bridges/devices/lib` | 有（2026-11-19）：五件，缺的导出符号为 0，两件的未定义集合与 `prepared` 完全相同 |
| L6 | 图形兼容层 | `bridges/build-graphics-a10.sh`，源码在 `vendor/graphics`，产物在 `bridges/graphics/lib`；宿主端点在 app 侧 | 有（2026-11-19）：六个客体库，codec id 与宿主渲染器内嵌的那个一致，符号面与 `prepared` 那份相同 |
| L7 | 可选桥：网络、音频、媒体、相机 | `bridges/build-media-a10.sh`，接口头由 `runtime/build-media-tools.sh` 在 WSL 里生成 | 有（2026-11-19）：网络与音频两件、媒体七件都已通，七件的未定义符号集合与 `prepared` 那份差集为 0；相机未落 |
| L8 | prepared 与清单 | `scripts/prepare-a10.py` 只出"项目件"那一半；镜像那一半仍由 `scripts/extract-a10-inputs.py` 与参考 APK 提供 | 部分（2026-11-19）：`staged=31 missing=9 host=2`，逐件带来源标签 |
| L9 | dex | `bridges/build-dex-a10.sh` 出客体侧 `libdexfile.so`（dex-cache 单元）；`framework-check.dex` 与 `runtime-check.dex` 仍随 prepared 从参考 APK 抽出 | 部分（2026-11-19）：`libdexfile` 已自产，两个 check dex 还要 S5 |
| L10 | app 侧消费 | app 仓库的 `:guest-runtime` 与 `rom-embed.json` | 不在本仓库 |

L8 与 L9 的“有”只指本仓库能产出当前这份内容，不指能重新生成它。判据是删掉 `prepared/` 之后，
除了参考 APK 或 `runtime-inputs` 之外还需要什么；今天什么都不需要，因为内容是搬的。
S5 之后这条判据变成“只需要镜像、AOSP 10 源与 NDK”。

### 4.1 体量对照

A15 提交 1,090 个文件，A10 今天 358 个，其中 61 个是 S3 从 `container-probe/runtime` 搬进来的，
59 个是 S4 的 binder 组从 `container-probe/binder` 与 `guest-runtime/native` 搬进来的，
128 个是 S4 的图形组从 `container-probe/graphics` 搬进来的（101 个原样复制品加 26 份 emugen 产物），
另 18 个是属性、设备、媒体三组从 `guest-runtime/native` 搬进来的客体源。
S5 另加了 `scripts/prepare-a10.py`。
差的东西不是几个脚本，是另外两个单元的源码与三个域的桥。这张表按目录数，口径是不含 `.gitignore` 忽略的
产物目录与 `rootfs-index.json`，含仓库根那份未登记的 `guest-runtime-a10.zip`。
这张表用来防止“A10 已经差不多了”的错觉；每一行都写着由哪一段长出来。

| 目录 | A15 提交 | A10 今天 | 由哪一段长出来 |
| --- | --- | --- | --- |
| `third_party/` | 500 | 0 | 不照搬：图形上游改走 `runtime/upstream` 的四个仓库（goldfish、qemu、`frameworks/native`、`hardware/libhardware`），归档清单在 `vendor/graphics/archives.txt` |
| `vendor/` | 314 | 301（`properties` 22、`runtime` 73：`dynamic` 25、`filesystem` 24、`companion` 24、`binder` 58、`native` 19、`graphics` 128、`media` 1） | S3 落了四个运行时单元，S4 落了 binder、图形、属性、设备、媒体五组；`dex-cache` 判定的范围已改成"不进 libart，进 libdexfile"，见 STATUS §3 |
| `bridges/` | 200 | 7（`compile.sh` 加 binder、图形、属性、设备、媒体、dex 六条 `build-*-a10.sh`，产物目录不入库） | S4 只剩 `image/a10vm-init` |
| `runtime/` | 14，另有上游 10,095 个文件靠脚本重取、不入库 | 30 | S3 的入口、清单与单元脚本已落位，S4 补了 `toolchain.sh`；上游 2,033 个受校验文件靠 `fetch-a10-sources.py` 重取 |
| `scripts/` | 13 | 5 | S1、S2 各落一批，S5 落了 `prepare-a10.py` 的第一段 |
| `bootstrap/` | 9 | 0 | S5，dex 的 Java 源 |
| `rom/` | 7 | 7 | 已有 |
| `.github/` | 6 | 0 | S6，CI 单独一轮 |
| `doc/` | 8 | 0 | 不适用，A10 的移植文档在 app 仓库 |
| 零散条目：LICENSE、README、BUILD、STATUS、.gitignore、assets、prebuilt、LICENSES、vintf、native、bootanim、release、src、Gradle 脚本与 prop | 19 | 5 | 逐步 |

### 4.2 桥的入口与产物

    sh bridges/build-binder-a10.sh

一条命令编出 binder 组的九个产物，落在 `bridges/lib/registry` 与 `bridges/bin`，报告与配方落在
`bridges/obj/binder`。入口只有一条前提：`runtime/build/lib` 的五件运行时产物与
`rootfs/system/lib64/libc++.so` 已经在位，缺了直接失败，不回退到 NDK 的库。

```text
vendor/binder/native/*.cpp ──┐
runtime/upstream/frameworks/native/libs/binder ─┤
runtime/upstream/system/core/{liblog,base,libcutils,libutils} ─┼─▶ bridges/lib/registry/*.so
vendor/binder/platform.patch（改 open/ioctl/mmap） ─┘        └─▶ bridges/bin/{binder-broker,binder-registry}
runtime/build/lib/{libc,libdl,libm,libunwind}.so ──────────────┘
rootfs/system/lib64/libc++.so ─────────────────────────────────┘
```

判据三条：`llvm-readelf -d` 的 NEEDED 全指向本仓库的运行时与镜像的 `libc++.so`；
导出符号集与 `prepared` 里同名文件两个方向差集为空；`bridges/obj/binder/binder.sha256` 两轮构建同值。

### 4.3 图形组的入口与产物

    sh bridges/build-graphics-a10.sh

一条命令编出六个客体图形库，落在 `bridges/graphics/lib`，派生件在 `bridges/graphics/derived`，
逐件的 `llvm-readelf` 与 `llvm-nm` 输出留在同名 `.elf.txt` 与 `.undefined.txt`。

```text
vendor/graphics/{native,desktop}/*.cpp ─────────────────┐
vendor/graphics/generated/{gl2,renderControl}_* ───────┤  emugen 产物，随 qemu 与 goldfish 的提交一起换
runtime/upstream/device/generic/goldfish-opengl ────────┤
runtime/upstream/external/qemu/android/android-emugl ───┼─▶ bridges/graphics/lib/*.so
runtime/upstream/frameworks/native/{opengl,libs} ───────┤
runtime/upstream/hardware/libhardware ──────────────────┤
bridges/lib/registry/{libutils,liblog,libcutils} ───────┤
runtime/build/lib 四件 + 镜像的 libc++、libnativewindow、libhardware、libsync ┘
```

判据四条：`bridges/graphics/codec-id.txt` 里的值与 `prepared` 的宿主渲染器内嵌的 64 位串逐字相同；
每个库的 NEEDED 都在允许清单里，这条闸门写在脚本里；对 `prepared` 同名副本缺的导出符号为 0；
连跑两次产物同哈希。图形上游今天只有提交钉住，逐文件清单是 S4 收尾的活。

### 4.4 属性组与设备组的入口

    sh bridges/build-properties-a10.sh
    sh bridges/build-devices-a10.sh

属性组要先跑 `sh runtime/prepare-properties.sh`，它按 `vendor/properties/sources.txt` 取 28 个文件、
按 `sources.sha256` 校验，再把派生树落到 `runtime/build/properties/derived`。产物三件：
`bridges/properties/bin/{property-service,seed-properties}` 与 `bridges/properties/lib/liba10vm-property-client.so`。

设备组只依赖运行时闭包与 binder 组的 `liba10binder.so`，产物五件在 `bridges/devices/lib`。
两组的源码都在 `vendor/native`，复制清单留着哈希证据。

判据三条：对 `prepared` 同名副本缺的导出符号为 0；每个产物的 NEEDED 都在脚本里的允许清单内；
删掉 `bridges/properties` 与 `bridges/devices` 重跑，八个产物逐件同哈希。

### 4.5 dex 单元

    python runtime/fetch-dex-sources.py     按提交取 LineageOS art 的 dex 子树
    sh bridges/build-dex-a10.sh             编 libdexfile，产物在 bridges/dex/lib

`cache.patch` 打在这份源码上，编出带 `DexArchiveCache` 的 `libdexfile.so`。它替换的是客体里的
`libdexfile`，不是 `libart`：`prepared` 的 `libart.so` 与镜像逐字节相同，而 `libdexfile.so` 不是。
判据：对 `prepared` 同名副本缺的导出为 0；NEEDED 只落在镜像的 `libartbase/libartpalette/libbase/liblog/libcrypto`
与本仓库运行时；连跑两次同哈希。

### 4.6 媒体组

    sh runtime/build-media-tools.sh      宿主生成器：hidl-gen 与 351 个接口头（要 bison、flex、clang）
    python runtime/media-deps.py         从 rootfs 抽 120 个 ARM64 链接依赖
    sh bridges/build-media-a10.sh        netd、音频 HAL 与媒体七件

第一步是**宿主**工具，只能在有 `bison`/`flex` 的 Linux 上跑（CI 的 ubuntu 或 WSL），产物是纯文本头；
第二、三步在哪个平台都行。七件的判据：对 `prepared` 同名副本缺的导出为 0，
未定义符号集合差集为 0，NEEDED 全部落在镜像与本仓库运行时。

### 4.7 项目件落位

    sh bridges/build-media-a10.sh        netd 客户端与音频 HAL，产物在 bridges/media/lib
    python scripts/prepare-a10.py        项目件按身份落进 prepared.staging

媒体脚本今天只出两件：`libnetd_client.so` 与 `audio.primary.a10vm.so`。其余七件要 AOSP 10 的
`hidl-gen` 与 `aidl` 生成接口头，而这两支生成器要宿主的 `bison` 与 `flex`，本机没有；
这一支只能在 ubuntu 的 CI 或有这两个工具的 Linux 上跑。

`prepare-a10.py` 是 S5 的第一段：读 `prepared/assets/guest-runtime-inputs.json` 拿身份，
按脚本里那张 `logical → 本仓库路径` 的表找字节，把项目件落进 `prepared.staging/jniLibs/arm64-v8a`，
再写 `prepared.staging/project-manifest.json`。它**不改 `prepared`**，只产出一个带来源标签的暂存树。
镜像那一半（1,016 件改名搬运、2,209 条 data、574 条符号链接、78 个系统 APK、172 条属性）还没有规则。

## 5. 失败先看哪里

| 现象 | 先看 | 处理 |
| --- | --- | --- |
| `找不到 python3 或 python` | `PYTHON` 环境变量，`command -v python3` | 指定解释器；不要改回写死的 `python` |
| `缺少本仓库的工具：...` | 报错点出的那个路径 | 工作目录不对，或 clone 不全 |
| `找不到参考 APK：...` | `--plan-only` 打印的 prepared 来源与“存在/缺失” | 补参考 APK、改 `--apk`，或换 `runtime-inputs` |
| `参考 APK 与清单不一致（N 条）` | 抽取器打印的第一条差异 | 换过 APK 或清单被改过；取回原始 APK，不许改清单里的 `bytes` 与 `sha256` |
| `prepared 不存在，去掉 --skip-extract` | `prepared/assets/guest-runtime-inputs.json` | 去掉 `--skip-extract` 先跑抽取 |
| `--verify-only` 不过 | 它打印的第一个不匹配条目 | 重跑打包；不许手改 zip |
| 想知道某条命令会不会动 prepared | `sh scripts/build-a10.sh --plan-only` | 打印的是来源、路径与跳过状态，不执行任何一步 |
| `sources.lock.json 里没有 redroid10 条目` | lock 文件是否是复制来的那份 | 用 `guest-runtime/sources.lock.json` 覆盖，别手改字段 |
| `lock 固定的层 ... 不在这次解析的 manifest 里` | 上一行的 resolved 输出与 lock 的层 digest | 镜像或 lock 有一边变了；先确认是哪一边，不许改 lock 去凑 |
| `层 0 的 sha256 不符` | 下载中断或代理改写了内容 | 删掉 `.part` 与目标文件重下；不许跳过校验 |
| 解包后条目数明显偏少 | `--layer` 是否指向了别的文件 | 回到 `downloads/manifest.json` 的层清单，重新解 |
| `bridges/compile.sh: 缺 ... 先跑 sh runtime/build-a10-runtime.sh` | 报错点出的那个产物 | 先编运行时闭包；桥要链接 `runtime/build/lib` 里那五件 |
| `build-binder-a10.sh: platform.patch 没落到 ...` | `patch` 自己的输出（Skipped、malformed） | 补丁必须用 GNU `patch -p1 -t`；`git apply` 会静默跳过，退出码 0 也不改字节 |
| `build-dex-a10.sh` 报 `'jni.h' file not found` | `runtime/upstream/libnativehelper/include_jni` 在不在 | `jni.h` 来自 AOSP 10 的 `libnativehelper`，已钉在 `runtime/lists/archives.txt`；取源之后才有 |
| `build-graphics-a10.sh: 补丁没落地 ...` | `git apply` 的报错原文 | 图形的八份 desktop 补丁与 `platform.patch` 的 hunk 头是手写裁剪过的，只有 `git apply --recount` 能落地；落地与否由脚本里的 `grep` 判据决定 |
| `graphics: codec id 算不出来` 或算出来的值跟宿主不一致 | `build-graphics-a10.sh` 里那行 `sha256sum -t` | 少写 `-t` 就会算成另一个 id，因为 Git for Windows 默认二进制输出；客体与宿主从此互相拒绝 |
| 编 `gralloc.cpp` 报没有 `validateBufferSize` | include 里有没有 `-I"$Q/guest"` | 那一份是 qemu 自带的旧 `gralloc.h`，只属宿主渲染器；客体侧不能带 |
| `ld.lld: error: undefined symbol: __android_log_buf_print` 之类 | 该库的依赖顺序 | `libbase` 依赖 `liblog`，`libcutils` 依赖 `liblog` 与 `libbase`，顺序错就过不了 `--no-undefined` |

症状与装机侧的对应关系在 app 仓库的 `docs/android10-port/09`，这里只放构建侧。

## 6. 不变量

1. 只 clone 本仓库时必须能完整出包并干净退出。没有 app 工程不是失败，是这种用法本身。
2. 三个运行时仓库互不引用脚本，唯一必须逐字节一致的是 `rom/rom_hash.py` 的算法。
3. 清单与 payload 的字节数、哈希一律由脚本算出来。手改清单或手塞文件会让 `--verify-only` 拒收。
4. 缺条件就失败。缺 NDK、缺 JSON 工具、缺 dex 输入都不许回退到旧产物。
5. `prepared/`、`prepared-apk/`、`dist/` 是产物，不入库，见 [`.gitignore`](.gitignore)。
6. 参考 APK 是历史产物。S5 之后它只作对照，不再是输入。
7. 往 ROM 里放宿主侧产物是错的。`desktop-window`、`p1-client`、`desktop-gpu-host` 都不进 payload。
8. `runtime/upstream` 的顶层只允许出现仓库根，解包只有一条 `tar -mxzf`，与 A9、A15 逐字相同。
9. 一个仓库的源只在一个清单里声明：A10 自己的源在 `runtime/lists/archives.txt`，单元的源在单元目录里。

## 7. 与其它文档的分工

| 想知道 | 看哪 |
| --- | --- |
| 现在到哪、下一步做什么 | [`STATUS.md`](STATUS.md) |
| 规范之后应该长什么样，十层的验收 | app 仓库 `docs/android10-port/02` |
| S0 到 S6 的阶段与退出条件 | app 仓库 `docs/android10-port/05` |
| 入口契约、将来 CI 的输入 | app 仓库 `docs/android10-port/06` |
| 清单字段与每个字段谁在读 | app 仓库 `docs/android10-port/07` |
| 打包器与 stager 的分工 | [`rom/README.md`](rom/README.md) |
| 跨会话纪律与红线 | app 仓库 `_audit/` |
