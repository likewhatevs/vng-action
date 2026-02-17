#!/usr/bin/env bash
set -euo pipefail

PACKAGES=(
    build-essential flex bison bc
    cpio kmod rsync
    libelf-dev libssl-dev libzstd-dev dwarves
    virtiofsd busybox-static ccache
)

case "$(dpkg --print-architecture)" in
    amd64) PACKAGES+=(qemu-system-x86) ;;
    arm64) PACKAGES+=(qemu-system-arm) ;;
    *)     echo "::error::Unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;;
esac

# Append caller-supplied packages
if [ -n "${VNG_EXTRA_PACKAGES:-}" ]; then
    read -ra extra <<< "$VNG_EXTRA_PACKAGES"
    PACKAGES+=("${extra[@]}")
fi

PIPX_BIN=$(pipx environment --value PIPX_BIN_DIR 2>/dev/null || echo "")
if ! dpkg -s "${PACKAGES[@]}" &>/dev/null || [ ! -x "${PIPX_BIN}/vng" ]; then
    DEPS_LOG=$(mktemp)
    trap 'rm -f "$DEPS_LOG"' EXIT
    install_deps() {
        local apt_flags=(-y --no-upgrade)
        if [ "${VNG_INSTALL_RECOMMENDS:-false}" != "true" ]; then
            apt_flags+=(--no-install-recommends)
        fi
        sudo apt-get update -qq
        sudo apt-get install "${apt_flags[@]}" "${PACKAGES[@]}" virtme-ng
        pipx install --force virtme-ng
    }
    echo "::group::Installing dependencies"
    retries="${VNG_DEPS_RETRIES:-3}"
    dep_timeout="${VNG_DEPS_TIMEOUT:-180}"
    for attempt in $(seq 1 "$retries"); do
        : > "$DEPS_LOG"
        if timeout "$dep_timeout" bash -c "set -e; $(declare -f install_deps; declare -p PACKAGES); install_deps" >"$DEPS_LOG" 2>&1; then
            break
        fi
        echo "::warning::Dependency installation attempt $attempt/$retries failed:"
        cat "$DEPS_LOG"
        if [ "$attempt" -eq "$retries" ]; then
            echo "::error::All $retries attempts failed"
            exit 1
        fi
        sleep 5
    done
    PIPX_BIN=$(pipx environment --value PIPX_BIN_DIR)
    if [ ! -x "$PIPX_BIN/vng" ]; then
        echo "::error::pipx vng not found at $PIPX_BIN/vng"
        exit 1
    fi
    echo "$PIPX_BIN" >> "$GITHUB_PATH"
    echo "::endgroup::"
fi

if [ -e /dev/kvm ] && [ ! -f /etc/udev/rules.d/99-kvm4all.rules ]; then
    echo "::group::Configuring KVM access"
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
        | sudo tee /etc/udev/rules.d/99-kvm4all.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
    echo "KVM access configured (/dev/kvm mode 0666)"
    echo "::endgroup::"
elif [ ! -e /dev/kvm ]; then
    echo "::warning::/dev/kvm not found. VM will use software emulation (slow)."
fi

echo "Installed virtme-ng $("$PIPX_BIN/vng" --version)"
