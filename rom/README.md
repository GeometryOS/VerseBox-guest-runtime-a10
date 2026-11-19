# guest-runtime-a10/rom —— Android 10 的 ROM 工具链

| 文件 | 作用 |
| --- | --- |
| `pack-rom.py` | 打包器：`prepared/` + 自述 → `dist/versebox-<id>-<version>.zip`（新格式） |
| `rom_hash.py` | `payloadSha256` 的唯一实现（算法是**合同**） |
| `stage-apk-payload.py` | 旧格式：客体 .so → `assets/guest-runtime/lib/**`，`jniLibs` 只留 resident |
| `rom.properties.yaml` | ROM 身份（`id` / `name` / `defaultRomVersion` / `libMode`） |
| `resident-native.txt` | 必须留在 APK `lib/arm64-v8a` 的逻辑名（含逐调用点理由） |

## 为什么这里有一份「和 A9/A15 一样」的脚本

三个运行时是**三个独立仓库**（`docs/rom-package/11` §1），各自 clone / CI / 发布。
跨仓库引用脚本会让「只 clone A10」的人打不出 A10 的 ROM，也会把两个域的发布节奏焊在一起。
三个仓库之间唯一必须逐字节一致的东西是 `rom_hash.py` 的规范化算法（app 侧解包器只认这一种）；
`pack-rom.py` 只允许在**域默认值**上不同（id / 清单名 / assets 前缀 / resident 清单 / dist 目录）。

核对方法：拿**同一个** payload 目录跑三个仓库的 `rom_hash.py --json`，输出必须相同。

## 判据

```text
prepared-apk/jniLibs/arm64-v8a/*.so        = resident 清单（A10 是 3 个）
prepared-apk/assets/guest-runtime/lib/     = 其余 1055 个
dist/versebox-android10-1.0.0.zip          --verify-only 通过；libMode=rom
```