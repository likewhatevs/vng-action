#!/usr/bin/env bash
set -euo pipefail

if [ -z "${VNG_KERNEL_URL:-}" ]; then
    echo "::error::VNG_KERNEL_URL is not set"
    exit 1
fi

if [ -z "${VNG_KERNEL_TAG:-}" ]; then
    echo "::error::VNG_KERNEL_TAG is not set"
    exit 1
fi

KERNEL_DIR="${VNG_KERNEL_DIR:?VNG_KERNEL_DIR is not set}"

echo "::group::Cloning kernel $VNG_KERNEL_TAG from $VNG_KERNEL_URL"
rm -rf "$KERNEL_DIR"
git clone --depth 1 --branch "$VNG_KERNEL_TAG" "$VNG_KERNEL_URL" "$KERNEL_DIR"
echo "::endgroup::"

cd "$KERNEL_DIR"

SHA=$(git rev-parse --short=12 HEAD)

BUILD_ARGS=(--build --force)
MAKE_VARS=(LOCALVERSION="__${VNG_KERNEL_NAME:-local}__${SHA}")
if [ -n "${VNG_LLVM:-}" ]; then
    MAKE_VARS+=(LLVM="$VNG_LLVM")
fi
if [ -n "${VNG_CC:-}" ]; then
    MAKE_VARS+=(CC="$VNG_CC" HOSTCC="$VNG_CC")
fi
if [ "${VNG_CCACHE:-}" = "true" ] && command -v ccache &>/dev/null; then
    export CCACHE_DIR="$HOME/.cache/ccache"
    export KBUILD_BUILD_TIMESTAMP="0"
    export KBUILD_BUILD_USER="vng"
    export KBUILD_BUILD_HOST="vng"
    ccache --max-size 5G
    ccache --set-config depend_mode=true
    # Determine the compiler to wrap — explicit CC, or clang if LLVM, else gcc
    if [ -n "${VNG_CC:-}" ]; then
        _CC="$VNG_CC"
    elif [ -n "${VNG_LLVM:-}" ]; then
        if [ "$VNG_LLVM" = "1" ]; then _CC="clang"; else _CC="clang${VNG_LLVM}"; fi
    else
        _CC="gcc"
    fi
    # Wrapper script avoids spaces in CC value (vng/make can't handle CC="ccache gcc")
    CCACHE_WRAPPER=$(mktemp /tmp/ccache-cc-XXXXXX)
    printf '#!/bin/sh\nexec ccache %s "$@"\n' "$_CC" > "$CCACHE_WRAPPER"
    chmod +x "$CCACHE_WRAPPER"
    MAKE_VARS+=(CC="$CCACHE_WRAPPER" HOSTCC="$CCACHE_WRAPPER")
fi
if [ -n "${VNG_KCONFIG:-}" ]; then
    KCONFIG_PATH="$GITHUB_WORKSPACE/$VNG_KCONFIG"
    if [ ! -f "$KCONFIG_PATH" ]; then
        echo "::error::kconfig file not found: '$VNG_KCONFIG' (resolved to '$KCONFIG_PATH'). Ensure the path is relative to your repository root."
        exit 1
    fi
    echo "Using kconfig fragment: $VNG_KCONFIG"
    BUILD_ARGS+=(--config "$KCONFIG_PATH")
fi
echo "::group::Building kernel with virtme-ng"
vng "${BUILD_ARGS[@]}" "${MAKE_VARS[@]}"
echo "::endgroup::"

# vng --force overrides --config fragments for DEBUG_INFO, so patch the
# config after generation and do an incremental rebuild if needed.
if [ "${VNG_VMLINUX_H:-}" = "true" ] && ! grep -q 'CONFIG_DEBUG_INFO_BTF=y' .config; then
    echo "::group::Rebuilding with CONFIG_DEBUG_INFO_BTF=y"
    scripts/config --enable DEBUG_INFO \
                   --disable DEBUG_INFO_NONE \
                   --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
                   --enable DEBUG_INFO_BTF
    make olddefconfig "${MAKE_VARS[@]}" -s
    if ! grep -q 'CONFIG_DEBUG_INFO_BTF=y' .config; then
        echo "::warning::CONFIG_DEBUG_INFO_BTF=y could not be enabled (missing dependencies?)"
        grep 'CONFIG_DEBUG_INFO' .config || true
    else
        make -j"$(nproc)" "${MAKE_VARS[@]}" -s
        if readelf -S vmlinux 2>/dev/null | grep -q '\.BTF'; then
            echo "vmlinux .BTF section present"
        else
            echo "::warning::vmlinux rebuilt but .BTF section missing (pahole issue?)"
        fi
    fi
    echo "::endgroup::"
fi

# Generate vmlinux.h for BPF applications (must happen before tree cleanup)
if [ "${VNG_VMLINUX_H:-}" = "true" ] && [ -f vmlinux ]; then
    echo "::group::Generating vmlinux.h"
    BPFTOOL=""
    # Build standalone bpftool (avoids kernel tree LLVM skeleton deps)
    if [ ! -x /tmp/bpftool/src/bpftool ]; then
        if git clone --depth 1 --recurse-submodules https://github.com/libbpf/bpftool /tmp/bpftool 2>/dev/null \
            && make -C /tmp/bpftool/src -j"$(nproc)" -s LLVM_STRIP=/bin/true 2>/tmp/bpftool-build.log; then
            BPFTOOL="/tmp/bpftool/src/bpftool"
        else
            echo "::warning::Failed to build standalone bpftool:"
            cat /tmp/bpftool-build.log 2>/dev/null || true
        fi
    else
        BPFTOOL="/tmp/bpftool/src/bpftool"
    fi
    if [ -z "$BPFTOOL" ]; then
        echo "::warning::bpftool not available, skipping vmlinux.h generation"
    elif "$BPFTOOL" btf dump file vmlinux format c > vmlinux.h; then
        echo "Generated vmlinux.h ($(wc -c < vmlinux.h) bytes)"
    else
        echo "::warning::vmlinux lacks BTF info (ensure CONFIG_DEBUG_INFO_BTF=y)"
        rm -f vmlinux.h
    fi
    echo "::endgroup::"
fi

# Keep only what virtme-ng needs to boot:
#   .config, System.map, boot image, modules.order, .virtme_mods/
echo "::group::Cleaning build tree for caching"
CLEAN_DIR=$(mktemp -d)
cp -p .config System.map modules.order modules.builtin modules.builtin.modinfo "$CLEAN_DIR/"
BOOT_IMAGE=$(make -s "${MAKE_VARS[@]}" image_name)
mkdir -p "$CLEAN_DIR/$(dirname "$BOOT_IMAGE")"
cp "$BOOT_IMAGE" "$CLEAN_DIR/$BOOT_IMAGE"
# vng may look for a different image than make image_name reports (e.g., arm64:
# make reports Image.gz but vng needs the uncompressed Image). Copy all boot
# images from the same directory so vng can find what it needs.
BOOT_DIR=$(dirname "$BOOT_IMAGE")
for img in "$BOOT_DIR"/{Image,Image.gz,bzImage}; do
    [ -f "$img" ] && [ ! -f "$CLEAN_DIR/$img" ] && cp "$img" "$CLEAN_DIR/$img"
done
if [ -d .virtme_mods ]; then
    cp -a .virtme_mods "$CLEAN_DIR/"
    # Remove build/source symlinks that point back into the full tree;
    # they'll dangle after cleanup and aren't needed to boot.
    rm -f "$CLEAN_DIR"/.virtme_mods/lib/modules/*/build \
          "$CLEAN_DIR"/.virtme_mods/lib/modules/*/source
fi
[ -f vmlinux.h ] && cp vmlinux.h "$CLEAN_DIR/"
# Preserve .ko files at their build tree locations (depmod scans these via build symlink)
find . -name '*.ko' -type f | while read -r ko; do
    mkdir -p "$CLEAN_DIR/$(dirname "$ko")"
    cp "$ko" "$CLEAN_DIR/$ko"
done

cd /
rm -rf "$KERNEL_DIR"
mv "$CLEAN_DIR" "$KERNEL_DIR"
echo "::endgroup::"

echo "Kernel build complete"
