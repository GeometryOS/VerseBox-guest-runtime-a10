#!/bin/sh
# A10 的设备与日志组：客体侧看到的设备总线、日志通道、管理器策略与 HAL 模块表。
#
#   sh bridges/build-devices-a10.sh
#
# 产物（bridges/devices/lib）：
#   liba10vm-guest-devices.so    客体 /dev 与宿主设备端点之间的传输
#   liba10vm-binder-devices.so   设备端点走 binder 的那一半
#   liba10vm-manager-policy.so   servicemanager 的准入策略
#   liba10vm-guest-log.so        客体日志落到宿主的那条通道
#   liba10vm-hal-modules.so      客体按 hw_get_module 找模块时的模块表
#
# 这五件都不依赖图形与属性组，只依赖运行时闭包与 binder 组的 liba10binder。
# 所以跑这一组之前要先跑 `sh runtime/build-a10-runtime.sh` 与 `sh bridges/build-binder-a10.sh`。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
set +u
. "$MODULE/vendor/binder/compile.sh"

NATIVE="$MODULE/vendor/native"
GRAPHICS="$MODULE/vendor/graphics/desktop"
GOUT="$OUT/devices"
GOBJ="$GOUT/obj"
REG="$OUT/lib/registry"
mkdir -p "$GOUT/lib" "$GOBJ"

for required in "$NATIVE/GuestDevices.cpp" "$NATIVE/BinderDevices.cpp" \
                 "$NATIVE/ManagerPolicy.c" "$NATIVE/GuestLog.c" \
                 "$NATIVE/GuestSharedMemory.cpp" "$NATIVE/HostLinearMemory.cpp" \
                 "$NATIVE/HostDeviceTransport.cpp" \
                 "$GRAPHICS/GuestHardware.cpp" "$REG/liba10binder.so" ; do
    if [ ! -f "$required" ]; then
        printf 'devices: 缺 %s\n' "$required" >&2
        printf 'devices: 运行时靠 sh runtime/build-a10-runtime.sh，liba10binder 靠 sh bridges/build-binder-a10.sh\n' >&2
        exit 1
    fi
done

crt_so
link_guest() {
    name=$1
    shift
    ld.lld -shared -soname "$name" -z now -z relro -z max-page-size=4096 \
        --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
        "$OUT/obj/crt/crtbegin_so.o" "$@" "$BUILTINS" \
        "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/$name"
}

# 设备传输：四份源一起编，链 libc++ 与 libunwind，因为 GuestDevices.cpp 用了 C++ 容器。
objects=
for path in "$NATIVE/GuestDevices.cpp" "$NATIVE/HostLinearMemory.cpp" \
            "$NATIVE/HostDeviceTransport.cpp" "$NATIVE/GuestSharedMemory.cpp" ; do
    object="$GOBJ/$(basename "$path" .cpp).o"
    platform_compile "$path" "$object"
    objects="$objects $object"
done
link_guest liba10vm-guest-devices.so $objects \
    "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC"

# BinderDevices.cpp 直接用 binder 组的 Driver.h，头从 vendor/binder/native 取，
# 与本仓库其余单元一致：源码跟着来源走，不复制第二份头。
platform_compile "$NATIVE/BinderDevices.cpp" "$GOBJ/binder-devices.o" -I"$MODULE/vendor/binder/native"
link_guest liba10vm-binder-devices.so "$GOBJ/binder-devices.o" \
    "$REG/liba10binder.so" "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC"

platform_compile "$NATIVE/ManagerPolicy.c" "$GOBJ/manager-policy.o"
link_guest liba10vm-manager-policy.so "$GOBJ/manager-policy.o" "$LIBC"

platform_compile "$NATIVE/GuestLog.c" "$GOBJ/guest-log.o"
link_guest liba10vm-guest-log.so "$GOBJ/guest-log.o" "$LIBC"

platform_compile "$GRAPHICS/GuestHardware.cpp" "$GOBJ/hal-modules.o" -I"$GRAPHICS" \
    -I"$UP/hardware/libhardware/include"
link_guest liba10vm-hal-modules.so "$GOBJ/hal-modules.o" "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC"

allowed='liba10binder.so libc++.so libm.so libunwind.so libc.so libdl.so'
for f in "$GOUT/lib"/*.so; do
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
    for needed in $(llvm-readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'); do
        case " $(printf '%s' "$allowed" | tr '\n' ' ') " in
            *" $needed "*) ;;
            *) printf 'devices: %s 的 NEEDED 里出现 %s，不在允许清单\n' \
                   "$(basename "$f")" "$needed" >&2; exit 1 ;;
        esac
    done
done

# 五件的导出面必须盖住 prepared 里同名副本导出的每一个符号。
for name in liba10vm-guest-devices.so liba10vm-binder-devices.so liba10vm-manager-policy.so \
            liba10vm-guest-log.so liba10vm-hal-modules.so; do
    reference="$MODULE/prepared/jniLibs/arm64-v8a/liba10vm-guest-$name"
    if [ ! -f "$reference" ]; then
        printf 'devices: %s 没有对照件，跳过导出比对\n' "$name"
        continue
    fi
    llvm-nm -D --defined-only "$reference" | awk '{print $3}' | sort -u > "$GOBJ/$name.reference"
    llvm-nm -D --defined-only "$GOUT/lib/$name" | awk '{print $3}' | sort -u > "$GOBJ/$name.built"
    if comm -23 "$GOBJ/$name.reference" "$GOBJ/$name.built" | grep -q .; then
        printf 'devices: %s 缺 prepared 那份导出的符号：\n' "$name" >&2
        comm -23 "$GOBJ/$name.reference" "$GOBJ/$name.built" >&2
        exit 1
    fi
done

printf 'devices finished\n'
for f in "$GOUT/lib"/*.so; do
    printf '  %s  %s  %s\n' "$(wc -c < "$f" | tr -d ' ')" \
        "$(sha256sum -t "$f" | cut -d ' ' -f 1)" "$(basename "$f")"
done
