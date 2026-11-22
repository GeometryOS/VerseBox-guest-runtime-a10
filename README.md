<p align="center">
  <img src="https://img.shields.io/badge/guest%20image-Redroid%2010-6f42c1.svg" alt="guest image: Redroid 10">
  <img src="https://img.shields.io/badge/API-29%20arm64-3ddc84.svg" alt="API 29 arm64">
</p>

# guest-runtime-a10

这是一个可以在不用 root，不用 Docker，不用容器的情况下，让 **Android 10（API 29，arm64）** 运行在 VerseBox 虚拟机的安卓 10 独立客体😋

> **目前的状态：可以启动、可以操作，功能面已经完整。**
## 这是干什么的

Android 10 的镜像通常依赖容器或 root 环境运行。本仓库自行搭建运行所需的基础设施：
一份 API 29 的 linker/libc/libdl/libm/libunwind，一套将客体绝对路径映射到 App 私有目录的补丁，
以及 Binder、属性、设备、日志、图形、媒体六座桥。用户空间复用 Redroid 10（ART、framework、系统应用、HAL），
构成一个不依赖宿主系统版本、也不需要特权的客体。

## 构建

**Linux / macOS：**

```sh
sh scripts/build-a10.sh
```

**Windows：** 在 Git Bash 里执行同一条命令。`python3` 必须在 `PATH` 里
（`WindowsApps` 下那个是商店占位，跑不起来）。

脚本默认复用已有的 `prepared/`，只打 ROM 包；要从源码链重跑一遍再落位，用：

```sh
sh scripts/build-a10.sh --from-sources
```

它先跑 `scripts/build-a10-data.sh` 生成 `runtime-check.dex`、`services.jar`、`guest.prop`、VINTF、
seccomp 与 system image 路径，再由 `scripts/prepare-a10.py --apply` 落位，最后出 ROM 包。
运行时的五件单独重编用 `sh runtime/build-a10-runtime.sh`，媒体接口头的宿主生成器要有 `bison` 与 `flex`
（只能在 Linux 上跑）。

需要 Python 3、JDK、Android SDK（`platforms/android-35`、`build-tools/35.0.0` 与 `build-tools/30.0.3`），
重建桥接与图形还需要 NDK 29，路径通过 `ANDROID_HOME` 与 `ANDROID_NDK_HOME` 读取。
客体的 AIDL 头必须由 `build-tools/30.0.3` 的 `aidl` 生成，`d8` 用 `35.0.0`；顺序与产物验收见 [BUILD.md](BUILD.md)。

APK 不在本仓库编：本仓库产出 `prepared/` 与 ROM 包，APK 由宿主工程消费 `prepared-apk/` 编出。

## 运行原理🤔

宿主 App 承担 init 的角色：读取清单，按 uid/gid 启动每个客体进程。
客体内的 `/system`、`/data` 等绝对路径由自建 linker/libc 重定向到本地目录，
内核不会访问宿主系统的对应路径：

| 层 | 来自 | 职责 |
| --- | --- | --- |
| 启动器 | 宿主工程 `FrameworkSession` | 读取清单、启动进程、收集日志与就绪标记 |
| 运行时 | `runtime/`、`vendor/runtime/` | API 29 的 linker/libc/libdl/libm/libunwind，含路径映射与私有属性区补丁 |
| 桥接 | `bridges/` | 属性服务、Binder 传输、设备、guest 日志、`netd` 与音频 HAL、媒体七件 |
| 图形 | `bridges/graphics/`、`vendor/graphics/` | goldfish HWC、gralloc 与 EGL/GLES；帧交给宿主合成 |
| 用户空间 | Redroid 10 镜像 | ART、framework、系统服务、系统 APK、HAL |
| 汇总 | `prepared/` | 以上全部打包为 assets、jniLibs 与清单 |

画面与输入都是客体的：SurfaceFlinger 合成图层，宿主只做显示与触摸转发；
开机动画由镜像自带的 `/system/bin/bootanimation` 绘制，`sys.boot_completed=1` 后退出。

## 目录

```text
scripts/     镜像抓取与解包、prepared、data 与 dex 生成、build 入口
bootstrap/   A10Boot、A10DesktopHome、A10DesktopCheck 等 Java 入口类
framework/   客体侧框架补丁与检查类（PackageCodePaths、AppLaunch、AppDexCache 等）
vendor/      运行时配方（dynamic/filesystem/companion）、binder 单元、图形与媒体单元
bridges/     属性/Binder/设备/日志/图形/媒体桥的源码与构建脚本
runtime/     API 29 linker/libc/libdl/libm/libunwind 的源清单、补丁、构建脚本
rom/         ROM 打包器、resident 清单与打包说明
prebuilt/    pinned 的 framework-check.dex、清单快照与三件宿主件
prepared/    产物：assets + jniLibs（不入库）
rootfs/      解包后的 Redroid 10 根文件系统（不入库）
downloads/   镜像层与 config（不入库）
```

> Java 层不在 `src/` 下：入口类在 `bootstrap/io/a10vm/guest/`，框架与检查类在
> `framework/src/main/java/`，两者由 `scripts/build-a10-data.sh` 与 `scripts/prepare-a10.py`
> 编进 `runtime-check.dex`、`services.jar` 与 `framework-check.dex`。

## 注意事项

- **镜像文件不在本仓库。** Redroid 10 的 tar 由 `scripts/fetch-redroid10.py` 按
  `sources.lock.json` 的 digest 在构建时获取，仓库只包含构建它的补丁与应用源码。
- 仅`framework-check.dex` 目前沿用 `prebuilt/framework-check.dex`（带 `.sha256`）

## ROM 自动打包

构建链会自动将 `prepared/` 整合并输出为统一格式的 `.zip` ROM 包，默认存放于 `dist/` 目录下：

```text
dist/versebox-android10-<ver>.zip          完整 ROM 包
dist/versebox-android10-<ver>-min.zip      最小占位包
dist/apk-resident-libs-android10.tar       APK 的 lib/ 来源
dist/pack-android10-<ver>.json             打包报告（payload 哈希与条目数）
```

了解更多请参考 [rom/README.md](rom/README.md)。

## 文档

- 构建、产物验收、排查：[BUILD.md](BUILD.md)
- 新版 ROM 格式与打包工具：[rom/README.md](rom/README.md)
- 分阶段状态：[STATUS.md](STATUS.md)

## 许可证

本仓库按目录拆分许可：

- **核心客体运行时**（`runtime/`、`bridges/`、`bootstrap/`、`framework/`、
  `vendor/`、`prebuilt/arm64/`）：**AGPL-3.0-only**。对外提供修改后的客体时，
  需按 AGPL §13 向使用者提供对应源码；个人自用、自行修改不受影响。
- **构建与集成工具**（`scripts/`、`rom/`、清单生成、宿主侧接入的配置与示例）：
  **MIT**。可自由接入自有应用。
- **`vendor/` 与 AOSP 派生部分**：来自 AOSP 与宿主工程的共享容器层，
  保留 **Apache-2.0** 及文件自带的 BSD/MIT 声明，作为独立部分分发。

许可全文目前只在宿主工程根目录（`LICENSE`），尚未随本仓库单独落位。
Redroid 10 镜像在构建时获取，不随仓库分发，镜像自身许可以上游为准。
