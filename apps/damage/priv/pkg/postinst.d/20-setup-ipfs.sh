#!/bin/sh
# postinst — add ppa:twdragon/ipfs and install ipfs-kubo (minimal)
set -eu

log(){ printf '[postinst:ipfs-install] %s\n' "$*"; }

# --- Fetch helper: curl || wget || apt-helper || python3 ---
fetch_stdout() {
  URL="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$URL"
    return
  fi
  if [ -x /usr/lib/apt/apt-helper ]; then
    # writes to a temp file, then cat it
    tmp="$(mktemp)"
    /usr/lib/apt/apt-helper download-file "$URL" "$tmp" TMPKEY >/dev/null 2>&1 || {
      rm -f "$tmp"; return 1; }
    cat "$tmp"
    rm -f "$tmp"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$URL" <<'PY'
import sys,urllib.request
url=sys.argv[1]
sys.stdout.flush()
sys.stdout.buffer.write(urllib.request.urlopen(url).read())
PY
    return
  fi
  log "ERROR: need one of curl/wget/apt-helper/python3 to fetch the key."
  exit 1
}

# --- Determine Ubuntu codename (works on Mint/Debian) ---
DISTRO_CODENAME=""
if command -v lsb_release >/dev/null 2>&1; then
  DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
fi
if [ -r /etc/os-release ]; then
  . /etc/os-release
  [ -n "${UBUNTU_CODENAME:-}" ] && DISTRO_CODENAME="$UBUNTU_CODENAME"
  [ -z "${DISTRO_CODENAME:-}" ] && [ -n "${VERSION_CODENAME:-}" ] && DISTRO_CODENAME="$VERSION_CODENAME"
fi
DISTRO_CODENAME="${DISTRO_CODENAME:-jammy}"
log "Using codename: $DISTRO_CODENAME"

KEYDIR="/etc/apt/keyrings"
KEYFILE="$KEYDIR/twdragon-ipfs.gpg"
LISTFILE="/etc/apt/sources.list.d/ipfs-twdragon.list"
KEYID="864E8B8A6F93FAE9"
REPO_BASE="https://ppa.launchpadcontent.net/twdragon/ipfs/ubuntu"

mkdir -p "$KEYDIR"; chmod 0755 "$KEYDIR"

# We need gpg to dearmor; fail with a clear message if absent
if ! command -v gpg >/dev/null 2>&1; then
  log "ERROR: 'gpg' (gnupg) is required to install repo key. Install 'gnupg' and re-run."
  exit 1
fi

# Install key if missing
if [ ! -s "$KEYFILE" ]; then
  log "Fetching and installing PPA key $KEYID…"
  fetch_stdout "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${KEYID}" \
    | gpg --dearmor > "$KEYFILE"
  chmod 0644 "$KEYFILE"
else
  log "Keyring already present: $KEYFILE"
fi

# Configure source list (idempotent)
REPO_LINE="deb [signed-by=$KEYFILE] $REPO_BASE $DISTRO_CODENAME main"
REPO_SRC_LINE="deb-src [signed-by=$KEYFILE] $REPO_BASE $DISTRO_CODENAME main"
if [ ! -f "$LISTFILE" ] || ! grep -qF "$REPO_LINE" "$LISTFILE"; then
  log "Writing APT source: $LISTFILE"
  {
    echo "$REPO_LINE"
    echo "$REPO_SRC_LINE"
  } > "$LISTFILE"
else
  log "APT source already configured."
fi

log "apt-get update…"
apt-get update -y

log "Installing ipfs-kubo…"
DEBIAN_FRONTEND=noninteractive apt-get install -y ipfs-kubo

log "Done."
exit 0
