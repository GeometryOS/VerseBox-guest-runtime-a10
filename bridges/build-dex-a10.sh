#!/bin/sh
# A10 的 dex 单元：客体里那份带 DexArchiveCache 的 libdexfile。
#
#   sh bridges/build-dex-a10.sh
#
# 产物：bridges/dex/lib/libdexfile.so
#
# 为什么这一件单独一组：它不是 AOSP 10 的原件，是 `cache.patch` 打在 LineageOS `android_art`
# 的钉住提交上编出来的。同一份取证也纠正了 S3 的一处结论——prepared 里的 `libart.so` 与镜像逐字节相同，
# 但 `libdexfile.so` 不是，说明 dex-cache 单元并不替换 libart，只替换 libdexfile。
set -eu
: "${MODULE:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$(dirname -- "$0")/compile.sh"
set +u

SRC="$MODULE/vendor/runtime/dex-cache"
ART="$MODULE/runtime/build/dex/upstream/art"
DER="$OUT/dex/derived"
OBJ="$OUT/dex/obj"
GOUT="$OUT/dex"
APEXLIB="$MODULE/rootfs/system/apex/com.android.runtime.debug/lib64"
SYSLIB="$MODULE/rootfs/system/lib64"

for required in "$SRC/cache.patch" "$SRC/DexArchiveCache.cpp" "$SRC/DexClassIndex.cpp" \
                 "$ART/COMMIT" "$ART/libdexfile/dex/dex_file.cc" \
                 "$ART/tools/generate_operator_out.py" \
                 "$APEXLIB/libartbase.so" "$APEXLIB/libartpalette.so" \
                 "$SYSLIB/libbase.so" "$SYSLIB/liblog.so" "$SYSLIB/libcrypto.so" ; do
    if [ ! -f "$required" ]; then
        printf 'dex: 缺 %s\n' "$required" >&2
        printf 'dex: 源码靠 python runtime/fetch-dex-sources.py，镜像库靠 scripts/fetch-redroid10.py 与 extract-rootfs.py\n' >&2
        exit 1
    fi
done

rm -rf "$DER" "$OBJ" "$GOUT/lib" "$GOUT/generated"
mkdir -p "$GOUT/lib" "$GOUT/generated" "$OBJ" "$DER"
cp -R "$ART/libdexfile" "$ART/libartbase" "$ART/libartpalette" "$DER/"

# cache.patch 的 hunk 头是手写裁剪过的，和图形那一组同一种情形：只有 git apply --recount 能落地，
# 落地与否自己判，判据是 DexArchiveCache 的标记真的进了 libdexfile 的源码。
apply_patch() {
    patch_file=$1
    relative=${DER#"$MODULE"/}
    if (cd "$MODULE" && git apply --recount --unsafe-paths --directory="$relative" "$patch_file"); then
        return 0
    fi
    if (cd "$MODULE" && git apply --recount --unsafe-paths -R --check \
            --directory="$relative" "$patch_file" >/dev/null 2>&1); then
        return 0
    fi
    printf 'dex: 补丁没落地 %s\n' "$patch_file" >&2
    exit 1
}
apply_patch "$SRC/cache.patch"
grep -rq DexArchiveCache "$DER/libdexfile" || {
    printf 'dex: cache.patch 没落到 libdexfile\n' >&2
    exit 1
}

dex_compile() {
    compile "$@" -std=gnu++17 -O3 -fno-exceptions -fno-rtti -DNDEBUG -DART_TARGET -DART_TARGET_ANDROID \
        -DART_BASE_ADDRESS=0x70000000 -DBUILDING_LIBART=1 -fvisibility=protected \
        -DART_STACK_OVERFLOW_GAP_arm=8192 -DART_STACK_OVERFLOW_GAP_arm64=8192 \
        -DART_STACK_OVERFLOW_GAP_mips=16384 -DART_STACK_OVERFLOW_GAP_mips64=16384 \
        -DART_STACK_OVERFLOW_GAP_x86=16384 -DART_STACK_OVERFLOW_GAP_x86_64=20480 \
        -I"$DER/libdexfile" -I"$DER/libartbase" -I"$DER/libartpalette" \
        -I"$DER/libartpalette/include" -I"$UP/system/core/base/include" \
        -I"$UP/system/core/libutils/include" -I"$UP/system/core/liblog/include" \
        -I"$UP/system/core/libziparchive/include" -I"$UP/external/zlib" \
        -I"$UP/libnativehelper/include_jni" -I"$SRC"
}

"$PY" "$ART/tools/generate_operator_out.py" "$DER/libdexfile" \
    "$DER/libdexfile/dex/dex_file.h" "$DER/libdexfile/dex/dex_file_layout.h" \
    "$DER/libdexfile/dex/dex_instruction.h" "$DER/libdexfile/dex/dex_instruction_utils.h" \
    "$DER/libdexfile/dex/invoke_type.h" "$DER/libdexfile/dex/method_reference.h" \
    > "$GOUT/generated/operators.cc"

objects=
for name in art_dex_file_loader compact_dex_file compact_offset_table descriptors_names \
            dex_file dex_file_exception_helpers dex_file_layout dex_file_loader \
            dex_file_tracking_registrar dex_file_verifier dex_instruction modifiers primitive \
            signature standard_dex_file type_lookup_table utf ; do
    object="$OBJ/$name.o"
    dex_compile "$DER/libdexfile/dex/$name.cc" "$object"
    objects="$objects $object"
done
dex_compile "$GOUT/generated/operators.cc" "$OBJ/operators.o"
dex_compile "$SRC/DexArchiveCache.cpp" "$OBJ/cache.o"
dex_compile "$SRC/DexClassIndex.cpp" "$OBJ/class-index.o"
objects="$objects $OBJ/operators.o $OBJ/cache.o $OBJ/class-index.o"

crt_so
ld.lld -shared -soname libdexfile.so -z now -z relro -z max-page-size=4096 \
    --hash-style=gnu --eh-frame-hdr --build-id=sha1 --no-undefined --exclude-libs ALL \
    "$OUT/obj/crt/crtbegin_so.o" $objects \
    "$APEXLIB/libartbase.so" "$APEXLIB/libartpalette.so" \
    "$SYSLIB/libbase.so" "$SYSLIB/liblog.so" "$SYSLIB/libcrypto.so" \
    "$LIBCXX" "$LIBM" "$LIBDL" "$LIBC" "$BUILTINS" \
    "$OUT/obj/crt/crtend_so.o" -o "$GOUT/lib/libdexfile.so"

allowed='libartbase.so libartpalette.so libbase.so liblog.so libcrypto.so libc++.so libm.so libc.so libdl.so'
for f in "$GOUT/lib/libdexfile.so"; do
    llvm-readelf -hlWd "$f" > "$f.elf.txt"
    llvm-nm -u "$f" > "$f.undefined.txt"
    for needed in $(llvm-readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'); do
        case " $(printf '%s' "$allowed" | tr '\n' ' ') " in
            *" $needed "*) ;;
            *) printf 'dex: %s 的 NEEDED 里出现 %s，不在允许清单\n' \
                   "$(basename "$f")" "$needed" >&2; exit 1 ;;
        esac
    done
done

reference="$MODULE/prepared/jniLibs/arm64-v8a/liba10vm-guest-libdexfile.so"
if [ -f "$reference" ]; then
    llvm-nm -D --defined-only "$reference" | awk '{print $3}' | sort -u > "$OBJ/reference.syms"
    llvm-nm -D --defined-only "$GOUT/lib/libdexfile.so" | awk '{print $3}' | sort -u > "$OBJ/built.syms"
    if comm -23 "$OBJ/reference.syms" "$OBJ/built.syms" | grep -q .; then
        printf 'dex: libdexfile 缺 prepared 那份导出的符号：\n' >&2
        comm -23 "$OBJ/reference.syms" "$OBJ/built.syms" >&2
        exit 1
    fi
fi

printf 'dex finished\n'
printf '  %s  %s  libdexfile.so\n' "$(wc -c < "$GOUT/lib/libdexfile.so" | tr -d ' ')" \
    "$(sha256sum -t "$GOUT/lib/libdexfile.so" | cut -d ' ' -f 1)"
