# runtime/legacy：旧流水线的记录，不参与构建

这里放两份从 app 仓库 `container-probe/runtime/` 原样复制过来的文件，迁入时逐字节未改。

- `prepare-apk.sh` 把 `bin/bootstrap-probe` 复制成 `liba10vm-p2-bootstrap.so` 塞进 prepared 的 jniLibs，
  再写一份 `runtime-inputs.json`。它调的是 `container-probe/properties/prepare-apk.sh` 与
  `container-probe/build/prepared`，两条路径都在 app 仓库，在本仓库里跑不起来。
- `container-probe-runtime-README.md` 是 P2 静态 Bionic 自举那一轮的记录，讲的是 container-probe 的验收，
  不是本仓库的构建说明。

两者都不在构建链上：`runtime/build-native.sh` 与 `runtime/fetch-sources.sh` 不引用它们，
`scripts/build-a10.sh` 也不引用。留着只因为它们是“这块源码当初怎么验的”唯一的原始记录，
删不删由维护者决定。

各源码单元里的 `vendor/runtime/dynamic/prepare-apk.sh` 与 `vendor/runtime/filesystem/prepare-apk.sh`
同样不在链上，位置与 A9、A15 的两份 `vendor/runtime` 一致，原样保留。
