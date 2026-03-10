#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-
set -euo pipefail

# ------------------------------------------------------------
# Deterministic installer for:
# clightning-v25.12.1-Ubuntu-24.04-amd64.tar.xz
#
# Source:
# https://github.com/ElementsProject/lightning/releases/download/v25.12.1/clightning-v25.12.1-Ubuntu-24.04-amd64.tar.xz
#
# Usage:
#   sudo ./install-cln-v25.12.1-ubuntu-24.04.sh --sha256 <64hex>
#
# ------------------------------------------------------------

VERSION="v25.12.1"
FILENAME="clightning-${VERSION}-Ubuntu-24.04-amd64.tar.xz"
URL="https://github.com/ElementsProject/lightning/releases/download/${VERSION}/${FILENAME}"

LIGHTNING_USER="lightning"
LIGHTNING_GROUP="lightning"
LIGHTNING_DIR="/var/lib/lightning"
PORT="9735"
NETWORK="bitcoin"

TMP="/tmp/cln-install"
INSTALL_BASE="/opt/core-lightning"

log() { echo "[CLN] $*" ; }
die() { echo "[CLN] ERROR: $*" ; exit 1 ; }

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."
}

parse_args() {
  SHA256=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256)
        SHA256="$2"
        shift 2
        ;;
      *)
        die "Unknown argument $1"
        ;;
    esac
  done

  [[ -n "$SHA256" ]] || die "--sha256 required"
  [[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid sha256 format"
}

install_deps() {
  log "Installing minimal runtime dependencies..."
  apt-get update -y
  apt-get install -y \
    ca-certificates curl tar xz-utils jq
}

create_user() {
  log "Ensuring lightning system user..."
  if ! id -u "$LIGHTNING_USER" >/dev/null 2>&1; then
    useradd --system \
      --home "$LIGHTNING_DIR" \
      --create-home \
      --shell /usr/sbin/nologin \
      --user-group \
      "$LIGHTNING_USER"
  fi

  mkdir -p "$LIGHTNING_DIR"
  chown -R "$LIGHTNING_USER:$LIGHTNING_GROUP" "$LIGHTNING_DIR"
  chmod 0750 "$LIGHTNING_DIR"
}

download_and_verify() {
  mkdir -p "$TMP"
  cd "$TMP"

  log "Downloading ${URL}"
  curl -fL --retry 3 -o "$FILENAME" "$URL"

  log "Verifying sha256..."
  echo "${SHA256}  ${FILENAME}" | sha256sum -c -
}

install_binary() {
  log "Extracting..."
  rm -rf extract
  mkdir extract
  tar -xf "$FILENAME" -C extract

  # If tar contains a single top directory, descend into it
  ROOT="$(find extract -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -n "$ROOT" ]]; then
    EXTRACT_DIR="$ROOT"
  else
    EXTRACT_DIR="extract"
  fi

  TS="$(date -u +%Y%m%d-%H%M%S)"
  DEST="${INSTALL_BASE}/${TS}"
  CURRENT="${INSTALL_BASE}/current"

  mkdir -p "$INSTALL_BASE"
  cp -a "$EXTRACT_DIR" "$DEST"
  ln -sfn "$DEST" "$CURRENT"

  # 🔥 Correct binary location detection
  if [[ -x "${CURRENT}/bin/lightningd" ]]; then
    ln -sfn "${CURRENT}/bin/lightningd" /usr/local/bin/lightningd
  fi

  if [[ -x "${CURRENT}/bin/lightning-cli" ]]; then
    ln -sfn "${CURRENT}/bin/lightning-cli" /usr/local/bin/lightning-cli
  fi

  command -v lightningd >/dev/null || die "lightningd not installed properly"
}


create_systemd_unit() {
  log "Creating systemd service..."

  cat > /etc/systemd/system/lightningd.service <<EOF
[Unit]
Description=Core Lightning (CLN)
After=network-online.target
Wants=network-online.target

[Service]
User=${LIGHTNING_USER}
Group=${LIGHTNING_GROUP}
Type=simple
ExecStart=/usr/local/bin/lightningd \\
  --lightning-dir=${LIGHTNING_DIR} \\
  --network=${NETWORK} \\
  --addr=0.0.0.0:${PORT}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${LIGHTNING_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now lightningd
}

final_message() {
  log "Installation complete."
  echo
  echo "Check status:"
  echo "  systemctl status lightningd"
  echo
  echo "Run CLI as lightning user:"
  echo "  sudo -u lightning lightning-cli --lightning-dir=${LIGHTNING_DIR} getinfo"
  echo
}

main() {
  require_root
  parse_args "$@"
  install_deps
  create_user
  download_and_verify
  install_binary
  create_systemd_unit
  final_message
}

main "$@"
