#!/bin/sh
set -e
set -x

: "${VAR_DIR:=/var/lib/damage}"

# Isolated SSH trees
: "${DAMAGE_SSH_GIT_SYSTEM_DIR:=${VAR_DIR}/ssh/git/system}"
: "${DAMAGE_SSH_GIT_USER_DIR:=${VAR_DIR}/ssh/git/user}"
: "${DAMAGE_SSH_GIT_REPOS_DIR:=${VAR_DIR}/git}"

: "${DAMAGE_SSH_TUNNEL_SYSTEM_DIR:=${VAR_DIR}/ssh/tunnel/system}"
: "${DAMAGE_SSH_TUNNEL_USER_DIR:=${VAR_DIR}/ssh/tunnel/user}"

# Optional ownership, useful when running from package/install scripts as root.
# Example:
#   DAMAGE_USER=damage DAMAGE_GROUP=damage ./install_ssh_keys.sh
: "${DAMAGE_USER:=}"
: "${DAMAGE_GROUP:=}"

ensure_dir() {
    DIR="$1"

    mkdir -p "$DIR"
    chmod 700 "$DIR"

    if [ -n "$DAMAGE_USER" ] && [ -n "$DAMAGE_GROUP" ]; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$DIR"
    fi
}

fix_key_permissions() {
    KEY_PATH="$1"

    chmod 600 "$KEY_PATH"
    [ -f "${KEY_PATH}.pub" ] && chmod 644 "${KEY_PATH}.pub"

    if [ -n "$DAMAGE_USER" ] && [ -n "$DAMAGE_GROUP" ]; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$KEY_PATH"
        [ -f "${KEY_PATH}.pub" ] && chown "$DAMAGE_USER:$DAMAGE_GROUP" "${KEY_PATH}.pub"
    fi
}

generate_ed25519_host_key() {
    SYSTEM_DIR="$1"
    NAME="$2"
    KEY_PATH="${SYSTEM_DIR}/ssh_host_ed25519_key"

    ensure_dir "$SYSTEM_DIR"

    if [ ! -f "$KEY_PATH" ]; then
        echo "[INFO] Generating ${NAME} ed25519 SSH host key: $KEY_PATH"
        ssh-keygen -q -t ed25519 -f "$KEY_PATH" -N ""
    else
        echo "[INFO] ${NAME} ed25519 SSH host key already exists at $KEY_PATH - skipping."
    fi

    fix_key_permissions "$KEY_PATH"
}

generate_rsa_host_key() {
    SYSTEM_DIR="$1"
    NAME="$2"
    KEY_PATH="${SYSTEM_DIR}/ssh_host_rsa_key"

    ensure_dir "$SYSTEM_DIR"

    if [ ! -f "$KEY_PATH" ]; then
        echo "[INFO] Generating ${NAME} RSA SSH host key: $KEY_PATH"
        ssh-keygen -q -t rsa -b 4096 -f "$KEY_PATH" -N ""
    else
        echo "[INFO] ${NAME} RSA SSH host key already exists at $KEY_PATH - skipping."
    fi

    fix_key_permissions "$KEY_PATH"
}

ensure_authorized_keys() {
    USER_DIR="$1"
    NAME="$2"
    AUTH_KEYS="${USER_DIR}/authorized_keys"

    ensure_dir "$USER_DIR"

    if [ ! -f "$AUTH_KEYS" ]; then
        echo "[INFO] Creating empty ${NAME} authorized_keys: $AUTH_KEYS"
        : > "$AUTH_KEYS"
    else
        echo "[INFO] ${NAME} authorized_keys already exists at $AUTH_KEYS - keeping."
    fi

    chmod 600 "$AUTH_KEYS"

    if [ -n "$DAMAGE_USER" ] && [ -n "$DAMAGE_GROUP" ]; then
        chown "$DAMAGE_USER:$DAMAGE_GROUP" "$AUTH_KEYS"
    fi
}

ensure_repos_root() {
    ensure_dir "$DAMAGE_SSH_GIT_REPOS_DIR"
}

# Git SSH listener keys.
generate_ed25519_host_key "$DAMAGE_SSH_GIT_SYSTEM_DIR" "git listener"
generate_rsa_host_key     "$DAMAGE_SSH_GIT_SYSTEM_DIR" "git listener"
ensure_authorized_keys    "$DAMAGE_SSH_GIT_USER_DIR" "git listener"
ensure_repos_root

# Tunnel SSH listener keys.
generate_ed25519_host_key "$DAMAGE_SSH_TUNNEL_SYSTEM_DIR" "tunnel listener"
generate_rsa_host_key     "$DAMAGE_SSH_TUNNEL_SYSTEM_DIR" "tunnel listener"
ensure_authorized_keys    "$DAMAGE_SSH_TUNNEL_USER_DIR" "tunnel listener"

echo "[INFO] DamageBDD SSH listener key setup complete."

exit 0
