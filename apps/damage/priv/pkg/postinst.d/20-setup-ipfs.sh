#!/usr/bin/env bash
set -euo pipefail

IPFS_VERSION="v0.38.1"
IPFS_TARBALL="kubo_${IPFS_VERSION}_linux-amd64.tar.gz"
IPFS_URL="https://github.com/ipfs/kubo/releases/download/${IPFS_VERSION}/${IPFS_TARBALL}"

log() { printf '[ipfs-install] %s\n' "$*"; }

# ensure curl or wget is available
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$IPFS_URL" -o "$IPFS_TARBALL"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$IPFS_URL" -O "$IPFS_TARBALL"
  else
    log "Error: curl or wget required."
    exit 1
  fi
}

# download tarball
log "Downloading IPFS Kubo ${IPFS_VERSION}…"
fetch

# extract
log "Extracting ${IPFS_TARBALL}…"
tar -xzf "$IPFS_TARBALL"

# install binary
cd kubo
log "Running install script…"
sudo bash install.sh

# verify installation
log "Installed version: $(ipfs --version)"
ipfs config Addresses.Gateway /ip4/127.0.0.1/tcp/8082

# cleanup
cd ..
rm -rf kubo "$IPFS_TARBALL"

log "✅ IPFS Kubo ${IPFS_VERSION} installation completed."
