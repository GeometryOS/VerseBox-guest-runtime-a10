# Android 10 运行时仓库 · 真实进度

最后更新：2026-11-20

一句话：APK 导入已由维护者确认修复。ROM 1.0.1 的 HWC host-fence fallback 已编译并通过 ABI/打包校验，但已在实体机实例 `1795154236450` 证实无效：状态栏/导航栏与动画仍抽搐。该实例确实加载 SHA `eeb34ac2…` 的新 HWC；日志仍有 8 条 `No local sync point found`、5 次 35–111 帧跳帧、最高 3,217 ms slow delivery、导航栏窗口冻结 620 ms。不能继续宣称该 fence 机制是根因或已修复。
错误实验 ROM `dist/versebox-android10-1.0.1-hwc-native-fence-fallback.zip` 保留供取证；原 `prepared/` 与 `1.0.0` ROM 未改。下一步回到同一实例的 `presentDisplay`/SurfaceFlinger buffer acquire-release 时间线，定位实际停住的是哪个 producer/consumer，不做新构建直到能说明可证伪判据。

## 0. 新会话从这里开始

三句话交接：

1. 42 件项目产物已收口：39 件由本仓库源码编出，`image/a10vm-init` 与两个宿主件按字节钉在
   `prebuilt/arm64/`，各自带 `.sha256`。`prepared` 已由 rootfs 与这批产物重新生成，
   1058 个 native、2209 条 data，26 件 pinned，逐条在 `prepared/prepare-report.json`。
2. 真机已越过 seed、ART 与框架入口并到达 `READY`，当前仍可运行 A10。早期 `Wrong guest SDK` 卡点已通过 libc 属性区修复关闭，取证与修正过程保留在 `docs/android10-port/11-进展日志.md` 的 2026-11-19 记录；这不是本轮图层卡顿的原因。
   APK 导入已由维护者确认在 Android Studio 新版 app 中恢复；本轮不要求再构建 app 或重复导入测试。
3. 不许重试的路径在 §8。另外 `bridges/` 的 .gitignore 已改成只排除产物目录，源码目录不再被整体忽略；
   `bootstrap/` 只放 A10 的四个入口类，不搬 `guest-runtime/check` 的共用实现。
   这一轮曾给 `vendor/runtime/filesystem/GuestPaths.cpp` 加过属性区豁免，已按字节回滚，
   源文件 sha256 与 `container-probe` 原件一致；`runtime/build/lib/libc.so` 仍是 `ef057e1f…`。

构建环境的固定前缀，缺一个都会走错工具：

```sh
PATH="<NDK 29.0.14206865>/toolchains/llvm/prebuilt/windows-x86_64/bin:/d/Program/Git/usr/bin:/d/Program/Git/bin:<repo>/_bin/a10/toolshim:$PATH"
sh runtime/build-a10-runtime.sh --plan-only
```

`<repo>/_bin/a10/toolshim/python3` 是一个 shim，把 `python3` 指到本机真实的 CPython；
WindowsApps 里那个 `python3.exe` 是商店占位，跑不起来。

## 1. 当前阶段（2026-11-19）

| 阶段 | 状态 | 判据 |
| --- | --- | --- |
| S0 取证与文档基线 | 完成 | app 仓库 `docs/android10-port/` 十二篇，数字可在文件里复核 |
| S1 仓库骨架与入口 | 完成 | 本文 §2 的七条已验证，外加 `BUILD.md` 与本文 |
| S2 镜像与 rootfs | 完成（2026-11-19）：fetch 与 extract 都跑通，prepared 还没切 | 本文 §2 的镜像四条；产物是 `downloads/`、`rootfs/`、`rootfs-index.json` |
| S3 源码运行时（C/C++） | 完成（2026-11-19）：闭包五件自建产物齐，第六件 `libc++` 取证确认取自镜像；`dex-cache` 判定不入链 | `runtime/build/{lib/liba10vm-bootstrap.a, bin/source-linker64, lib/libc.so, lib/libdl.so, lib/libm.so, lib/libunwind.so}`，判据见 §2；上游 1,562 个文件校验通过 |
| S4 桥与图形（C/C++） | 完成（2026-11-19）：binder、图形、属性服务、设备与日志、媒体与 drm 五组完成；`image/a10vm-init` 与两个宿主件按 `_audit/00` §4.4 钉住 | `bridges/lib/registry` 七个库与 `bridges/bin` 两个进程、`bridges/graphics/lib` 六个库、`bridges/properties` 三件、`bridges/devices/lib` 五个库、`bridges/media` 七件；导出面对 `prepared` 那份缺零个；`prebuilt/arm64/` 三件带 `.sha256`，判据见 §2 与 §10 |
| S5 prepared 与 dex | 进行中（2026-11-19）：prepared 已由 rootfs 重新生成并通过打包自检；dex 仍 pinned，26 件 pinned 逐条有记录 | `python scripts/prepare-a10.py --apply` 得到 1058 个 native、2209 条 data；`python rom/pack-rom.py --verify-only dist/versebox-android10-1.0.0.zip` 通过；`prepared/prepare-report.json` 列 26 件 pinned，判据见 §10 |
| S6 发布与 app 入库 | 未开始 | 没有 `.github/`，没有 tag 与 Release；CI 由维护者另开会话补 |

## 2. 已验证

每条都附判据命令与结果摘要，原始输出在 app 仓库的 `_bin/a10/logs/`。

| 改动 | 判据 | 结果 |
| --- | --- | --- |
| `scripts/build-a10.sh` 加 `--plan-only` 与 `A10_PLAN_ONLY` | `sh scripts/build-a10.sh --plan-only`、`A10_PLAN_ONLY=1 sh scripts/build-a10.sh` | 两条退出码 0，打印 module、ROM 身份、prepared 来源与存在性、ROM 包路径、payload 路径、镜像链状态与“APK 由 app 仓库编” |
| 同一入口的参数组合 | `--plan-only --skip-rom --rom-version 9.9.9 --lib-mode both`、`--plan-only --skip-extract`、`--plan-only --apk <不存在的路径>` | 三条退出码 0；分别打印“跳过（--skip-rom）”、“复用 prepared/”、“参考 APK，缺失” |
| 语法与解释器探测未被破坏 | `sh -n scripts/build-a10.sh`；`sh -x scripts/build-a10.sh --plan-only` 的轨迹 | 退出码 0；轨迹里有 `PY=python3`；`grep -c '^[[:space:]]*python[[:space:]]'` 为 0 |
| `--help` 补 `--skip-extract` 语义与 `--plan-only` | 旧版本与新版本各跑一次 `--help` 再 `diff` | 两个版本退出码 0，diff 只有第一行加 `[--plan-only]` 与新增 9 行，旧行一条未改 |
| 只 clone 本仓库时的入口 | 在 `_bin/a10/scratch/isolated-clone/` 只有 `scripts/`、`rom/`、`README.md`、`.gitignore` 的副本里跑 `--plan-only` | 退出码 0，prepared 来源打印默认路径并标“缺失”，不抛“gradlew 找不到” |
| plan-only 不动产物 | plan-only 前后各记一次 `prepared` 的文件数与 `dist`、`prepared-apk` 的目录 mtime | 文件数 3268 前后一致，两个目录的 mtime 未变 |
| 结尾说明 APK 归属 | 阅读脚本结尾与 `--plan-only` 输出 | 两处都写明 APK 由 app 仓库消费 `prepared-apk/` 编出，本脚本不跑 Gradle |
| `scripts/fetch-redroid10.py` 按 digest 解析、按 lock 校验 | `--check`，然后整层下载 | `--check` 退出码 0：lock 的 manifest digest `f41e76f3…` 直接解析到一份 image manifest，里面只有一层，digest 与字节数和 lock 一字不差。下载 701,673,445 B，sha256 与 lock 的 `47a4595f…` 一致，`downloads/manifest.json` 已写 |
| `scripts/extract-rootfs.py` 从 manifest 解包 | 在 `downloads/` 就绪后跑一次 | 4443 条：412 个目录、3458 个文件、573 个符号链接，1,572,657,491 B；`rootfs-index.json` 967,741 B，记着每条的 mode、uid、gid 与链接目标 |
| 解出的树与旧 prepared 逐条比对 | 共享路径逐文件 sha256 | 共享 2170 个文件，2165 个字节完全一致；`system/build.prop` 两边 sha256 都是 `12021d5a…`、2938 B |
| 差异清单可解释 | `_bin/a10/evidence/20261119-rootfs-vs-prepared.json` | prepared 比镜像多 21 个文件，是旧流水线注入的项目件（`a10vm-boot-check`、`a10vm-bridge.jar`、`a10vm-display.rc`、`a10vm-host-devices.xml`、5 个 `*.asset` 等）；5 个文件被改过（两个 `mediacodec.policy`、`services.jar`、两个 vintf manifest）；镜像比 prepared 多 1288 个文件，集中在 `system/lib64`、`system/apex`、`system/bin` |
| `container-probe/runtime/{dynamic,filesystem}` 迁入 | 49 个文件逐个比 sha256 与字节数 | 49 个文件全部相同，共 382,961 B，其中 C/C++ 25 个（`dynamic` 7、`filesystem` 18）。逐行清单在 `_bin/a10/evidence/20261119-s3-vendor-runtime-copy.csv` |
| 顶层 11 个脚本与清单落位 | 同一份清单的第 50 到 60 行 | 11 个文件全部相同，共 68,070 B；`archives.txt` 的四条 pin 与原件逐字一致 |
| 落位与 A9 同形 | 数 `guest-runtime-a9/vendor/runtime` 的文件数与差异 | A9 是 49 个，本仓库落位那一刻的 `vendor/runtime` 也是 49 个（后加 `companion` 24 个，今天 73 个）；A9 的 `dynamic` 25 个与本仓库逐字节相同，`filesystem` 有 2 个文件被 A9 按 API 28 改过。所以“原样复制”成立的是初始落位，接口级适配属于后面那一段 |
| 上游源码按钉住提交取回 | `python runtime/fetch-a10-sources.py --check` | 当时是 `entries=22 verified=996 missing=0 mismatched=0`，两份清单 `runtime/lists/sources.sha256` 与 `vendor/runtime/dynamic/sources.sha256` 逐文件比对；加 `companion` 之后是 25 条、1,562 个文件，见下面那一行 |
| 静态闭包从源码编出 | `sh runtime/build-static.sh` | 当时记的是 `runtime/build/lib/liba10vm-bootstrap.a` 571,604 B，组成就是 `runtime/lists/static-sources.txt` 那一份；现在同一份源编出 587,466 B，差额见 §3 |
| 运行时单一入口 | `sh runtime/build-a10-runtime.sh --plan-only` | 退出码 0，打印 module、解释器、上游、build 目录、四份输入是否存在、NDK、五步顺序与六件产物 |
| 构建链不再引用 app 仓库 | `grep -rn container-probe runtime/ scripts/` | 命中只在 `runtime/legacy/`（构建链不调用）；`scripts/` 为 0 |
| 私有 linker 从源码编出 | `sh runtime/build-linker.sh` 后看 `llvm-nm -u` 与 `llvm-readelf -d` | `runtime/build/bin/source-linker64` 813,696 B；未定义符号 0 条；SONAME `ld-android.so`；无 `DT_NEEDED`；导出 23 个符号 |
| 共享 libc 与 libdl 从源码编出 | `sh runtime/build-libc.sh` | `libc.so` 1,316,488 B，SONAME `libc.so`，`DT_NEEDED` 只有 `libdl.so` 与 `ld-android.so`，导出 1360 个符号；`libdl.so` 11,744 B，SONAME `libdl.so`，`DT_NEEDED` 只有 `ld-android.so` |
| libc 的未定义符号都能在运行时闭包里找到 | `llvm-nm -u libc.so` | 18 条，全部来自两个 `DT_NEEDED`：11 个 `__loader_*`、`dlopen`/`dlsym`/`dlclose`/`dlerror`/`dl_iterate_phdr`、`android_dlopen_ext`、`android_get_application_target_sdk_version` |
| 两份补丁真正生效 | 应用后查符号与源码 | `linker_main.cpp` 有 2 处 `A10VM_DEBUGGERD`；`bionic_systrace.cpp` 走 `async_safe_format_buffer`。之前 `git apply` 退出码 0 却一个字节不改 |
| `companion` 单元迁入 | 24 个文件逐个比 sha256 与字节数 | 24 个全部相同，共 111,357 B，其中 C/C++ 11 个；逐行清单在 `_bin/a10/evidence/20261119-s3-vendor-runtime-companion-copy.csv` |
| 配套库的上游源按同一份清单校验 | `python runtime/fetch-a10-sources.py` | `entries=25 fetched=0 blueprints=2 verified=1562 missing=0 mismatched=0`；这是三份 `sources.sha256` 的并集：A10 996 条、`dynamic` 与 `companion` 各自那份，后者 566 条 |
| 配套数学与展开库从源码编出 | `sh runtime/build-companion.sh` | `libm.so` 287,504 B、sha256 `1d48dd1f…`；`libunwind.so` 57,480 B、sha256 `267a6e67…` |
| 两个配套库的符号面与 prepared 那份一致 | `llvm-nm -D --defined-only` 与 `llvm-nm -u` 的集合比对 | 导出的具名符号集完全相同：`libm` 286 个、`libunwind` 37 个，两个方向差集都为空；未定义符号集同样相同，7 与 20 个；`DT_NEEDED` 分别是 `libc.so` 与 `libc.so, libdl.so`，与 prepared 一致 |
| 入口接上 NDK 与配套库这一步 | `sh runtime/build-a10-runtime.sh --plan-only` | 退出码 0；多打印一行 `ndk`，五步顺序里含 `build-companion`，产物多两行 `libm.so libunwind.so`；`A10_NDK` 写成 `C:\…` 时由 `cygpath` 转成 `/c/…` 再判存在 |
| 一条命令跑完五步 | `sh runtime/build-a10-runtime.sh` | 12:00 开始、12:18:44 结束，退出码 0；日志依次出现 `static bootstrap archive`、`private linker`、`libc and libdl`、`companion libraries`、`runtime build finished`；`source-linker64` 813,696 B，四个 .so 的哈希与上一轮完全相同 |
| 三次构建同一份字节 | 每轮都记录 `libc`、`libdl`、`libm`、`libunwind` 的 sha256 | 三轮都是 `ef057e1f…`、`6ba53377…`、`1d48dd1f…`、`267a6e67…` |
| binder 单元落位 | 58 个文件逐个比 sha256 与字节数 | 58 个全部相同，共 258,409 B，其中 C/C++ 37 个（`native` 22、`test` 15）；逐行清单在 `_bin/a10/evidence/20261119-s4-vendor-binder-copy.csv` |
| `RegistryMain.cpp` 落位 | 一个文件比 sha256 | 552 B，与 `guest-runtime/native/RegistryMain.cpp` 逐字节相同，清单在 `_bin/a10/evidence/20261119-s4-vendor-native-registry-main.csv` |
| 上游补到 frameworks/native | `python runtime/fetch-a10-sources.py` | `entries=30 verified=2033 missing=0 mismatched=0`；新增两条 pin（`libs/binder`、`libs/binderthreadstate`）与 unit 清单并入后 471 个文件 |
| `platform.patch` 真的落到派生件 | 补丁后 grep 标记符号 | 7 个文件全部 patched；`ProcessState.cpp` 有 `a10binder_default_driver`，`IPCThreadState.cpp` 有 `a10binder_ioctl` |
| binder 组的七个库与两个进程 | `sh bridges/build-binder-a10.sh` | 退出码 0：`liba10binder.so` 48,192 B、`libbinder.so` 745,616 B、`libutils.so` 165,728 B、`liblog.so` 123,960 B、`libbase.so` 103,680 B、`libcutils.so` 21,832 B、`libbinderthreadstate.so` 13,352 B、`binder-broker` 70,616 B、`binder-registry` 24,168 B |
| 符号面与 `prepared` 那份逐条对照 | `llvm-nm -D --defined-only` 与 `llvm-nm -u` 的集合比对 | `libbinder` 导出 1,476 个、未定义 193 个，两个方向差集都为空；`libutils` 434/80、`liblog` 125/108、`libbase` 142/122、`libcutils` 42/28、`libbinderthreadstate` 12/14，同样差集为空。唯一差异是 `libutils` 少一个未定义 `wcslen`，因为本仓库按 A10 的 bionic 头编译，它被解析到 libc |
| 桥的依赖落在本仓库的运行时上 | `llvm-readelf -d` 的 NEEDED | `libbinder.so` 的 NEEDED 是 `liba10binder/libutils/libcutils/libbase/liblog/libbinderthreadstate/libc++.so/libm.so/libunwind.so/libc.so/libdl.so`；C++ 那份来自 `rootfs/system/lib64/libc++.so`，其余五件来自 `runtime/build/lib` |
| 解包只有一条命令 | `grep -n "tarfile\|extract_pieces" runtime/fetch-a10-sources.py` | 0 命中；`extract()` 只有 `subprocess.run(["tar", "-mxzf", ...])` |
| 取源能重解一棵子树 | 删掉 `frameworks/native/libs/binderthreadstate` 后重跑 | `entries=30 fetched=1`，解出 3 个文件，`verified=2033 missing=0 mismatched=0` |
| 源清单只声明一次 | `grep -c "frameworks/native" runtime/lists/archives.txt` | 0；binder 的源只由 `vendor/binder/archives.txt` 决定 |
| 上游树形状 | `Get-ChildItem runtime/upstream -Directory` | 七项：`bionic`、`build`、`device`、`external`、`frameworks`、`hardware`、`system`；后两项是图形组在 2026-11-19 加的（goldfish-opengl 在 `device/generic/` 下，HAL 头在 `hardware/libhardware`），删掉的 53 个平铺副本逐个证明过是 `system/core` 子目录的重复 |
| 删掉重复上游后仍能编 | 删 53 个目录后重建 binder 组 | 退出码 0，九个产物与删除前逐件同哈希 |
| `frameworks/native/include` 要不要 | 头文件解析取证，`_bin/a10/evidence/20261119-a10-binder-include-resolution.txt` | 配方 `log=17 base=12 utils=20 binderthreadstate=1 binder=21 cutils=7`；未解析的 6 条全部在平台分支里或由 clang 自带；`vndksupport/linker.h` 被 `platform.patch` 的 `!defined(A10VM_PRIVATE_RUNTIME)` 守卫关掉，判据是派生件第 26 行与 `.o.d` 里 grep 不到 `vndk` |
| 产物身份 | 三轮各记一次 sha256，第三轮是删掉 `bridges/{lib,bin,obj,generated,derived}` 之后重跑 | `libbinder.so` `1dd0b8dd…`、`liba10binder.so` `7bbd6b0b…`、`binder-broker` `0549b768…`、`binder-registry` `70f9cdcc…`，三轮一致；逐件清单在 `_bin/a10/evidence/20261119-s4-binder-build.json` |
| 图形源落位 | 101 个文件逐个比 sha256 与字节数 | 101 个全部相同，共 370,831 B；逐行清单在 `_bin/a10/evidence/20261119-s4-vendor-graphics-copy.csv` |
| 图形上游按钉住的提交取回 | `python runtime/fetch-a10-sources.py` | `entries=41 fetched=11 verified=2033 missing=0 mismatched=0`；11 个归档是 goldfish 三条、qemu 两条、`frameworks/native` 五条、`hardware/libhardware` 一条 |
| 符号链接残桩补成字节 | 取源之后数残桩 | `links repaired=46 unresolved=45`；2033 个受校验文件仍全部一致，`sync/sync.h` 能读出来 |
| 图形组的六个库 | `sh bridges/build-graphics-a10.sh` | 退出码 0：`libOpenglSystemCommon.so` 863,064、`libGLESv2_emulation.so` 153,272、`hwcomposer.ranchu.so` 126,816、`libEGL_emulation.so` 113,536、`libGLESv1_CM_emulation.so` 103,160、`gralloc.ranchu.so` 32,216 |
| codec id 与宿主渲染器一致 | 与 `prepared` 的 `liba10vm-desktop-gpu-host.so` 内嵌的 64 位串比对 | 两边都是 `0c8b4b134d59c2429b5d043a9d8a3833f043534a437201ac538121a3b199b433`；账号里那串来自十一行 sha256 文本的汇总，公式与 `build-desktop.sh` 逐字相同 |
| 图形的入口面与 `prepared` 对齐 | `llvm-nm -D --defined-only` 与 `llvm-nm -u` 的集合比对 | 六个库对同名副本缺的导出符号都是 0；只有 `libOpenglSystemCommon` 多两个（`a10pixels::rgbToYuvRow`、`yuvToRgbRow`，本项目补的 YUV 转换）；未定义集合六个都完全相同 |
| 图形的依赖闸门 | `llvm-readelf -d` 的 NEEDED 与允许清单 | 只落在 `bridges/lib/registry` 的三份、`runtime/build/lib` 的四件与镜像的 `libc++.so`、`libnativewindow.so`、`libhardware.so`、`libsync.so`；没有 NDK 的库 |
| 图形两轮同哈希 | 连跑两次 `bridges/build-graphics-a10.sh` | 六个产物逐件同值，逐件清单在 `_bin/a10/evidence/20261119-s4-graphics-build.json` |
| 属性服务组三件 | `sh bridges/build-properties-a10.sh` | `property-service` 64,808、`seed-properties` 62,456、`liba10vm-property-client.so` 7,240；逐个 `sh -n` 与整链退出码都是 0 |
| 属性服务的依赖与符号面 | `llvm-readelf -d`、`llvm-nm -D --defined-only`、`llvm-nm -u` | `property-service` 的 NEEDED 与 `prepared` 那份逐项相同（`libc++/libunwind/libc/libm/libdl/ld-android`），未定义符号 93 条两个方向差集都是 0；`liba10vm-property-client` 的 NEEDED 只有 `libc.so`，未定义 13 条差集 0；`seed-properties` 见 §3 与 §7 的静态动态差异 |
| 设备与日志组五件 | `sh bridges/build-devices-a10.sh` | `liba10vm-guest-devices.so` 29,784、`liba10vm-binder-devices.so` 12,384、`liba10vm-guest-log.so` 7,648、`liba10vm-hal-modules.so` 7,408、`liba10vm-manager-policy.so` 6,568 |
| 设备组五件的导出面 | 对 `prepared` 的 `liba10vm-guest-liba10vm-*.so` 逐件比集合 | 五件缺的导出符号都是 0；`manager-policy` 与 `guest-log` 的未定义集合也完全相同 |
| 两个新组删产物重建 | `Remove-Item bridges/properties,bridges/devices` 后重跑两条桥 | 八个产物逐件同哈希，与第一次构建一致 |
| 客体源的复制清单 | 逐文件比 sha256 与字节数 | 属性四件在 `…-vendor-native-properties-copy.csv`，设备八件在 `…-vendor-native-devices-copy.csv`，媒体六件在 `…-vendor-native-media-copy.csv`，全部 `same` |
| 媒体与网络两件 | `sh bridges/build-media-a10.sh` | `libnetd_client.so` 21,920、`audio.primary.a10vm.so` 26,304；对 `prepared` 同名副本缺的导出为 0；NEEDED 只落在运行时闭包 |
| 宿主生成器 `hidl-gen` 与 `aidl` | `sh runtime/build-media-tools.sh`（在 WSL 的 Ubuntu 22.04 里跑） | `hidl-gen` 编出并生成 28 个 HIDL 包的头；AIDL 用 SDK `build-tools/30.0.3/aidl --lang=cpp` 生成 9 个接口；接口头合计 351 个文件 |
| 媒体七件 | 同一条 `bridges/build-media-a10.sh` | `libmediaplayerservice.so` 1,187,880、`libstagefright_httplive.so` 507,880、`libresourcemanagerservice.so` 75,344、`drm` 237,176、`media-drm` 27,248、`media-omx` 15,608、`media` 9,120 |
| 媒体七件的符号面 | 对 `prepared` 同名副本比集合 | 七件缺的导出都是 0，**未定义符号集合也完全相同（差集 0）**；NEEDED 数分别是 26／15／7／7／8／6／9 |
| 媒体七件的链接依赖 | `python runtime/media-deps.py` | 从 rootfs 与镜像 APEX 抽出 120 个 ARM64 依赖，`missing=0`；`libc/libdl/libm/libunwind` 明确走本仓库的运行时闭包 |
| 媒体组的上游头 | `vendor/media/archives.txt` 两条 pin 后取源 | `system/media` 的 `audio/include`（`fdc88efc…`）、`system/netd` 的 `include`（`e27bf9ed…`）；`entries=43 fetched=2 verified=2033 missing=0 mismatched=0` |
| S5 第一段：项目件落位 | `python scripts/prepare-a10.py` | `staged=31 missing=9 host=2`，31 + 9 + 2 = 42；`prepared.staging/jniLibs/arm64-v8a` 31 个文件，清单 `prepared.staging/project-manifest.json` |
| dex 单元自产 | `sh bridges/build-dex-a10.sh` | `bridges/dex/lib/libdexfile.so` 304,424 B、`6a854559…`；连跑两次同值 |
| dex 的符号面 | 对 `prepared` 的 `liba10vm-guest-libdexfile.so`（296,272 B）比集合 | 缺的导出为 0，多出 8，未定义差集 7；NEEDED 是 `libartbase/libartpalette/libbase/liblog/libcrypto/libc++/libm/libdl/libc`，全部来自镜像与本仓库运行时 |
| 落位的身份对得上 | 抽查三条的 `name` 与 `guestPath` | `libGLESv2_emulation.so` → `liba10vm-guest-libGLESv2_emulation.so`、`/vendor/lib64/egl/libGLESv2_emulation.so`；`gralloc.ranchu.so` → `/vendor/lib64/hw/gralloc.ranchu.so`；`registry/libc++.so` 的 `source` 是 `redroid10` |

本轮修掉的两个自己的问题，一并记下来：

1. `prepare_kind=参考 APK` 没加引号，shell 把 `APK` 当成命令执行。判据是那个用例曾经退出码 127 并打印
   `APK: command not found`；加引号后同一用例退出码 0。这条是参数组合测试抓到的，不是读代码看出来的。
2. `--plan-only` 需要 `rom.properties.yaml` 的 id 与版本，原本这两行写在 prepared 之后。为让计划输出与
   实际执行用同一份变量，把身份与输出路径的计算移到工具检查之后，并在读不到文件时打印“未读到”，不编默认值。

## 3. 未验证

| 项 | 状态 | 为什么没验、下一步用哪一行验 |
| --- | --- | --- |
| 属性区补丁在真机上生效，框架入口已过 | `files/devices/1795079181903/vm/framework-server.log` 出现 `desktop_guest_sdk=29`；同一实例 `server` 进程的 `maps` 里 `boot-properties` 出现 6 次、`/dev/__properties__` 0 次 | 2026-11-19 19:01 实测，pid 27953；`A10VM_PROPERTIES` 指向 `vm/boot-properties`。2026-11-19 19:03 已可启动；19:16 重装后新实例 `1795085438495` 再次 `desktop_guest_sdk=29`，`startup-events.log` 58.75 s 打出 `READY client: desktop_services_ready=1` |
| APK 导入 | 用户已确认新版 app 导入恢复 | 设备后续日志也显示 create `[103861457]`、write `Success: streamed 2616411 bytes`、commit `Success`，三个命令均 `guest_command_result=0`；本轮停止要求重复测试，焦点转回 ROM HWC |
| Guest log 镜像批写 | 已实现于共享 app runtime；用户确认新版 app 已构建 | SDK 29 每条 guest 日志按最多 3,000 UTF-8 字节合批，纯 Java 测试和模块编译通过。该项不作为本轮局部图层冻结的根因或修复结论，不再要求用户重复验证 app 链 |
| HWC 缺 goldfish_sync 的 host-wait fallback | 已在 `android10@1.0.1` 实机验证无效，图层抽搐仍存在 | 新实例 `1795154236450` 实际加载的 HWC SHA 为 `eeb34ac2…`，与测试 ROM 内相同；但仍有 8 条 `No local sync point found`、Skipped 41/104/35/111/110 frames、`Slow delivery 3217ms`，导航栏 `Screen frozen +620ms`。logcat 无 host fence wait failure。不得再把该改动称作修复；host-wait 只是已证伪的单变量实验，下一轮须检查 A10 SF/HWC present/release fence 的 buffer 生命周期及 app 渲染循环 |
| 整链构建（prepared → zip → prepared-apk） | 已验证过一次（2026-11-19） | 那次跑通了三个阶段，但入口当时被空的 `runtime-inputs/guest-runtime` 抢走来源，抽 prepared 前先把旧 `prepared` 删了。现在来源判定改成看清单文件，且先写 `prepared.staging` 校验通过再换。重跑判据仍是 `build finished` 三行路径与 `--verify-only` 退出码 |
| `--plan-only` 在 Linux 上的行为 | 未验证 | 本机只有 Git 自带的 `sh`，与 ubuntu-24.04 的 dash 有差异；CI 补上之后由 CI 验 |
| 局部图层停更根因 | 仍未解决；host-wait ROM 已证伪 | 新实例 `1795154236450`，ROM 1.0.1，设备载入 HWC SHA `eeb34ac2…`。compositor 8 条 sync warning；server 有 Choreographer skip 41/104/35/111/110 帧、最大 slow delivery 3,217 ms、NavigationBar0 frozen 620 ms；无 HWC wait failure。上述同时存在但不能据此假定同一根因。下一步按同一时段采集 SF/HWC/producer queue+latch+release 序列并检查状态栏对应 layer 的 buffer frame number |
| `--skip-extract` 与 `--skip-rom` 的真实执行 | 未验证 | 只在 plan-only 里验了跳过分支的打印；真实执行属于 S5 之后 |
| 符号链接与硬链接没有落盘 | 未验证，设计如此 | 索引记着 573 个符号链接的目标，S5 的 stager 按索引还原。要在真机上判，看实例里 `LIB`、`EXEC` 行与文件 mode |
| `build-a10.sh` 没有调用 fetch 与 extract | 未接线 | 两条来源并存到 S5；接线方式写在 `BUILD.md` §1.1 |
| 两个新脚本在 Linux 上的行为 | 未验证 | 都是纯 stdlib、没有外部命令；CI 补上之后由 CI 验 |
| 这五个自建产物没有在真机上跑过 | 未验证 | 它们只过了静态判据（符号、SONAME、`DT_NEEDED`）。要判"能不能起客体"，得先进 `prepared`、再出包、再装机，属于 S5 与 S6 |
| 运行时没有接入 `prepared` | 未接线 | `scripts/prepare-a10.py` 还不存在，`prepared` 由参考 APK 抽出来。五件产物今天只是编出来了，没有任何客体内容用到它们 |
| 新闭包与装机那一份不是同一批字节 | 已知，未验证影响 | 同一台机器、同一份源码，2026-11-19 编出的 `libc.so` 1,316,488 B 与装机那份 1,308,880 B 不同，原因是链接器版本不同：装机那份的 `.comment` 写 `LLD 21.1.8`，本机 NDK 是 `LLD 21.0.0`；导出符号集与未定义符号集一致。字节不可能相等，所以 S5 的判据只能是装机后的 `VERIFY`、`DATA`、`READY`，不能是哈希相等 |
| `liba10vm-bootstrap.a` 两次编出的字节数不同 | 未取证，数字本身也可疑 | 之前记 571,620 B，这次整链重跑是 587,466 B，差 15,846 B。四个闭包成员的目标文件合计 15,032 B，加 `ar` 的成员头与符号索引，量级对得上；但 05 号文档 §4.2 又写着"清单原样"那一版是 571,604 B，比 571,620 少 16 B，等于四个目标文件只值 16 B，自相矛盾。所以这两份记录里至少有一份是过时的，成员清单还没逐条比对。它只进 linker 的链接，不影响导出符号，但可复现这一条要等成员清单比对完才能说成立 |
| `fetch-a10-sources.py` 对子树为 `.` 的条目判重有问题 | 已修（2026-11-19） | 判断"目录已存在就跳过"时，`.` 的目标正是仓库根，而根已经由更细的子树建出来，于是整棵归档被跳过，`bionic/libm` 因此缺过。修法是取源前把整棵归档排到最前，判据是脚本里那一行排序注释与 `entries=30` 的跑通记录 |
| `runtime/upstream` 里的符号链接在 Windows 上是残桩 | 已收口（2026-11-19） | `fetch-a10-sources.py` 取完源跑 `materialize_links`，按链接目标把残桩补成同样的字节，所以 `sync/sync.h` 这类头能读出来。第一轮 `repaired=46 unresolved=45`，第二轮 `0/0`；2,033 个受校验文件仍然全部一致。链接目标落在树外的保持原样 |
| binder 组的产物没有进 `prepared` | 未接线 | 它们在 `bridges/{lib/registry,bin}`，`prepared` 里同名条目仍来自参考 APK。S5 接上之后判据是清单里出现 `aosp10` 与 `project-a10` 来源 |
| `liba10binder` 的 `ClientBuffers::receive` 签名与 `prepared` 那份不同 | 已知，未判影响 | 本仓库编出的是 `receive(Packet*, binder_transaction_data*, size_t*)`，`prepared` 里少最后那个参数，说明那份二进制早于当前源码。S5 把新产物接进 `prepared` 时，调用方要跟着一起换，判据是 `libbinder` 的未定义符号里不出现旧签名 |
| `binder-broker` 与 `binder-registry` 没有跑过 | 未验证 | 只过了静态判据（`llvm-readelf -d` 与 `llvm-nm -u`）。要判能不能起，得先进 `prepared`、再出包、再装机，属于 S5 与 S6 |
| 图形组的六个库没有跑过 | 未验证 | 只过了静态判据（导出、未定义、NEEDED、codec id）。能不能出画面得先进 `prepared`、再出包、再装机 |
| 图形上游没有逐文件清单 | 未验证 | 这一组今天只有提交钉住（`vendor/graphics/archives.txt`）与 codec id 这一条间接判据，没有 `vendor/graphics/sources.sha256`。补法是 S4 收尾用 `runtime/record-sources.py` 从编译依赖 `.d` 记一份 |
| emugen 的 26 个产物是提交的不是生成的 | 已知，判据间接 | emugen 要宿主的 C++ 链接器，本机只有 NDK 的 clang++（没有 MSVC 头与库）。间接判据两条：上游八份定义文件与 A15 提交的那份逐字节相同；codec id 与 `prepared` 里宿主渲染器内嵌的那个相同 |
| `seed-properties` 改成了动态链接 libc++ | 已知，改动有据 | 旧流水线把 NDK 的 `libc++_static.a` 静态链进去，产 674,536 B、NEEDED 只有 `libdl/libm/libc`；本仓库按其余产物的规矩链镜像的 `libc++`，产 62,456 B，NEEDED 多 `libc++.so`、`libunwind.so`、`ld-android.so`。判据只能是装机：seed 跑起来时这几件必须已经在实例的库搜索路径里 |
| `liba10vm-guest-devices.so` 比 `prepared` 那份多 19 个导出、14 个未定义差异 | 已知，未判影响 | 缺的导出是 0，所以宿主按名字找的符号都在；多出来的与差异说明 `prepared` 里那份二进制早于当前源码，与 `liba10binder` 的 `ClientBuffers::receive` 同类。S5 换进 `prepared` 时宿主侧调用方要一起换 |
| 媒体七件要在 Linux 上生成接口头 | 已解决，路径固定 | 七件要 `hidl-gen` 与 `aidl` 的头，两支生成器要宿主 `bison`/`flex`。本机已装 WSL 的 Ubuntu-a10（`wsl --import` 导入 ubuntu-base 22.04），`apt install bison flex build-essential libssl-dev clang` 之后 `sh runtime/build-media-tools.sh` 一次跑通；接口头是纯文本，后面的交叉编译仍在 Windows 上做 |
| `image/a10vm-init` 没有产出者 | 已定位，要新建单元 | `grep -rn a10vm-init guest-runtime container-probe tools` 只命中 `GuestPaths.cpp:39` 的路径特判。它是一支**静态 `EXEC`**：`llvm-readelf -h` 报 `Type: EXEC`，`llvm-readelf -d` 没有动态段，`llvm-nm -D` 只有一个定义符号，字节 2,182,048。所以它不是"把镜像的 init 改个名"，要从 AOSP 10 的 `system/core/init` 新建一条静态构建链 |
| S5 的镜像那一半没有 staging 规则 | 未开始 | 1,016 件改名搬运、2,209 条 data、574 条符号链接、78 个系统 APK、172 条属性都还没有从 `rootfs/` 选出来的规则；dex 也还不能自产 |


## 4. 已回滚

无对外交付的回滚。有一处同轮自我更正：给 `runtime/lists/archives.txt` 加过一行 `external/libcxx … src`，
随后查到 `vendor/runtime/dynamic/archives.txt` 第 8 行已经覆盖同一个三元组，当轮删回原样，文件仍是 11 行。

## 5. 当前卡点

以下保留 2026-11-19 已关闭的启动卡点。APK 导入已由维护者确认修复；当前唯一主线是 A10 ROM 的 status/navigation layer 在高频更新后停住。ROM 1.0.1 的 HWC fallback 已在实体机确认无效；下一动作只读 SF/HWC/BufferQueue 时间线，满足判据前不再构建。

1. 框架入口 `Wrong guest SDK` 已关闭。真因是这一版 libc 编译时用的属性派生树没带 `runtime.patch`，
   `__system_properties_init` 读的是宿主的 `/dev/__properties__`。重编后真机 `desktop_guest_sdk=29`，
   同实例 `server` 进程 `maps` 里 `boot-properties` 6 次、`/dev/__properties__` 0 次（pid 27953，19:01）。
   同轮还暴露并修掉一个我自己造成的回归：重跑整条运行时把 linker 重链成 806,696 B，清单仍是 813,696 B，
   装机后报“字节与清单不符”。已从归档包恢复 800,280 B（`ffd1f89c…`），并在出包后加了 zip 内部逐条核对。
   进程 pid 28746 的 `environ` 里 `A10VM_PROPERTIES` 指向 `vm/boot-properties`，值是对的；
   同一份 `maps` 里属性区却是 `/dev/__properties__/*`（设备号 `00:10`，宿主 tmpfs），
   私有目录一个文件都没被映射过。原因是这一版 libc 编译时用的派生树没有带上 `runtime.patch`：
   三个域取同一个对象 `bionic_libc_bionic_system_property_api.cpp.o`，A9 与 A15 里有
   `A10VM_PROPERTIES` 没有 `/dev/__properties__`，A10 里正好相反。
   于是 `ro.build.version.sdk` 读到宿主的值，`DesktopBoot:8` 拿它和 29 比就炸。
   旧说法“框架件与 odex 不配套”已证伪，`services.jar` 那条校验和是旧流水线改过 jar 的独立症状。
2. `seed-properties` 的 `libunwind.so` 已经修掉：静态链后 5,693,880 B，真机 `seed_complete=1`；
   ART 也到了 `art_runtime_ready=1`，服务进程全部起来。
3. `image/a10vm-init` 仍按字节钉在 `prebuilt/arm64/`；两个 check dex 仍从参考 prepared 取，
   `bootstrap/` 四个入口类还没有接进 dex 与 `runtimeProfile`。这三条都是已知限制，不是已修。

已交付的 39 件源码产物没有卡点：导出面对 `prepared` 那份缺零个，媒体七件的未定义符号集合与那份完全相同，
图形的 codec id 与宿主渲染器内嵌的那个逐字相同。

环境侧的两条事实记在这里，免得下一个人重踩：WSL 的两个可选特性原本是 `Disabled`，
用 `dism /online /enable-feature /all /norestart` 打开后（退出码 3010）重启才生效；
`wsl --install -d Ubuntu` 的 `已禁止(403)` 来自商店下载链路，绕法是 `wsl --import` 导入
ubuntu-base 的 tar.gz（已放在 `D:\my123\_a10-tools\`）。另外这台机器的 DNS 会把
`archive.ubuntu.com` 解析到 `28.0.0.163`（不可达），WSL 里的 `sources.list` 已换成可用的国内镜像。

## 6. 当前图形排查交接（2026-11-20，HWC 1.0.1 fallback 已证伪）

APK 导入已由维护者确认 Android Studio 新版 app 修复；ROM `android10@1.0.1` 实例 `1795154236450` 的 create/write/commit 也成功，session `[638585845]`、stream 2,616,411 B，三个命令 `guest_command_result=0`。该问题关闭，不再要求重测导入。

HWC fallback 已实测无效。设备 `rootfs/vendor/lib64/hw/hwcomposer.ranchu.so` 是链接至 `vm/libs/liba10vm-guest-hwcomposer.ranchu.so` 的 symlink，目标 SHA `eeb34ac29c68ef3f551f4ec515671ef984ef5c798b57a6bf307e721ad55935f1`，与测试 ROM 完全一致。故失败不是旧 ROM、APK 缓存或测试路径错。

同一新版实例的日志：compositor 179 行、8 条 `No local sync point found`（Gallery/Launcher/Settings layer）；server 11,900 行、5 次 Choreographer skipped（41、104、35、111、110 帧）、3 次 slow delivery（最大 3,217 ms）、5 次 slow dispatch、`NavigationBar0` screen frozen 620 ms。没有 `host GPU fence wait failed`；host wait fallback 已返回，但画面现象没有消失。

ROM 1.0.1 当前作为**无效实验**保留。下一步先取同一刷新卡停窗口的 SurfaceFlinger/HWC/BufferQueue 时间线，逐层对齐 frame number、queue/latch/release fence 与 SystemUI producer；识别 buffer 不推进属于 producer、latch、release 还是 framework 主线程。没有这一条判据之前不再加 fence guard、不再构建、不再安装 ROM。

以下紧接的 S5 首包/材料清单是 2026-11-19 的历史记录，保留其当时边界；不是当前卡点，也不要求重做已经通过的 seed/ART 闸门。当前唯一未关闭项和下一步判据见本节开头的 2026-11-20 图形交接，以及 `docs/android10-port/11-进展日志.md` 14:00 实测记录。


## 7. 已知限制

| 限制 | 边界 | 替换条件 |
| --- | --- | --- |
| prepared 来自参考 APK | 内容可信，来源不可复现；APK 丢了就重建不出来 | S5 把 `--from-rootfs` 变成默认 |
| 五个自建产物没有进过 `prepared` | 它们在 `runtime/build/`，清单里一条都没引用；`prepared` 仍是参考 APK 抽出来的那份 | S5 的 `prepare-a10.py` 逐条接上，判据是清单里出现 `aosp10` 来源的条目 |
| `libc++` 取自镜像 | 841,888 B，与 `system/lib64/libc++.so` 逐字节相同；837 个客体库按它链接 | 换镜像时随镜像走，不自建。自建会出现第二份 libc++，与 `_LIBCPP_VERSION` 和 ABI 一起漂移 |
| 清单是旧 schema | 缺 `frameworkSdk`、`runtimeProfile`、`apexAliases` 等 16 个字段，共享层靠默认值工作 | S5 |
| A10 的 ART 来自调试 APEX | 靠共享启动层 `apexAliases` 挂到 `/apex/com.android.runtime`。镜像里 `system/apex/<name>/` 已经是展开的目录，没有 `.apex` 压缩包，所以这条链不需要 A15 那样的展开步骤 | 换镜像或换 APEX 布局时先确认这条链 |
| prepared 与镜像之间的 26 处差异没有自动化 | 21 个新增与 5 个改动来自旧流水线，逐条清单在 `_bin/a10/evidence/20261119-rootfs-vs-prepared.json` | S5 的 `prepare-a10.py` 必须逐条重现这 26 处，否则装机后行为会变 |
| 入口不自动跳过已完成阶段 | 需要显式 `--skip-extract`、`--skip-rom` | S5 的 `prepare-a10.py` 落地后按产物存在性跳过 |
| 仓库根有一份 `guest-runtime-a10.zip` | 78,338 B，源码快照，不含任何产物 | 由维护者决定是否删除 |
| `runtime/upstream` 的符号链接是 0 字节残桩 | Windows 上建链接要权限，tar 遇链接即失败退出（`system/core` 抽出 2017 个文件、归档 2411 条）。残桩不在 `sources.sha256` 里，1,562 个受校验文件全部一致；换平台要重抽一次 | 换到 Linux 或开开发者模式后重跑 `fetch-a10-sources.py` |
| 解包只有一条命令，与 A9/A15 相同 | 已收口（2026-11-19） | `extract()` 只剩 `tar -mxzf <archive> -C <dest>`，Python 只负责下载与逐文件校验；之前那套 Python `tarfile` 加 Windows 分支已删掉，`.part` 中转目录也不再产生 |
| `runtime/upstream` 顶层只许出现仓库根 | 已收口（2026-11-19） | 删掉 53 个平铺的 `system/core` 子目录副本后，顶层是 `bionic`、`build`、`external`、`frameworks`、`system` 五项；删后重建 binder 组九个产物逐件同哈希。缺的自检见 `_audit/coding-log/2026-11-19-重大事故-A10解包器自创与清单重复` 第 08 篇 |
| `bridges/` 只有 binder 组 | 客体侧的属性服务、设备、图形三组一件都没有；启动链要的 `liba10vm-guest-devices` 与图形库今天还拿不到 | S4 剩下三组，从 `container-probe/graphics` 起 |
| `bridges/` 的产物目录不入库 | `bridges/{lib,bin,obj,generated,derived}` 在 `.gitignore` 里，与 A15 同一分界：产物靠 `bridges/build-*.sh` 现编 | 交付前删掉 `bridges/` 的产物目录重跑一次，产物哈希应当不变 |
| 图形上游没有逐文件清单 | 只有提交钉住与 codec id 这条间接判据 | S4 收尾用 `runtime/record-sources.py` 从 `.d` 记一份 `vendor/graphics/sources.sha256` |
| 图形的 emugen 产物是提交的 | `vendor/graphics/generated` 26 个文件，来自 A15 仓库，判据是定义文件逐字节相同且 codec id 一致 | 换 qemu 或 goldfish 的提交时，这 26 个文件要跟着换，判据仍是 codec id |
| 图形库比 `prepared` 那份小几十到几百字节 | 链接器版本不同（装机那份 `LLD 21.1.8`，本机 21.0.0）；导出与未定义集合相同 | 不接受字节相等的判据；换成装机后的画面 |

那份 zip 的登记：`sha256=3F707841D25B7450BC3E77CAAF05E6F33E6F7EDCF7A3ECA349C3F18020707E2D`。
它里面 11 个非 `.pyc` 条目与工作树逐字节相同，只有 `scripts/build-a10.sh` 是加解释器探测之前的版本，
另有四个 `__pycache__` 条目。它不能当产物，也不能当输入，解压覆盖工作树会退回旧脚本。

## 8. 不要重试

| 路径 | 为什么 |
| --- | --- |
| 把参考 APK 当成长期输入 | 不可复现，S5 之后只作对照 |
| 在 A10 仓库引用 A9/A15 的脚本 | 三个仓库各自 clone，跨引用会让“只 clone A10”打不出包 |
| 改 app 仓库的 `guest-runtime/` 来迁就 A10 | 共享启动层同时服务 A9、A10、A15 |
| 手改清单或手塞 `dist/` | 哈希自证会失败，也无法追溯 |
| 用 `--min-api` 当 API 29 可用性证明 | 它只管字节码级别，不管方法在不在 |
| 用 `git apply` 打 `vendor/runtime/dynamic/platform.patch` 或 `runtime/platform.patch` | 两份补丁的 hunk 头行数与正文对不上：`git apply` 退出码 0 却一个字节不改，看起来像成功。只能用 GNU `patch -p1 -t`，判据是 `linker_main.cpp` 里有 2 处 `A10VM_DEBUGGERD` |
| 跑 `runtime/legacy/` 里的旧脚本 | 它们是旧流水线的记录，`SRC` 指向 app 仓库的 `container-probe/`，在本机静默生效、在第三方机器上失败 |
| 给 registry 那一组自建 `libc++` | 旧流水线有一份 1,334,384 B 的自建 `libc++.so`，本仓库改用镜像那份（841,888 B）。自建会多出第二份 libc++，与 `_LIBCPP_VERSION` 一起漂移；镜像里 837 个客体库都按它链接 |
| 用 `git apply` 打 `vendor/binder/platform.patch` | 与运行时那两份补丁同类的坑：hunk 头与正文对不上时 `git apply` 退出码 0 却一个字节不改。用 `patch -p1 -t`，判据是 `ProcessState.cpp` 里有 `a10binder_default_driver` |
| 用不带 `-t` 的 `sha256sum` 算 codec id | Git for Windows 默认二进制模式，输出 `<hash> *<name>`，十一行文本汇总之后得到的是另一个 id，客体与宿主互相拒绝，表现为没有画面而不是编译失败。判据是 id 等于 `0c8b4b13…` |
| 给客体图形加 `-I"$Q/guest"` | 那一份 `hardware/gralloc.h` 是 Q 之前的版本，没有 `validateBufferSize` 与 `getTransportSize`，会把 AOSP 10 的头盖掉。这个参数只属宿主渲染器 |
| 在 Windows 上指望 tar 把符号链接建出来 | AOSP 的 `system/core/libsync/include/sync/sync.h` 是链接，tar 只留读不出来的残桩。取源之后由 `materialize_links` 补字节，别手工去改 `runtime/upstream` |
| 按反汇编重写 `image/a10vm-init` | 没有源码，重写等于重做开机路径；已按 §4.4 钉在 `prebuilt/arm64/a10vm-init`，替换条件在 `prebuilt/README.md` |
| 编 `SdkProbe.dex` 之类的探针推设备 | 违反 `_audit/README` 硬规则第 8 条与 00 §4.1；这一轮连 dalvik-cache 权限都没过，只增加失败面 |
| 用 `adb exec-out > 文件` 拉二进制再算哈希 | PowerShell 会按文本重定向，文件头出现 UTF-16 BOM、长度和内容都变；二进制哈希只在设备上 `sha256sum` |
| 给 `GuestPaths.cpp` 加属性区豁免 | 这是 S3 逐字节核对过的文件；stateRoot 覆盖 properties 路径这一点当时已论证过，改动没有证据。已按字节回滚，sha256 8e7d02db… |
| 在没有新日志时重编 `libc` | 全量 libc 十几分钟，而且这一轮的依据是被自己排除的假设；中断后哈希仍是 ef057e1f…，没有产生新信息 |
| 整条 `runtime/build-a10-runtime.sh` 重跑 | 它会把 `source-linker64` 一起重链，字节从 813,696 变成 806,696，而清单身份没跟着变，包一装就是“字节与清单不符”。只重编真正变了的那一件，其余用已验产物 |
| 出包后不看 zip 内部自洽 | `pack-rom` 自己那套校验不覆盖我手工换过的产物。判据是 `_bin/a10/scratch/verify-rom-manifest.py`：1058 条逐条比字节，0 mismatch 才允许装机 |

## 9. 产物身份

| 文件 | 字节 | sha256 |
| --- | --- | --- |
| `scripts/build-a10.sh` | 7,217 | `b575aec207107ed748f094ea8d96a8847d6ebee351d3b8d4f4abee8e6770efe3` |
| `scripts/fetch-redroid10.py` | 13,016 | `adb2e5ea9f051dd6877b4b8c85eba74e077ed84396dd7c2b1dd26a462fe695d8` |
| `scripts/extract-rootfs.py` | 8,525 | `a42814dc697287e8ac5dd2d406177bd386ac86ae5608e642be9a5a9a9ffc216c` |
| `sources.lock.json`（从 `guest-runtime/` 复制） | 645 | `39f1556ea5f8ede941b4bf347595c654559401070d5ad1bbb527374a1d264630` |
| `downloads/redroid10-layer0-47a4595f.tar.gz` | 701,673,445 | `47a4595f19ded855ae0b0045c8926b838576de4ceb4297ca881461fd809b2a81` |
| `rootfs/` | 4443 个条目，1,572,657,491 B | 逐条在 `rootfs-index.json` |
| `rootfs-index.json` | 967,741 | `d018a3ee01d273c80c4722d58296b906df12671673b8a77f1132ebccc291dff2` |
| `prepared/jniLibs/arm64-v8a` | 1,058 个文件，462,098,880 B | 逐条哈希在 `prepared/assets/guest-runtime-inputs.json` |
| `dist/versebox-android10-1.0.0.zip` | 665,625,441 | `db546331be3bddffafc809e7c6bb08d9c8ec80220fc74c5ee054093a269bd38a` |
| `vendor/runtime/` | 73 个文件，494,318 B（`dynamic` 25、`filesystem` 24、`companion` 24） | 前两个单元的逐文件哈希在 `_bin/a10/evidence/20261119-s3-vendor-runtime-copy.csv`，`companion` 在 `…-companion-copy.csv` |
| `runtime/build/bin/source-linker64` | 813,696 | `llvm-nm -u` 空，SONAME `ld-android.so` |
| `runtime/build/lib/libc.so` | 1,316,488 | `ef057e1fd0000973678b13e851a1397ea0300aa3fef53a6db80bb811c6df83d3` |
| `runtime/build/lib/libdl.so` | 11,744 | `6ba53377b4de2822d5d980cf896889093891e1299228000957b46fc8e5f79fd5` |
| `runtime/build/lib/liba10vm-bootstrap.a` | 571,620 | 由 `runtime/lists/static-sources.txt` 加四个链接必需的闭包成员。2026-11-19 整链重跑后同一份源编出 587,466 B，比这份大 15,846 B，原因未取证，见 §3 最后一行 |
| `runtime/build/lib/libm.so` | 287,504 | `1d48dd1f94cf0262da6ae3dd6eb8eb63a962b251be57def5c99db5f383258408`；SONAME `libm.so`，`DT_NEEDED` 只有 `libc.so`，导出 293 个符号 |
| `runtime/build/lib/libunwind.so` | 57,480 | `267a6e67ff4392effd9ddb0d45e9b0ca394e5a4b24e95c464f067c08cef00116`；SONAME `libunwind.so`，`DT_NEEDED` 是 `libc.so` 与 `libdl.so`，导出 57 个符号 |
| `vendor/runtime/companion/` | 24 个文件，111,357 B | 逐文件哈希在 `_bin/a10/evidence/20261119-s3-vendor-runtime-companion-copy.csv` |
| `runtime/`（不含 `upstream/`、`downloads/`、`build/`） | 30 个文件 | 8 个构建脚本（含 `build-companion.sh`）、1 个入口、1 个 `toolchain.sh`、5 个取源/生成脚本（含 `recipes-to-sh.py`）、4 份清单（含 `blueprints.txt`）、2 份补丁、4 个探针、`legacy/` 4 份 |
| `vendor/binder/` | 58 个文件，258,409 B | 逐文件哈希在 `_bin/a10/evidence/20261119-s4-vendor-binder-copy.csv`；只有 `compile.sh` 第 2 行把上游单元路径从 app 仓库改成本仓库，其余 57 个逐字节相同 |
| `bridges/lib/registry/libbinder.so` | 745,616 | `1dd0b8dd…`；导出 1,476 个符号，与 `prepared` 那份集合相同；NEEDED 十一项，见 §2 |
| `bridges/lib/registry/liba10binder.so` | 48,192 | `7bbd6b0b…`；导出 46 个；NEEDED 是 `libc++/libc/libm/libdl` |
| `bridges/lib/registry/libutils.so` | 165,728 | `a54f8cc1…`；导出 434 个 |
| `bridges/lib/registry/liblog.so` | 123,960 | `f0af9178…`；导出 125 个 |
| `bridges/lib/registry/libbase.so` | 103,680 | `7ea84135…`；导出 142 个 |
| `bridges/lib/registry/libcutils.so` | 21,832 | `16b03a24…`；导出 42 个 |
| `bridges/lib/registry/libbinderthreadstate.so` | 13,352 | `5bb3e4e0…`；导出 12 个 |
| `bridges/bin/binder-broker` | 70,616 | `0549b768…`；PIE，`-dynamic-linker /system/bin/linker64` |
| `bridges/bin/binder-registry` | 24,168 | `70f9cdcc…`；PIE，入口是 `vendor/native/RegistryMain.cpp` |
| `vendor/graphics/` | 128 个文件：`container-probe/graphics` 的 101 个复制品（370,831 B）加 `generated` 的 26 个 emugen 产物 | 复制品逐文件哈希在 `_bin/a10/evidence/20261119-s4-vendor-graphics-copy.csv`，emugen 产物在 `…-graphics-generated-copy.csv` |
| `bridges/graphics/lib/libOpenglSystemCommon.so` | 863,064 | `417a5f63e6724c1a5ae598f7855643e4671aa1d992b3785257326fefc5259215`；导出 793、未定义 136，与 `prepared` 那份差集 0（多 2 个 `a10pixels::*YuvRow`） |
| `bridges/graphics/lib/libGLESv2_emulation.so` | 153,272 | `5d771749bbe27cccda27824a51a12f647e37708db130b565e65b51d9c3baab76`；导出 432、未定义 15 |
| `bridges/graphics/lib/hwcomposer.ranchu.so` | 126,816 | `c00d9bd0255306982ce57a8df9ed417b5e5e94b1b53aa959356d43a4bfc680ac`；导出 191、未定义 79 |
| `bridges/graphics/lib/libEGL_emulation.so` | 113,536 | `87d76a3d29a8c0fa32f9eece2cf4ac4e5cd69b2603f41f3b84c9b258e5002f99`；导出 122、未定义 80 |
| `bridges/graphics/lib/libGLESv1_CM_emulation.so` | 103,160 | `5089fd047748b3412240ea95404b58144e3a53841898a72b4eb2a4dd7d6367a4`；导出 301、未定义 14 |
| `bridges/graphics/lib/gralloc.ranchu.so` | 32,216 | `f98038ee32d45b0ddfa058b40954c6824dc9a31178738bb42f73ede958a1ed88`；导出 7、未定义 54 |
| `bridges/graphics/codec-id.txt` | 65 | `0c8b4b134d59c2429b5d043a9d8a3833f043534a437201ac538121a3b199b433`；与 `prepared` 里宿主渲染器内嵌的那个逐字相同 |
| `bridges/properties/bin/property-service` | 64,808 | `f078280618f89ef47350d5937bfd20a05362600404ca8d9bddd7396f61f0a430`；NEEDED 与 `prepared` 那份逐项相同 |
| `bridges/properties/bin/seed-properties` | 62,456 | `eb3dec2bab4ac05d8e9f032ebc732d0b5c7087bee1b3595b25b7b8ad26914cb6`；动态链接，见 §3 的差异说明 |
| `bridges/properties/lib/liba10vm-property-client.so` | 7,240 | `9dbf40351b1a5be7754ff0e118d827ae1c79c458d335da77d011b80a496bf690`；NEEDED 只有 `libc.so` |
| `bridges/devices/lib/liba10vm-guest-devices.so` | 29,784 | `15253d17476e73e40270d2971691f86450246c3da1780900d490c59b5a105d34`；导出 39、未定义 38 |
| `bridges/devices/lib/liba10vm-binder-devices.so` | 12,384 | `aa8ac2a7451bb93f3348d7322ba5cdcf620d3e11d80d62050b85ed3cb17b1fde`；NEEDED 含 `liba10binder.so` |
| `bridges/devices/lib/liba10vm-guest-log.so` | 7,648 | `c5d3caa49408eefe40bfd7cf3f7bccb023762421c82f3864f173e5e35a10f2af`；未定义集合与 `prepared` 完全相同 |
| `bridges/devices/lib/liba10vm-hal-modules.so` | 7,408 | `567576730a48aaa5c18c1b9c2ad7de27bf41d4a2e305de9af19d4b18783663a4`；源码是 `vendor/graphics/desktop/GuestHardware.cpp` |
| `bridges/devices/lib/liba10vm-manager-policy.so` | 6,568 | `7c76458b7809f403592caa5966044ba4203c58c8cf6d0fa444ae0b0fa6227fde`；未定义集合与 `prepared` 完全相同 |
| `vendor/native/` | 19 个文件：`RegistryMain.cpp` 加属性四件、设备八件、媒体六件 | 复制清单在 `…-vendor-native-properties-copy.csv`、`…-devices-copy.csv` 与 `…-media-copy.csv` |
| `bridges/media/lib/libmediaplayerservice.so` | 1,187,880 | 缺失导出 0、未定义差集 0；NEEDED 26 项全部来自镜像与本仓库运行时 |
| `bridges/media/lib/libstagefright_httplive.so` | 507,880 | 缺失导出 0、未定义差集 0 |
| `bridges/media/lib/libresourcemanagerservice.so` | 75,344 | 缺失导出 0、未定义差集 0 |
| `bridges/media/bin/drm` | 237,176 | 缺失导出 0、未定义差集 0 |
| `bridges/media/bin/media-drm` | 27,248 | 缺失导出 0、未定义差集 0 |
| `bridges/media/bin/media-omx` | 15,608 | 缺失导出 0、未定义差集 0 |
| `bridges/media/bin/media` | 9,120 | 缺失导出 0、未定义差集 0 |
| `runtime/build-media-tools.sh` | 宿主生成器入口 | 在 WSL 里跑通：`hidl-gen` 生成 28 个 HIDL 包，SDK `aidl` 生成 9 个接口，接口头合计 351 个 |
| `runtime/media-deps.py` | 抽取链接依赖 | `deps=120 missing=0`，每件的来源与 sha256 在 `runtime/build/media/dependencies.json` |
| `bridges/media/lib/libnetd_client.so` | 21,920 | `e93d5eff314c4aa0c5dc452962b291879824f1fe22fa0c4993c5e9e4a6e76ed2`；NEEDED 只落在运行时闭包 |
| `bridges/media/lib/audio.primary.a10vm.so` | 26,304 | `1898fc221b5b84d9a74125b44fdfd2d7a336727b3e28d22e2ca45370dd6492fa`；同上 |
| `bridges/dex/lib/libdexfile.so` | 304,424 | `6a854559e96325496d6196040d94444ca3d8022201ecb0b6439fdc13f18786ed`；导出 343、缺 `prepared` 那份的导出 0 个；NEEDED 见 §2 |
| `vendor/runtime/dex-cache/` | 8 个文件 | `container-probe/runtime/dex-cache` 的原样复制，逐文件哈希在 `…-vendor-runtime-dex-cache-copy.csv`；`cache.patch` 落地判据是 `DexArchiveCache` 出现在派生源码里 |
| `runtime/fetch-dex-sources.py` | 按提交取 GitHub tar.gz | 钉 `2311566b…`，归档 sha256 `5dbbc762…`，落 `runtime/build/dex/upstream/art` 并写 `COMMIT` |
| `scripts/prepare-a10.py` | 9,060 | 读对照清单、按 `logical → 本仓库路径` 表落位、写 `prepared.staging/project-manifest.json` |
| `prepared.staging/project-manifest.json` | 逐件身份与来源 | `staged=31 missing=9 host=2`；每件带 `name`、`logical`、`guestPath`、`bytes`、`sha256`、`source`、`sourcePath` |

`dist/` 三件产物的完整清单见 [`BUILD.md`](BUILD.md) §3。产物与本轮改动无关，字节未变。

`BUILD.md` 与 `STATUS.md` 是说明文档，不是产物，不记哈希。

## 10. 2026-11-19 晚 · S5 首包与真机

这一轮做了四件事，顺序就是实际发生顺序。

1. 收口 42 件：`image/a10vm-init` 按 `_audit/00` §4.4 钉进 `prebuilt/arm64/a10vm-init`，
   2,182,048 B、`9AD65B9D…`；两个宿主件 `desktop-gpu-host` 与 `host-devices` 同样钉住，
   因为它们的源码在 app 的 `native-display` 与共享宿主层，不在本仓库。
2. 重写 `scripts/prepare-a10.py`：prepared 不再从参考 APK 整体抽取，改为 rootfs 逐条核对加本仓库产物。
   第一次生成 `files=1058 data=2209 pinned=26 changed=45`，`--apply` 切换后
   `python rom/pack-rom.py --verify-only dist/versebox-android10-1.0.0.zip` 通过。
   ROM 665,405,983 B（后因 seed 静态化变成 666.7 MB），APK 1,982,167,404 B、`8A86B903…`。
3. 第一次真机启动停在 `seed-properties`：`CANNOT LINK EXECUTABLE ... library "libunwind.so" not found`。
   这不是 ROM 少文件，是 seed 从 APK `lib/` 直接 exec，环境里只有 `PATH`。
   改法是把 `libc++_static.a`、`libc++abi.a`、`libunwind.a` 静态链进 seed，动态只留
   `libc/libdl/libm`；新 seed 5,693,880 B，NEEDED 三项。
4. `.gitignore` 改成只排除 `bridges/*/lib|bin|obj|derived`，不再整体排除 `bridges/graphics`、
   `bridges/properties`、`bridges/devices`、`bridges/media`、`bridges/dex`。
   `bootstrap/io/a10vm/guest/` 落了四个 A10 入口类，支撑类仍留在共享 `guest-runtime/check`，不复制几十份。

26 件 pinned 的分布：3 个文件（init 与两个宿主件）、5 个旧流水线改过的数据件、7 个大小写冲突的
`.asset`、7 个项目数据件（XML/RC/JAR/boot-check）、2 个 check dex、2 个旧流水线生成的数据件。
每一条的 `reason` 在 `prepared/prepare-report.json`，替换条件按类别写进 `prebuilt/README.md` 与本文 §7。

第三版 APK 2,648,887,507 B 已安装并启动。真机结果：`VERIFY 1058/1058`、`DATA 2209/2209`、
`seed_complete=1`、`art_runtime_ready=1`，服务进程全部起来；框架入口 `DesktopBoot.main` 抛
`Wrong guest SDK`，`framework-server.log` 另有一条 `services.jar` 的 dex checksum 不匹配。
这一轮没有改源码去绕过这条断言，也没有再动 libc；下一轮从框架件与 odex 的配套关系查。
