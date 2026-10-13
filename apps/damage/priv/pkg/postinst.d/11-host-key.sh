#!/bin/sh
set -eu

# Create isolated SSH host keys and authorized_keys trees used by DamageBDD's
# embedded Git and tunnel listeners. Safe to run repeatedly.

APP="${APP:-damage}"
VAR_DIR="${VAR_DIR:-/var/lib/${APP}}"
LOG_DIR="${LOG_DIR:-/var/log/${APP}}"
INSTALL_LOG="${INSTALL_LOG:-${LOG_DIR}/install.log}"

PKG_USER="${PKG_USER:-${SERVICE_USER:-}}"
if [ -z "$PKG_USER" ]; then
    case "${USER:-}" in
        ""|root) PKG_USER="$APP" ;;
        *) PKG_USER="$USER" ;;
    esac
fi
PKG_GROUP="${PKG_GROUP:-${SERVICE_GROUP:-$PKG_USER}}"

# Isolated SSH trees. Keep the DAMAGE_* names because these are application
# runtime configuration knobs, not distro-specific package assumptions.
DAMAGE_SSH_GIT_SYSTEM_DIR="${DAMAGE_SSH_GIT_SYSTEM_DIR:-${VAR_DIR}/ssh/git/system}"
DAMAGE_SSH_GIT_USER_DIR="${DAMAGE_SSH_GIT_USER_DIR:-${VAR_DIR}/ssh/git/user}"
DAMAGE_SSH_GIT_REPOS_DIR="${DAMAGE_SSH_GIT_REPOS_DIR:-${VAR_DIR}/git}"
DAMAGE_SSH_TUNNEL_SYSTEM_DIR="${DAMAGE_SSH_TUNNEL_SYSTEM_DIR:-${VAR_DIR}/ssh/tunnel/system}"
DAMAGE_SSH_TUNNEL_USER_DIR="${DAMAGE_SSH_TUNNEL_USER_DIR:-${VAR_DIR}/ssh/tunnel/user}"

DAMAGE_USER="${DAMAGE_USER:-$PKG_USER}"
DAMAGE_GROUP="${DAMAGE_GROUP:-$PKG_GROUP}"

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

init_install_log() {
    mkdir -p "$LOG_DIR"
    touch "$INSTALL_LOG"
    chmod 0640 "$INSTALL_LOG" 2>/dev/null || true
}

log() {
    _line="$(utc_now) [postinst][11-host-key] $*"
    printf '%s\n' "$_line"
    printf '%s\n' "$_line" >>"$INSTALL_LOG" 2>/dev/null || true
}

fatal() {
    log "ERROR: $*"
    exit 1
}

ensure_dir() {
    _dir="$1"
    install -d -m 0700 "$_dir"
    if [ -n "$DAMAGE_USER" ] && [ -n "$DAMAGE_GROUP" ] && \
       id -u "$DAMAGE_USER" >/dev/null 2>&1; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$_dir"
    fi
}

fix_key_permissions() {
    _key="$1"
    chmod 0600 "$_key"
    [ ! -f "${_key}.pub" ] || chmod 0644 "${_key}.pub"

    if [ -n "$DAMAGE_USER" ] && [ -n "$DAMAGE_GROUP" ] && \
       id -u "$DAMAGE_USER" >/dev/null 2>&1; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$_key"
        [ ! -f "${_key}.pub" ] || chown "$DAMAGE_USER:$DAMAGE_GROUP" "${_key}.pub"
    fi
}

generate_host_key() {
    _type="$1"
    _bits="$2"
    _system_dir="$3"
    _name="$4"
    _key="${_system_dir}/ssh_host_${_type}_key"

    ensure_dir "$_system_dir"
    if [ ! -f "$_key" ]; then
        log "Generating ${_name} ${_type} SSH host key: $_key"
        if [ -n "$_bits" ]; then
            ssh-keygen -q -t "$_type" -b "$_bits" -f "$_key" -N ""
        else
            ssh-keygen -q -t "$_type" -f "$_key" -N ""
        fi
    else
        log "Keeping existing ${_name} ${_type} SSH host key: $_key"
    fi
    fix_key_permissions "$_key"
}

ensure_authorized_keys() {
    _user_dir="$1"
    _name="$2"
    _auth_keys="${_user_dir}/authorized_keys"

    ensure_dir "$_user_dir"
    if [ ! -f "$_auth_keys" ]; then
        log "Creating empty ${_name} authorized_keys: $_auth_keys"
        : >"$_auth_keys"
    else
        log "Keeping existing ${_name} authorized_keys: $_auth_keys"
    fi
    chmod 0600 "$_auth_keys"
    if id -u "$DAMAGE_USER" >/dev/null 2>&1; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$_auth_keys"
    fi
}

init_install_log
if ! command -v ssh-keygen >/dev/null 2>&1; then
    log "WARNING: ssh-keygen is not installed; skipping optional SSH listener key setup"
    exit 0
fi

log "Starting SSH listener key setup"
generate_host_key ed25519 "" "$DAMAGE_SSH_GIT_SYSTEM_DIR" "git listener"
generate_host_key rsa 4096 "$DAMAGE_SSH_GIT_SYSTEM_DIR" "git listener"
ensure_authorized_keys "$DAMAGE_SSH_GIT_USER_DIR" "git listener"
ensure_dir "$DAMAGE_SSH_GIT_REPOS_DIR"

generate_host_key ed25519 "" "$DAMAGE_SSH_TUNNEL_SYSTEM_DIR" "tunnel listener"
generate_host_key rsa 4096 "$DAMAGE_SSH_TUNNEL_SYSTEM_DIR" "tunnel listener"
ensure_authorized_keys "$DAMAGE_SSH_TUNNEL_USER_DIR" "tunnel listener"

log "SSH listener key setup complete"
exit 0
