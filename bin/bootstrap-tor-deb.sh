#!/bin/sh
set -eu

# Standalone pre-install helper for Debian/Ubuntu hosts.
# Run this BEFORE installing the Damage .deb when you want the Tor Project
# package source. Do not call it from a Debian maintainer script.

TOR_KEY_FPR=A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
TOR_KEY_URL=https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc
TOR_REPO=https://deb.torproject.org/torproject.org/
TOR_SOURCE=/etc/apt/sources.list.d/tor.sources
TOR_KEYRING=/usr/share/keyrings/deb.torproject.org-keyring.gpg

log() {
    printf 'damage-tor-bootstrap: %s\n' "$*"
}

if command -v tor >/dev/null 2>&1; then
    log "Tor already installed: $(tor --version 2>/dev/null | head -n 1 || true)"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || {
    printf 'damage-tor-bootstrap: run as root\n' >&2
    exit 1
}
command -v apt-get >/dev/null 2>&1 || {
    printf 'damage-tor-bootstrap: apt-get not found; this helper is Debian/Ubuntu only\n' >&2
    exit 1
}
command -v dpkg >/dev/null 2>&1 || {
    printf 'damage-tor-bootstrap: dpkg not found; this helper is Debian/Ubuntu only\n' >&2
    exit 1
}

# shellcheck disable=SC1091
. /etc/os-release
CODENAME=${VERSION_CODENAME:-}
ARCH=$(dpkg --print-architecture)

install_distro_tor() {
    log "Installing Tor from configured Debian/Ubuntu repositories"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y tor
}

# Tor Project currently publishes Debian/Ubuntu binaries for amd64 and arm64.
# Prefer that source on those architectures when the distribution codename is
# available. If it cannot be configured, fall back cleanly to the distro repo.
case "$ARCH" in
    amd64|arm64) ;;
    *)
        log "Tor Project APT repository does not publish $ARCH; using distro package"
        install_distro_tor
        exit 0
        ;;
esac

case "${ID:-}" in
    debian|ubuntu) ;;
    *)
        log "${ID:-unknown} is not a supported Tor Project Debian/Ubuntu target; using distro package"
        install_distro_tor
        exit 0
        ;;
esac

if [ -z "$CODENAME" ]; then
    log "VERSION_CODENAME is unavailable; using distro package"
    install_distro_tor
    exit 0
fi

log "Configuring official Tor Project APT repository for $ID/$CODENAME ($ARCH)"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https ca-certificates curl gnupg

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM
KEY_ASC="$TMPDIR/tor.asc"
KEY_GPG="$TMPDIR/tor.gpg"

if ! curl -fsSL "$TOR_KEY_URL" -o "$KEY_ASC"; then
    log "Unable to download Tor Project signing key; falling back to distro package"
    install_distro_tor
    exit 0
fi

FPR=$(gpg --batch --show-keys --with-colons "$KEY_ASC" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print $10; exit}')
if [ "$FPR" != "$TOR_KEY_FPR" ]; then
    printf 'damage-tor-bootstrap: Tor Project signing-key fingerprint mismatch: %s\n' "$FPR" >&2
    exit 1
fi

gpg --batch --yes --dearmor --output "$KEY_GPG" "$KEY_ASC"
install -o root -g root -m 0644 "$KEY_GPG" "$TOR_KEYRING"

cat > "$TOR_SOURCE" <<EOF2
Types: deb
URIs: $TOR_REPO
Suites: $CODENAME
Components: main
Architectures: $ARCH
Signed-By: $TOR_KEYRING
EOF2

if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tor deb.torproject.org-keyring; then
    log "Installed Tor from the official Tor Project repository"
    exit 0
fi

log "Tor Project repository is unavailable for this release; reverting to distro package"
rm -f "$TOR_SOURCE"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tor
