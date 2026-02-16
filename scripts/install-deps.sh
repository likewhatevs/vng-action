#!/usr/bin/env bash
set -euo pipefail

PACKAGES=(
    build-essential gcc-multilib flex bison bc
    cpio kmod pkg-config rsync
    libelf-dev libssl-dev libzstd-dev dwarves
    linux-headers-generic linux-tools-common linux-tools-generic
    qemu-system-x86 busybox-static ccache
)

if dpkg -s "${PACKAGES[@]}" &>/dev/null && command -v vng &>/dev/null; then
    echo "Dependencies already installed, skipping"
    exit 0
fi

echo "::group::Installing dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq "${PACKAGES[@]}" virtme-ng
echo "::endgroup::"

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

echo "Installed virtme-ng $(vng --version)"
