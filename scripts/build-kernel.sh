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
if [ -n "${VNG_ARCH:-}" ]; then
    MAKE_VARS+=(ARCH="$VNG_ARCH")
fi
if [ -n "${VNG_CROSS_COMPILE:-}" ]; then
    MAKE_VARS+=(CROSS_COMPILE="$VNG_CROSS_COMPILE")
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

# Keep only what virtme-ng needs to boot:
#   .config, System.map, boot image, modules.order, .virtme_mods/
echo "::group::Cleaning build tree for caching"
CLEAN_DIR=$(mktemp -d)
cp .config System.map modules.order modules.builtin modules.builtin.modinfo "$CLEAN_DIR/"
BOOT_IMAGE=$(make -s "${MAKE_VARS[@]}" image_name)
mkdir -p "$CLEAN_DIR/$(dirname "$BOOT_IMAGE")"
cp "$BOOT_IMAGE" "$CLEAN_DIR/$BOOT_IMAGE"
if [ -d .virtme_mods ]; then
    cp -rL .virtme_mods "$CLEAN_DIR/"
fi
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
