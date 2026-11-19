#!/bin/sh
# A10 的 Binder 组：客体侧的传输层、注册表，以及打了补丁的 AOSP 10 Binder 与支撑库。
#
#   sh bridges/build-binder-a10.sh
#
# 产物：
#   bridges/lib/registry/liba10binder.so   项目自己的 wire、driver、client buffers
#   bridges/lib/registry/lib*.so           打了 platform.patch 的 AOSP 10 binder 与 log/base/cutils/utils
#   bridges/bin/binder-broker              每个客体一个独立 broker 进程
#   bridges/bin/binder-registry            Binder 注册表进程
#
# 补丁是这一组的核心：它把 AOSP binder 的 open、ioctl、mmap 换成项目的 a10binder_*，
# 客体里的 libbinder 才能在不碰内核驱动的条件下走宿主通道。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
SRC="$MODULE/vendor/binder"
# 单元自己的 compile.sh 定义 platform_compile：C++ 用 gnu++17 加 VNDK 宏，
# 与 container-probe 里那一份逐字一致，本仓库不抄第二份参数表。
. "$SRC/compile.sh"
OBJ="$OUT/obj/binder"
DERIVED="$OUT/derived"
REG="$OUT/lib/registry"
REP="$OUT/obj/binder"
mkdir -p "$OBJ" "$REG" "$OUT/bin" "$REP"

# 1) 派生件：补丁改过的那几个上游文件先复制到 derived 再打补丁，上游树一个字节不动。
for path in frameworks/native/libs/binder/ProcessState.cpp \
            frameworks/native/libs/binder/IPCThreadState.cpp \
            frameworks/native/libs/binderthreadstate/IPCThreadStateBase.cpp \
            system/core/libutils/misc.cpp \
            system/core/liblog/config_read.cpp \
            system/core/liblog/config_write.cpp \
            system/core/liblog/logger_write.cpp; do
    mkdir -p "$DERIVED/$(dirname "$path")"
    cp "$UP/$path" "$DERIVED/$path"
done
# 这份补丁的 hunk 头与正文对不上，git apply 会整份判成“无可应用”，退出码 0 却一个字节不改。
# 用 GNU patch，判据是标记符号真的出现在派生件里。
patch -p1 -t -d "$DERIVED" -i "$SRC/platform.patch"
grep -q a10binder_default_driver "$DERIVED/frameworks/native/libs/binder/ProcessState.cpp" || {
    printf 'build-binder-a10.sh: platform.patch 没落到 ProcessState.cpp\n' >&2
    exit 1
}
grep -q a10binder_ioctl "$DERIVED/frameworks/native/libs/binder/IPCThreadState.cpp" || {
    printf 'build-binder-a10.sh: platform.patch 没落到 IPCThreadState.cpp\n' >&2
    exit 1
}

# 2) 源清单由单元自己的 select-sources.py 读 Android.bp 得出，本仓库不抄第二份。
"$PY" -B "$SRC/select-sources.py" "$UP" > "$REP/recipes.json"
"$PY" "$RT/recipes-to-sh.py" "$REP/recipes.json" > "$REP/recipes.sh"
. "$REP/recipes.sh"
clang --version > "$REP/compiler.txt"
crt_so

# 3) 项目传输层先出，AOSP binder 链接它。ROM 的 libbinder 仍由镜像提供，
# 这一份只给注册表进程用，所以落在 registry/ 里，不与客体同名库抢名字。
transport=
for path in Wire.cpp TransactionLayout.cpp TransactionWire.cpp Driver.cpp ClientBuffers.cpp; do
    object="$OBJ/a10binder-$path.o"
    platform_compile "$SRC/native/$path" "$object"
    transport="$transport $object"
done
link_shared liba10binder.so "$REG" $transport "$LIBCXX" "$LIBC" "$LIBM" "$LIBDL"

# 4) 支撑库与 AOSP binder 本体。顺序固定：log 在最前，binder 在最后。
for recipe in log base cutils utils binderthreadstate binder; do
    case "$recipe" in
        log) sources=$log_sources ;;
        base) sources=$base_sources ;;
        cutils) sources=$cutils_sources ;;
        utils) sources=$utils_sources ;;
        binderthreadstate) sources=$binderthreadstate_sources ;;
        binder) sources=$binder_sources ;;
    esac
    objects=
    for path in $sources; do
        object="$OBJ/$(printf '%s' "$path" | tr / _).o"
        flags="-I$(dirname "$UP/$path")"
        if [ -f "$DERIVED/$path" ]; then input="$DERIVED/$path"; else input="$UP/$path"; fi
        case "$path" in
            */Threads.cpp) flags="$flags -Dset_sched_policy=a10vm_set_sched_policy" ;;
        esac
        platform_compile "$input" "$object" $flags
        objects="$objects $object"
    done
    if [ "$recipe" = cutils ]; then
        for path in Ashmem.cpp Scheduling.cpp; do
            object="$OBJ/$path.o"
            platform_compile "$SRC/native/$path" "$object"
            objects="$objects $object"
        done
    fi
    dependencies=
    case "$recipe" in
        base) dependencies="$REG/liblog.so" ;;
        cutils) dependencies="$REG/liblog.so $REG/libbase.so" ;;
        utils) dependencies="$REG/libcutils.so $REG/liblog.so" ;;
        binderthreadstate) dependencies="$REG/liblog.so" ;;
        binder) dependencies="$REG/liba10binder.so $REG/libutils.so $REG/libcutils.so $REG/libbase.so $REG/liblog.so $REG/libbinderthreadstate.so" ;;
    esac
    link_shared "lib$recipe.so" "$REG" $objects $dependencies \
        "$LIBCXX" "$LIBM" "$LIBUNWIND" "$LIBC" "$LIBDL"
done

# 5) 两个进程：broker 与注册表。
crt_pie
broker=
for path in Broker.cpp BrokerCleanup.cpp BrokerDispatch.cpp BrokerMain.cpp \
            BrokerNodeReclaim.cpp BrokerObjects.cpp BrokerTransactions.cpp Wire.cpp; do
    object="$OBJ/broker-$path.o"
    platform_compile "$SRC/native/$path" "$object"
    broker="$broker $object"
done
ld.lld -pie -e _start -dynamic-linker /system/bin/linker64 \
    -z max-page-size=4096 -z now -z relro --hash-style=gnu --eh-frame-hdr --build-id=sha1 \
    --no-undefined --exclude-libs ALL \
    "$OUT/obj/crt/crtbegin.o" $broker \
    "$REG/liba10binder.so" "$REG/libbinder.so" "$REG/libutils.so" \
    "$REG/libcutils.so" "$REG/libbase.so" "$REG/liblog.so" \
    "$REG/libbinderthreadstate.so" \
    "$LIBCXX" "$LIBC" "$LIBM" "$LIBDL" "$BUILTINS" \
    "$OUT/obj/crt/crtend.o" -o "$OUT/bin/binder-broker"

platform_compile "$MODULE/vendor/native/RegistryMain.cpp" "$OBJ/binder-registry.o" \
    -I"$SRC/native"
platform_compile "$SRC/native/ServiceRegistry.cpp" "$OBJ/service-registry.o"
ld.lld -pie -e _start -dynamic-linker /system/bin/linker64 \
    -z max-page-size=4096 -z now -z relro --hash-style=gnu --eh-frame-hdr --build-id=sha1 \
    --no-undefined --exclude-libs ALL \
    "$OUT/obj/crt/crtbegin.o" "$OBJ/binder-registry.o" "$OBJ/service-registry.o" \
    "$REG/libbinder.so" "$REG/liba10binder.so" "$REG/libutils.so" \
    "$REG/libcutils.so" "$REG/libbase.so" "$REG/liblog.so" \
    "$REG/libbinderthreadstate.so" \
    "$LIBCXX" "$LIBC" "$LIBM" "$LIBDL" "$BUILTINS" \
    "$OUT/obj/crt/crtend.o" -o "$OUT/bin/binder-registry"

for f in "$REG/lib"*.so "$OUT/bin/binder-broker" "$OUT/bin/binder-registry"; do
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
done
sha256sum "$REG/"*.so "$OUT/bin/binder-broker" "$OUT/bin/binder-registry" \
    > "$REP/binder.sha256"
printf 'binder bridges finished\n  %s\n  %s\n' "$REG" "$OUT/bin"
