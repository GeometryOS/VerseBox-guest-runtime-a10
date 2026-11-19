# A10 客体启动层

这里只放 A10 自己的入口类，对应 A15 的 `bootstrap/io/a10vm/guest/A15Boot.java` 与 A9 的 `A9Boot.java`。
四份源码从 `guest-runtime/check` 的同名类改名而来，逻辑没有改：

| 这里 | 来源 | 角色 |
| --- | --- | --- |
| `A10Boot.java` | `DesktopBoot.java` | 宿主拉起的第一段 Java，校验 SDK 29 后进入 SystemServer |
| `A10GuestApplication.java` | `GuestApplication.java` | 应用进程入口，配置 VMRuntime 后反射目标类的 main |
| `A10DesktopCheck.java` | `DesktopCheck.java` | 桌面自检，按服务、用户解锁与 Launcher3 判 READY |
| `A10DesktopHome.java` | `DesktopHome.java` | 自检通过后把 Launcher3 拉到前台并等窗口 HAS_DRAWN |

不把 `guest-runtime/check` 的几十个类整体搬过来。那些类是三个域共用的检查与适配实现，
宿主启动层仍在 `guest-runtime/src/main/java`；A10 只拥有入口与判据，支撑类由 dex 构建时一起编。
把共用类复制成第二份，等于给以后“只改一边”埋雷。

这份目录现在只落源码，还没有接进 dex 构建与清单的 `runtimeProfile`。切换 `bootEntry` 与
`appClass` 是单独一次验证：编出的 `framework-check.dex` 里要有这四个类，装机后 `VERIFY`、`DATA`、
`READY` 三条与当前记录同级，才允许把清单从默认入口改到这里。没有这一步之前，`prepared` 仍走
`DesktopBoot`，不能把“源码已落位”写成“入口已切换”。
