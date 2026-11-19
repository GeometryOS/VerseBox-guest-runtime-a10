#!/bin/sh
# 单元原件在 app 仓库里用 $ROOT 指容器探针树；落进本仓库后指本仓库的运行时单元。
. "$MODULE/vendor/runtime/companion/compile.sh"
platform_compile() {
    case "$1" in
        *.cpp|*.cc) platform_flags='-std=gnu++17 -fno-exceptions -fno-rtti -fno-sized-deallocation' ;;
        *) platform_flags= ;;
    esac
    compile "$@" $platform_flags \
        -D__ANDROID_VNDK__ -DA10VM_PRIVATE_RUNTIME -D_FILE_OFFSET_BITS=64 -DLOG_NDEBUG=1 \
        -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484 \
        -I"$UP/system/core/base/include" -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libcutils/include" -I"$UP/system/core/libutils/include" \
        -I"$UP/system/core/libsystem/include" -I"$UP/system/core/libprocessgroup/include" \
        -I"$UP/system/core/libbacktrace/include" -I"$UP/system/core/include" \
        -I"$UP/frameworks/native/libs/binder/include" \
        -I"$UP/frameworks/native/libs/binderthreadstate/include" \
        -I"$UP/system/libhwbinder/include" -I"$UP/frameworks/native/include" \
        -I"$SRC/native" -I"$OUT/generated" -Wno-deprecated-declarations
}
