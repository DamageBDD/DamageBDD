#!/usr/bin/env bash
# install-ipfs-kubo.sh — Install IPFS Kubo from ppa:twdragon/ipfs using keyrings + signed-by
# Works on Ubuntu, Linux Mint, and Debian-based systems with APT.
set -euo pipefail

log() { printf '[ipfs-install] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { log "Missing required command: $1"; exit 1; }; }

need curl
need gpg
need tee
need awk
need sed

# --- Determine Ubuntu codename (Mint exposes UBUNTU_CODENAME) ---
detect_codename() {
  local codename=""
  if command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
      codename="$UBUNTU_CODENAME"
    elif [[ -z "$codename" && -n "${VERSION_CODENAME:-}" ]]; then
      codename="$VERSION_CODENAME"
    fi
  fi
  echo "${codename:-jammy}"
}

CODENAME="$(detect_codename)"
log "Using codename: ${CODENAME}"

# --- Prepare keyring and repo list ---
KEYDIR="/etc/apt/keyrings"
KEYFILE="${KEYDIR}/twdragon-ipfs.gpg"
LISTFILE="/etc/apt/sources.list.d/ipfs-twdragon.list"
KEYID="864E8B8A6F93FAE9"  # Launchpad key for ppa:twdragon/ipfs

sudo install -d -m 0755 "$KEYDIR"

# Fetch & install the repo signing key (ASCII -> GPG keyring)
if [[ ! -s "$KEYFILE" ]]; then
  log "Fetching PPA signing key (${KEYID})…"
  # Pull via HTTPS and dearmor into a keyring file
  curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${KEYID}" \
    | gpg --dearmor | sudo tee "$KEYFILE" >/dev/null
  sudo chmod 0644 "$KEYFILE"
else
  log "Keyring already present at $KEYFILE"
fi

# Write sources.list entry (idempotent)
REPO_LINE="deb [signed-by=${KEYFILE}] https://ppa.launchpadcontent.net/twdragon/ipfs/ubuntu ${CODENAME} main"
REPO_SRC_LINE="deb-src [signed-by=${KEYFILE}] https://ppa.launchpadcontent.net/twdragon/ipfs/ubuntu ${CODENAME} main"

if [[ ! -f "$LISTFILE" ]] || ! grep -qF "$REPO_LINE" "$LISTFILE"; then
  log "Configuring APT source at ${LISTFILE}"
  printf '%s\n%s\n' "$REPO_LINE" "$REPO_SRC_LINE" | sudo tee "$LISTFILE" >/dev/null
else
  log "APT source already configured."
fi

# Update cache & install ipfs-kubo
log "Updating APT cache…"
sudo apt-get update -y

log "Installing ipfs-kubo…"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ipfs-kubo

log "Done. IPFS Kubo is installed."

