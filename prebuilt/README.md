# A10 预置件

这里放没有源码、只能按字节钉住的客体件。每件旁边有一份同名 `.sha256`，构建脚本先核对哈希再使用，不匹配就失败。
判定规则见 `_audit/00-总纲与红线.md` §4.4：只有确实没有源码的组件才允许 pinned，而且必须放 `prebuilt/` 并带哈希。

## arm64/a10vm-init

- 字节数 2,182,048，sha256 `9AD65B9DEA2ED65278A58CE83C16B6484CDF29ED62FD498CB093224E84A867F6`。
- ELF 形状是 `Type: EXEC`，没有动态段；它是一支静态引导 init，先准备客体运行环境，再 `execv` 镜像里的 `/system/bin/init`。
- 工作树里没有它的源码或构建脚本，旧的 A10 流水线也没有留下可复现的输入。它不是从镜像改名来的：镜像的 `/init` 是指向 `/system/bin/init` 的符号链接，那支是 726,200 B 的动态件。
- 处置是钉住字节，不做反汇编重写。重写等于把开机路径重做一遍，等价性无法用静态判据证明，只能靠装机赌，违反“这是移植，不是重写 Android”。

替换条件：拿到这支 init 的源码与补丁，或者拿到它能复现的上游 AOSP 10 init 构建配方，并且用同一份 rootfs 做出的包在真机上把 `VERIFY`、`DATA`、`READY` 跑到与当前记录同级。替换时必须同时更新这里的字节与 `.sha256`，并在 `STATUS.md` 的已知限制里销掉这一条。

## arm64/desktop-gpu-host 与 arm64/host-devices

- `desktop-gpu-host` 6,471,456 B，sha256 `6578B9D8...709B93`；`host-devices` 49,928 B，sha256 `D25A9540...D2E44C`。
- 两件跑在 app 进程里，来源是 app 的 `native-display` 与共享宿主层，不属于 A10 仓库的源码，也不进 ROM payload，按 resident 留在 APK 的 `lib/`。
- A10 仓库只消费它们，不在这里重编。钉住是为了让只 clone A10 的构建也能产出与参考 prepared 相同的 resident 集合；等 app 侧把宿主件作为构建输入发布出来，就改成从那个输入取，删掉这里的副本。

## 与 A15 的 prebuilt 不同

A15 的 `prebuilt/arm64/desktop-gpu-host` 是宿主渲染器，属于 app 进程；这里的是客体首启件，会进 ROM。两者都遵守同一条规则：没有源码才钉住，钉住必须带哈希。
