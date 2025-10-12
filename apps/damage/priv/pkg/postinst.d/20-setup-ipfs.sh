#!/bin/sh
# postinst script for installing IPFS Kubo from twdragon Launchpad PPA
# Compatible with Ubuntu, Linux Mint, Debian variants
# ------------------------------------------
set -eu

# Optional debug mode
[ "${PKG_DEBUG:-}" = "1" ] && set -x

echo "[postinst] Starting IPFS installation..."

# Determine codename (e.g. jammy, noble, bionic, bookworm)
if command -v lsb_release >/dev/null 2>&1; then
    DISTRO_CODENAME=$(lsb_release -cs)
elif [ -f /etc/os-release ]; then
    # Fallback if lsb_release is missing
    . /etc/os-release
    DISTRO_CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-"jammy"}}
else
    echo "[postinst] ERROR: Unable to determine distribution codename."
    exit 1
fi

echo "[postinst] Detected distribution codename: $DISTRO_CODENAME"

# Add the PPA repository if not already present
LIST_FILE="/etc/apt/sources.list.d/ipfs.list"
if ! grep -q "ppa.launchpadcontent.net/twdragon/ipfs" "$LIST_FILE" 2>/dev/null; then
    echo "deb https://ppa.launchpadcontent.net/twdragon/ipfs/ubuntu $DISTRO_CODENAME main" | tee -a "$LIST_FILE"
    echo "deb-src https://ppa.launchpadcontent.net/twdragon/ipfs/ubuntu $DISTRO_CODENAME main" | tee -a "$LIST_FILE"
    echo "[postinst] Repository added."
else
    echo "[postinst] Repository already configured."
fi

# Import GPG key for the repository
# (Keyserver fallback to hkps if default fails)
if ! apt-key list 2>/dev/null | grep -q "twdragon"; then
    echo "[postinst] Importing GPG key..."
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 864E8B8A6F93FAE9 || \
    apt-key adv --keyserver hkps://keyserver.ubuntu.com --recv-keys 864E8B8A6F93FAE9
fi

# Update package list and install ipfs-kubo
echo "[postinst] Updating APT cache..."
apt-get update -y

echo "[postinst] Installing IPFS Kubo..."
DEBIAN_FRONTEND=noninteractive apt-get install -y ipfs-kubo

# Enable and start service if systemd is present
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ipfs || true
    systemctl start ipfs || true
    echo "[postinst] IPFS systemd service enabled and started."
else
    echo "[postinst] Systemd not detected, skipping service enable."
fi

echo "[postinst] IPFS installation completed successfully."
exit 0
