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
export LOCALVERSION="__${VNG_KERNEL_NAME:-local}__${SHA}"

BUILD_ARGS=(--build --force)
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
vng "${BUILD_ARGS[@]}"
echo "::endgroup::"

# Keep only what virtme-ng needs to boot:
#   .config, System.map, arch/x86/boot/bzImage, modules.order, .virtme_mods/
echo "::group::Cleaning build tree for caching"
CLEAN_DIR=$(mktemp -d)
cp .config System.map modules.order modules.builtin modules.builtin.modinfo "$CLEAN_DIR/"
mkdir -p "$CLEAN_DIR/arch/x86/boot"
cp arch/x86/boot/bzImage "$CLEAN_DIR/arch/x86/boot/"
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
