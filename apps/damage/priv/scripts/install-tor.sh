#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-
set -euo pipefail

PORT="${PORT:-4888}"
HS_NAME="${HS_NAME:-damagebdd_dashboard_v3}"
TORRC="${TORRC:-/etc/tor/torrc}"
LOG_FILE="/var/log/damagebdd-tor-install.log"
PREV_LOG="/var/log/damagebdd-tor-install.log.prev"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "[damagebdd] Please run as root:"
  echo "  curl -fsSL https://run.damagebdd.com/scripts/install-tor.sh | sudo bash"
  exit 1
fi

mkdir -p /var/log
if [ -f "$LOG_FILE" ]; then
  mv "$LOG_FILE" "$PREV_LOG"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "DamageBDD Tor Hidden Service Installer"
echo "Timestamp: $(date)"
echo "=============================================="
echo ""

# ---- discover config files we should scan ----
CFG_FILES=()
if [ -f "$TORRC" ]; then
  CFG_FILES+=("$TORRC")
else
  echo "[!] torrc not found at: $TORRC"
  exit 1
fi

# If a torrc.d directory exists, scan it too (common pattern on some setups)
if [ -d /etc/tor/torrc.d ]; then
  while IFS= read -r -d '' f; do
    CFG_FILES+=("$f")
  done < <(find /etc/tor/torrc.d -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null || true)
fi

echo "[*] Scanning Tor config for port collisions on HiddenServicePort ${PORT}..."
# Match lines like:
# HiddenServicePort 4888 127.0.0.1:4888
# (allow leading spaces, tabs, multiple spaces)
if grep -RInE "^[[:space:]]*HiddenServicePort[[:space:]]+${PORT}([[:space:]]+|$)" "${CFG_FILES[@]}" >/dev/null 2>&1; then
  echo "[!] Refusing to proceed: HiddenServicePort ${PORT} is already defined in Tor config:"
  # Print matching lines for operator clarity
  grep -RInE "^[[:space:]]*HiddenServicePort[[:space:]]+${PORT}([[:space:]]+|$)" "${CFG_FILES[@]}" || true
  echo ""
  echo "[!] Choose a different PORT (env var) or remove/modify the existing hidden service."
  echo "    Example:"
  echo "      curl -fsSL https://run.damagebdd.com/scripts/install-tor.sh | sudo PORT=4889 bash"
  exit 2
fi
echo "[✓] No HiddenServicePort ${PORT} collisions found"

# ---- OS detection ----
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
else
  OS_ID="unknown"
  OS_LIKE=""
fi
echo "[*] Detected OS: $OS_ID"

# ---- install tor ----
if command -v tor >/dev/null 2>&1; then
  echo "[*] Tor already installed"
else
  echo "[*] Installing Tor..."
  case "$OS_ID" in
    debian|ubuntu|linuxmint|pop)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y tor
      ;;
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm tor
      ;;
    *)
      if echo "$OS_LIKE" | grep -qiE 'debian|ubuntu'; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y tor
      elif echo "$OS_LIKE" | grep -qiE 'arch'; then
        pacman -Sy --noconfirm tor
      else
        echo "[!] Unsupported distro. Install Tor manually, then rerun."
        exit 1
      fi
      ;;
  esac
fi

# ---- enable tor service ----
if systemctl list-unit-files | grep -q '^tor\.service'; then
  systemctl enable --now tor.service
  TOR_SERVICE="tor.service"
elif systemctl list-unit-files | grep -q '^tor@default\.service'; then
  systemctl enable --now tor@default.service
  TOR_SERVICE="tor@default.service"
else
  TOR_SERVICE="tor"
  systemctl start tor || true
fi
echo "[*] Using Tor service: $TOR_SERVICE"

# ---- set hidden service dir ----
HS_DIR="/var/lib/tor/${HS_NAME}"

# Add block only if HS_NAME not already referenced
if ! grep -q "$HS_NAME" "$TORRC"; then
  echo "[*] Adding hidden service to $TORRC"
  cat >> "$TORRC" <<EOF

# DamageBDD dashboard hidden service
HiddenServiceDir ${HS_DIR}
HiddenServiceVersion 3
HiddenServicePort ${PORT} 127.0.0.1:${PORT}
EOF
else
  echo "[*] Hidden service already referenced in torrc (by name). Not duplicating."
fi

# ---- permissions ----
if id debian-tor >/dev/null 2>&1; then
  TOR_USER="debian-tor"
  TOR_GROUP="debian-tor"
elif id tor >/dev/null 2>&1; then
  TOR_USER="tor"
  TOR_GROUP="tor"
else
  TOR_USER="tor"
  TOR_GROUP="tor"
fi

mkdir -p "$HS_DIR"
chown -R "$TOR_USER:$TOR_GROUP" "$HS_DIR"
chmod 700 "$HS_DIR"

# ---- restart tor ----
echo "[*] Restarting Tor..."
systemctl restart "$TOR_SERVICE"

# ---- wait for onion ----
HOSTNAME_FILE="${HS_DIR}/hostname"
echo "[*] Waiting for onion address..."
for i in {1..25}; do
  if [ -f "$HOSTNAME_FILE" ]; then
    ONION="$(cat "$HOSTNAME_FILE")"
    echo ""
    echo "=============================================="
    echo " DamageBDD Onion Address"
    echo "----------------------------------------------"
    echo "$ONION"
    echo "=============================================="
    echo ""
    echo "Access via Tor Browser:"
    echo "  http://${ONION}:${PORT}/"
    echo ""
    echo "[✓] Installation complete"
    echo "[✓] Log saved to $LOG_FILE"
    exit 0
  fi
  sleep 1
done

echo "[!] Onion hostname not generated yet."
echo "Check logs:"
echo "  journalctl -u $TOR_SERVICE -f"
exit 1
