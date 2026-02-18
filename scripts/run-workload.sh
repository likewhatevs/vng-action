#!/usr/bin/env bash
set -euo pipefail

if [ -z "${VNG_COMMANDS:-}" ]; then
    echo "::error::VNG_COMMANDS is not set"
    exit 1
fi

KERNEL_DIR="${VNG_KERNEL_DIR:?VNG_KERNEL_DIR is not set}"

: "${VNG_CPUS:=$(nproc)}"
if [ -z "${VNG_MEMORY:-}" ]; then
    VNG_MEMORY=$(awk '/MemTotal/ { printf "%d", $2 * 0.9 / 1024 }' /proc/meminfo)
    # ARM64 without KVM uses TCG+GICv2 which limits addressing to 32 bits
    if [ "$(uname -m)" = "aarch64" ] && [ "$VNG_MEMORY" -gt 4096 ]; then
        VNG_MEMORY=4096
    fi
    VNG_MEMORY="${VNG_MEMORY}M"
fi

# -cpu host requires KVM; drop it on ARM64 where runners may lack /dev/kvm
if [ "$(uname -m)" = "aarch64" ]; then
    VNG_QEMU_OPTS="${VNG_QEMU_OPTS//-cpu host/}"
    VNG_QEMU_OPTS="${VNG_QEMU_OPTS## }"
fi

VNG_ARGS=(--cwd "$GITHUB_WORKSPACE" --rwdir "$GITHUB_WORKSPACE"
          --pin --cpus "$VNG_CPUS" --memory "$VNG_MEMORY"
          --disable-monitor)
if [ -n "${VNG_NETWORK:-}" ]; then
    VNG_ARGS+=(--network "$VNG_NETWORK")
fi
if [ "${VNG_VERBOSE:-}" = "true" ]; then
    VNG_ARGS+=(--verbose)
fi
if [ -n "${VNG_QEMU_OPTS:-}" ]; then
    VNG_ARGS+=("--qemu-opts=$VNG_QEMU_OPTS")
fi
if [ -n "${VNG_APPEND:-}" ]; then
    VNG_ARGS+=(--append "$VNG_APPEND")
fi
for _dir in ${VNG_EXTRA_RWDIRS:-}; do
    _dir="${_dir/#\~/$HOME}"
    [ -d "$_dir" ] && VNG_ARGS+=(--rwdir "$_dir")
done

# Mount GitHub Actions file command directories so workloads can write to
# $GITHUB_STEP_SUMMARY, $GITHUB_OUTPUT, $GITHUB_ENV, $GITHUB_PATH from the VM.
declare -A _rwdirs
for var in GITHUB_STEP_SUMMARY GITHUB_OUTPUT GITHUB_ENV GITHUB_PATH; do
    if [ -n "${!var:-}" ]; then
        dir=$(dirname "${!var}")
        if [ -d "$dir" ] && [ -z "${_rwdirs[$dir]:-}" ]; then
            VNG_ARGS+=(--rwdir "$dir")
            _rwdirs[$dir]=1
        fi
    fi
done

# Write the workload script to a file on the shared filesystem so it doesn't
# bloat the kernel command line (COMMAND_LINE_SIZE is 2048 on x86).
SCRIPT=$(mktemp "${RUNNER_TEMP:-/tmp}/.vng-workload-XXXXXX.sh")
trap 'rm -f "$SCRIPT"' EXIT
{
    echo '#!/bin/bash'
    echo 'set -eo pipefail'
    echo "trap 'sync' EXIT"
    export -p
    cat <<__VNG_WORKLOAD_EOF__
# Remove build/source symlinks that virtme-prep-kdir-mods may recreate;
# they point back into the kernel tree and create filesystem loops.
rm -f '$KERNEL_DIR'/.virtme_mods/lib/modules/*/build \
      '$KERNEL_DIR'/.virtme_mods/lib/modules/*/source \
      '$KERNEL_DIR'/.virtme_mods/usr/lib/modules/*/build \
      '$KERNEL_DIR'/.virtme_mods/usr/lib/modules/*/source \
      '$KERNEL_DIR'/.virtme_mods/usr/usr
echo '::endgroup::'
echo '::group::Starting workload in vng VM'
echo '::endgroup::'
$VNG_COMMANDS
__VNG_WORKLOAD_EOF__
} > "$SCRIPT"
chmod +x "$SCRIPT"

cd "$KERNEL_DIR"
echo "::group::Booting vng VM"
VNG_CMD=(sudo env "PATH=$PATH" vng "${VNG_ARGS[@]}" --exec "bash '$SCRIPT'")
if [ "${VNG_RUN_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    timeout --foreground "$VNG_RUN_TIMEOUT" "${VNG_CMD[@]}"
else
    "${VNG_CMD[@]}"
fi
