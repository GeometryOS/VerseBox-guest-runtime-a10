#!/bin/sh
# A10 的属性服务组：客体侧的属性区、属性客户端，以及首次写入种子属性的可执行文件。
#
#   sh bridges/build-properties-a10.sh
#
# 产物（bridges/lib/properties 与 bridges/bin）：
#   property-service              客体属性区服务，`init` 起来之后第一件要能读的事就是它
#   liba10vm-property-client.so   客体库拿去读写私有属性区的入口
#   seed-properties               首次把 `guest.prop` 写进属性区的 PIE
#
# 上游是 bionic 的 system_properties 与 system/core 的 property_service，按
# vendor/properties/sources.txt 逐个文件取回、按 sources.sha256 校验，再打两份补丁。
# 派生树由 runtime/prepare-properties.sh 产出，本脚本只编译与链接。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
set +u
. "$MODULE/vendor/binder/compile.sh"

PROP="$MODULE/vendor/properties"
NATIVE="$MODULE/vendor/native"
PDER="$MODULE/runtime/build/properties/derived"
PB="$PDER/bionic/libc"
PC="$PDER/core/property_service/libpropertyinfoparser"
GOUT="$OUT/properties"
GOBJ="$GOUT/obj"
mkdir -p "$GOUT/lib" "$GOUT/bin" "$GOBJ"

for required in "$PB/system_properties/system_properties.cpp" \
                 "$PC/property_info_parser.cpp" \
                 "$NATIVE/PropertyService.cpp" \
                 "$NATIVE/PropertyClient.c" \
                 "$NATIVE/SeedProperties.cpp" \
                 "$PROP/native/PrivateProperties.cpp" ; do
    if [ ! -f "$required" ]; then
        printf 'properties: 缺 %s\n' "$required" >&2
        printf 'properties: 派生树靠 sh runtime/prepare-properties.sh\n' >&2
        exit 1
    fi
done

PROP_FLAGS="-I$PROP/native -I$PB -I$PB/async_safe/include -I$PB/system_properties/include -I$PC/include"
crt_pie
crt_so

# seed-properties 由宿主在客体属性区还不存在时直接 exec，环境里只有 PATH，没有 LD_LIBRARY_PATH。
# 动态链 libc++ 与 libunwind 会让它启动就报 "library libunwind.so not found"，所以这两件必须静态链。
# 路径由 clang 自己解析，换 NDK 版本时不用改这里的目录名。
LIBCXX_STATIC=$(clang --target=$TARGET --print-file-name=libc++_static.a)
LIBCXXABI_STATIC=$(clang --target=$TARGET --print-file-name=libc++abi.a)
LIBUNWIND_STATIC=$(clang --target=$TARGET --print-file-name=libunwind.a)
for static_lib in "$LIBCXX_STATIC" "$LIBCXXABI_STATIC" "$LIBUNWIND_STATIC"; do
    if [ ! -f "$static_lib" ]; then
        printf 'properties: 缺静态库 %s\n' "$static_lib" >&2
        exit 1
    fi
done

# 属性区的实现先打进静态库：seed-properties 要带着它上机，不能依赖客体装好之后才有的 .so。
core=
for path in context_node contexts_serialized prop_area prop_info system_properties; do
    object="$GOBJ/core-$path.o"
    platform_compile "$PB/system_properties/$path.cpp" "$object" $PROP_FLAGS -fvisibility=hidden
    core="$core $object"
done
for path in "$PC/property_info_parser.cpp" "$PB/async_safe/async_safe_log.cpp"; do
    object="$GOBJ/core-$(basename "$path" .cpp).o"
    platform_compile "$path" "$object" $PROP_FLAGS -fvisibility=hidden
    core="$core $object"
done
llvm-ar rcD "$GOUT/lib/liba10vm-property-core.a" $core

# property-service 是一个 PIE，由宿主在客体启动的早期拉起。
service=
for path in "$PB/system_properties/context_node.cpp" \
            "$PB/system_properties/contexts_serialized.cpp" \
            "$PB/system_properties/prop_area.cpp" \
            "$PB/system_properties/prop_info.cpp" \
            "$PB/system_properties/system_properties.cpp" \
            "$PC/property_info_parser.cpp" \
            "$PB/async_safe/async_safe_log.cpp" \
            "$PROP/native/PrivateProperties.cpp" \
            "$PROP/native/PropertyInfo.cpp" \
            "$NATIVE/PropertyService.cpp" ; do
    object="$GOBJ/service-$(basename "$path" .cpp).o"
    platform_compile "$path" "$object" $PROP_FLAGS
    service="$service $object"
done
link_pie() {
    output=$1
    shift
    ld.lld -pie -e _start -dynamic-linker /system/bin/linker64 \
        -z now -z relro -z max-page-size=4096 --hash-style=gnu --eh-frame-hdr \
        --build-id=sha1 --no-undefined --exclude-libs ALL \
        "$OUT/obj/crt/crtbegin.o" "$@" "$LINKER" \
        "$LIBCXX" "$LIBUNWIND" "$LIBM" "$LIBDL" "$LIBC" "$BUILTINS" \
        "$OUT/obj/crt/crtend.o" -o "$output"
}
link_pie "$GOUT/bin/property-service" $service

platform_compile "$NATIVE/PropertyClient.c" "$GOBJ/property-client.o" -I"$NATIVE"
ld.lld -shared -soname liba10vm-property-client.so -z now -z relro -z max-page-size=4096 \
    --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
    "$OUT/obj/crt/crtbegin_so.o" "$GOBJ/property-client.o" \
    "$LIBC" "$BUILTINS" "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/liba10vm-property-client.so"

# seed-properties 是首启件，不能依赖客体装好之后才有的 .so：libc++ 与 libunwind 静态链，
# bionic 的 libc/libdl/libm 仍然动态链，宿主系统里有这三件。旧流水线也是这个形状。
seed=
for path in "$NATIVE/SeedProperties.cpp" "$PROP/native/PrivateProperties.cpp" \
            "$PROP/native/PropertyInfo.cpp" ; do
    object="$GOBJ/seed-$(basename "$path" .cpp).o"
    platform_compile "$path" "$object" $PROP_FLAGS -fvisibility=hidden -D_LIBCPP_ABI_NAMESPACE=__ndk1
    seed="$seed $object"
done
ld.lld -pie -e _start -dynamic-linker /system/bin/linker64 \
    -z now -z relro -z max-page-size=4096 --hash-style=gnu --eh-frame-hdr \
    --build-id=sha1 --no-undefined --exclude-libs ALL \
    "$OUT/obj/crt/crtbegin.o" $seed "$GOUT/lib/liba10vm-property-core.a" \
    "$LIBCXX_STATIC" "$LIBCXXABI_STATIC" "$LIBUNWIND_STATIC" \
    "$LIBM" "$LIBDL" "$LIBC" "$BUILTINS" \
    "$OUT/obj/crt/crtend.o" -o "$GOUT/bin/seed-properties"

# ld-android.so 也在清单里：这两个 PIE 把本仓库的 linker 作为输入链了进去，
# libc 的 __loader_* 只能由它提供。客体里那份 linker 的 SONAME 正是 ld-android.so。
allowed='libc++.so libm.so libunwind.so libc.so libdl.so ld-android.so'
for f in "$GOUT/bin/property-service" "$GOUT/bin/seed-properties" \
         "$GOUT/lib/liba10vm-property-client.so"; do
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
    for needed in $(llvm-readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'); do
        case " $(printf '%s' "$allowed" | tr '\n' ' ') " in
            *" $needed "*) ;;
            *) printf 'properties: %s 的 NEEDED 里出现 %s，不在允许清单\n' \
                   "$(basename "$f")" "$needed" >&2; exit 1 ;;
        esac
    done
done

# 客户端那个共享库的导出面必须盖住 prepared 里同名副本导出的每一个符号。
reference="$MODULE/prepared/jniLibs/arm64-v8a/liba10vm-guest-liba10vm-property-client.so"
if [ -f "$reference" ]; then
    llvm-nm -D --defined-only "$reference" | awk '{print $3}' | sort -u > "$GOBJ/client.reference"
    llvm-nm -D --defined-only "$GOUT/lib/liba10vm-property-client.so" | awk '{print $3}' | sort -u \
        > "$GOBJ/client.built"
    if comm -23 "$GOBJ/client.reference" "$GOBJ/client.built" | grep -q .; then
        printf 'properties: liba10vm-property-client 缺 prepared 那份导出的符号：\n' >&2
        comm -23 "$GOBJ/client.reference" "$GOBJ/client.built" >&2
        exit 1
    fi
fi

printf 'properties finished\n'
for f in "$GOUT/bin/property-service" "$GOUT/bin/seed-properties" \
         "$GOUT/lib/liba10vm-property-client.so"; do
    printf '  %s  %s  %s\n' "$(wc -c < "$f" | tr -d ' ')" \
        "$(sha256sum -t "$f" | cut -d ' ' -f 1)" "$(basename "$f")"
done
