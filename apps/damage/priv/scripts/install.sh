#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-
set -euo pipefail

# DamageBDD multi-distro installer (Ubuntu/Mint/Arch)
#
# Usage:
#   curl -fsSL https://run.damagebdd.com/scripts/install.sh | sudo bash
#
# Optional overrides:
#   DAMAGEBDD_VERSION=1.2.3
#   DAMAGEBDD_SECRET_BYTES=32
#
# Where to host packages (defaults below):
#   DEB_URL="https://run.damagebdd.com/packages/deb/damagebdd_${VERSION}_amd64.deb"
#   ARCH_URL="https://run.damagebdd.com/packages/arch/damagebdd-${VERSION}-1-x86_64.pkg.tar.zst"
#
# Secrets:
#   /etc/damagebdd/secret.env (root-only)
#
# Logs:
#   /var/log/damagebdd-install.log
#   /var/log/damagebdd-install.log.prev

VERSION="${DAMAGEBDD_VERSION:-latest}"
SECRET_BYTES="${DAMAGEBDD_SECRET_BYTES:-32}"

LOG_FILE="/var/log/damagebdd-install.log"
PREV_LOG="/var/log/damagebdd-install.log.prev"

ETC_DIR="/etc/damage"
CONFIG_FILE="${ETC_DIR}/damage.conf"
SECRET_FILE="${ETC_DIR}/secret.env"

# NOTE: Change these to match your actual hosted artifact naming.
DEB_URL_DEFAULT="https://run.damagebdd.com/packages/deb/damagebdd_${VERSION}_amd64.deb"
ARCH_URL_DEFAULT="https://run.damagebdd.com/packages/arch/damagebdd-${VERSION}-1-x86_64.pkg.tar.zst"

DEB_URL="${DAMAGEBDD_DEB_URL:-$DEB_URL_DEFAULT}"
ARCH_URL="${DAMAGEBDD_ARCH_URL:-$ARCH_URL_DEFAULT}"

log()  { printf "\033[1;32m[damagebdd]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[damagebdd]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[damagebdd]\033[0m %s\n" "$*"; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Please run as root:"
    echo "  curl -fsSL https://run.damagebdd.com/scripts/install-damagebdd.sh | sudo bash"
    exit 1
  fi
}

setup_logging() {
  mkdir -p /var/log
  if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "$PREV_LOG"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1

  echo "=============================================="
  echo "DamageBDD Installer"
  echo "Timestamp: $(date)"
  echo "=============================================="
  echo ""
}

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"
    OS_LIKE=""
  fi
  ARCH="$(uname -m)"
}

require_arch_x86_64() {
  # You can extend this later for arm64 builds.
  if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    warn "Detected arch: $ARCH"
    warn "This installer assumes x86_64 artifacts. If you have arm64 builds, add them and extend the script."
  fi
}

ensure_tools_debian() {
  log "Installing prerequisites (Debian/Ubuntu/Mint)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg openssl
}

ensure_tools_arch() {
  log "Installing prerequisites (Arch)..."
  pacman -Sy --noconfirm ca-certificates curl openssl
}

download() {
  local url="$1"
  local out="$2"
  log "Downloading: $url"
  curl -fL --retry 3 --retry-delay 1 -o "$out" "$url"
}

install_deb() {
  ensure_tools_debian
  local tmp="/tmp/damagebdd.deb"
  download "$DEB_URL" "$tmp"

  log "Installing .deb..."
  dpkg -i "$tmp" || true
  # Fix deps if needed
  apt-get -f install -y

  rm -f "$tmp"
}

install_arch_pkg() {
  ensure_tools_arch
  local tmp="/tmp/damagebdd.pkg.tar.zst"
  download "$ARCH_URL" "$tmp"

  log "Installing Arch package..."
  pacman -U --noconfirm "$tmp"

  rm -f "$tmp"
}

generate_secret() {
  # Outputs a URL-safe-ish token. Store once; print once.
  # Prefer openssl; fallback to /dev/urandom.
  if command -v openssl >/dev/null 2>&1; then
    # base64, strip newlines and non-url-friendly chars lightly
    openssl rand -base64 "$SECRET_BYTES" | tr -d '\n' | tr '+/' '-_' | tr -d '='
  else
    dd if=/dev/urandom bs=1 count=$((SECRET_BYTES)) 2>/dev/null | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
  fi
}

write_config_file() {
  mkdir -p "$ETC_DIR"
  chmod 700 "$ETC_DIR"

  if [ -f "$CONFIG_FILE" ]; then
    warn "Config already exists: $CONFIG_FILE"
    warn "Not overwriting existing configuration."
    return 0
  fi

  local secret
  secret="$(generate_secret)"

  umask 077
  cat > "$CONFIG_FILE" <<EOF
% DamageBDD Configuration
% Generated: $(date -Is)

[
    {
        damage,
        [
            {run_user, "damage"},
            {ip, {127, 0, 0, 1}},
            %{ip, {0, 0, 0, 0}},
            {port, 4888}
        ]
    }
]
EOF

  chmod 600 "$CONFIG_FILE"

  echo ""
  echo "=============================================="
  echo " DamageBDD Secret (PRINTED ONCE)"
  echo "----------------------------------------------"
  echo "$secret"
  echo "=============================================="
  echo ""
  log "Initialized config at: $CONFIG_FILE (root-only)"
  echo ""

  cat <<'EOF'
Store this secret now in your password manager.

pass:
  pass insert damagebdd/secret

Bitwarden CLI:
  bw create item '{"type":1,"name":"damagebdd secret","notes":"<paste secret here>"}'

1Password CLI:
  op item create --category=login --title="damagebdd secret" password="<paste secret here>"

EOF
}

post_install_notes() {
  log "Install complete."
  log "Log saved to: $LOG_FILE"
  echo ""
  echo "Next:"
  echo "  - Wire your service to load: $SECRET_FILE"
  echo "  - Keep your dashboard bound to 127.0.0.1 where appropriate"
  echo ""
}

main() {
  need_root
  setup_logging
  detect_os
  require_arch_x86_64

  log "OS detected: $OS_ID (like: $OS_LIKE) arch: $ARCH"
  log "Version: $VERSION"
  log "DEB_URL:  $DEB_URL"
  log "ARCH_URL: $ARCH_URL"

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
      install_deb
      ;;
    arch|manjaro|endeavouros)
      install_arch_pkg
      ;;
    *)
      if echo "$OS_LIKE" | grep -qiE 'debian|ubuntu'; then
        install_deb
      elif echo "$OS_LIKE" | grep -qiE 'arch'; then
        install_arch_pkg
      else
        err "Unsupported distro. Add an installer branch for your OS."
        exit 1
      fi
      ;;
  esac

  write_config_file
  post_install_notes
}

main "$@"
