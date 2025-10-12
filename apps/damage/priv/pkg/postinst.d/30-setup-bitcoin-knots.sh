#!/bin/sh
# postinst — install Bitcoin Knots from upstream tarball (aarch64)
# This script avoids apt/dpkg calls and is safe inside dpkg maintainer context.
set -eu

log(){ printf '[postinst:knots] %s\n' "$*"; }

# ------- Config -------
URL="https://bitcoinknots.org/files/29.x/29.2.knots20251010/bitcoin-29.2.knots20251010-aarch64-linux-gnu.tar.gz"
ARCH_EXPECT="aarch64"
INSTALL_DIR="/usr/local/bin"
# Optional checksum (export BITCOIN_KNOTS_SHA256=... before dpkg -i to enforce)
SHA256_EXPECT="${BITCOIN_KNOTS_SHA256:-}"

# ------- Helpers -------
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
    tmp="$(mktemp)"; /usr/lib/apt/apt-helper download-file "$URL" "$tmp" TMP >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    cat "$tmp"; rm -f "$tmp"; return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$URL" <<'PY'
import sys,urllib.request
sys.stdout.buffer.write(urllib.request.urlopen(sys.argv[1]).read())
PY
    return
  fi
  log "ERROR: need one of curl/wget/apt-helper/python3 to download."
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing required: $1"; exit 1; }; }

# ------- Pre-flight -------
need_cmd tar
need_cmd uname

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) : ;;
  *)
    log "WARNING: host arch '$ARCH' != expected '$ARCH_EXPECT'. Skipping Knots install."
    exit 0
    ;;
esac

# If the right version is already installed, bail out cleanly
if command -v "${INSTALL_DIR}/bitcoind" >/dev/null 2>&1; then
  CURR="$(${INSTALL_DIR}/bitcoind --version 2>/dev/null || true)"
  echo "$CURR" | grep -q "Knots 29.2" && { log "Bitcoin Knots 29.2 already installed; nothing to do."; exit 0; }
fi

# ------- Download to temp -------
TARBALL="$(mktemp)"
TMPDIR="$(mktemp -d)"
cleanup(){ rm -f "$TARBALL" 2>/dev/null || true; rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

log "Downloading: $URL"
fetch_stdout "$URL" > "$TARBALL"

# Optional checksum verification
if [ -n "$SHA256_EXPECT" ]; then
  need_cmd sha256sum
  SHA_ACTUAL="$(sha256sum "$TARBALL" | awk '{print $1}')"
  if [ "$SHA_ACTUAL" != "$SHA256_EXPECT" ]; then
    log "ERROR: SHA256 mismatch. expected=$SHA256_EXPECT got=$SHA_ACTUAL"
    exit 1
  fi
  log "SHA256 verified."
else
  log "No SHA256 provided; skipping checksum verification."
fi

# ------- Extract & install -------
log "Extracting…"
tar -xzf "$TARBALL" -C "$TMPDIR"

# expected layout: bitcoin-29.2.knots20251010/bin/*
PKGROOT="$(find "$TMPDIR" -maxdepth 1 -type d -name 'bitcoin-*' | head -n1 || true)"
if [ ! -d "$PKGROOT/bin" ]; then
  log "ERROR: could not find extracted bin/ directory"
  exit 1
fi

# List of typical binaries (install what exists)
BINS="bitcoind bitcoin-cli bitcoin-tx bitcoin-wallet bitcoin-util bitcoin-qt"
mkdir -p "$INSTALL_DIR"

for B in $BINS; do
  if [ -f "$PKGROOT/bin/$B" ]; then
    install -m 0755 "$PKGROOT/bin/$B" "$INSTALL_DIR/$B"
    log "Installed $B -> $INSTALL_DIR/$B"
  fi
done

# Optionally install man pages if present
if [ -d "$PKGROOT/share/man" ]; then
  MANBASE="/usr/local/share/man"
  mkdir -p "$MANBASE"
  tar -C "$PKGROOT/share" -cf - man | tar -C "/usr/local/share" -xf -
  log "Man pages installed under /usr/local/share/man"
fi

# Final check
if command -v "${INSTALL_DIR}/bitcoind" >/dev/null 2>&1; then
  log "Installed: $(${INSTALL_DIR}/bitcoind --version | head -n1)"
else
  log "WARNING: bitcoind not found in $INSTALL_DIR after install."
fi

log "Bitcoin Knots installation complete."
exit 0
