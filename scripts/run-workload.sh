#!/usr/bin/env bash
set -euo pipefail

if [ -z "${VNG_COMMANDS:-}" ]; then
    echo "::error::VNG_COMMANDS is not set"
    exit 1
fi

KERNEL_DIR="${VNG_KERNEL_DIR:?VNG_KERNEL_DIR is not set}"

VNG_ARGS=(--cwd "$GITHUB_WORKSPACE")
if [ -n "${VNG_CPUS:-}" ]; then
    VNG_ARGS+=(--cpus "$VNG_CPUS")
fi
if [ -n "${VNG_MEMORY:-}" ]; then
    VNG_ARGS+=(--memory "$VNG_MEMORY")
fi
if [ -n "${VNG_NETWORK:-}" ]; then
    VNG_ARGS+=(--network "$VNG_NETWORK")
fi

cd "$KERNEL_DIR"
echo "::group::Booting vng VM"
vng "${VNG_ARGS[@]}" -- bash -c "echo '::endgroup::'
echo '::group::Starting workload in vng VM'
echo '::endgroup::'
set -euo pipefail
$VNG_COMMANDS"
