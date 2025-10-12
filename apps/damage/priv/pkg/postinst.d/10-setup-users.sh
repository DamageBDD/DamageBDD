#!/bin/sh
set -e
set -x
# postinst for damage — relx release with include_erts=true

#PKG_NAME="{{app}}"

# Paths produced by your package layout
#PREFIX="{{install_prefix}}"
#BIN="${PREFIX}/{{app}}/bin/{{app}}"
#LINK="/usr/bin/{{app}}"
#
#ETC_DIR="{{etc_dir}}"
#VAR_DIR="{{var_dir}}"
#LOG_DIR="{{log_dir}}"
#
## Service/user knobs (string flags so we can test in shell)
#CREATE_USER="{{create_user}}"        # "true" or "false"
#USER="{{user}}"
#GROUP="{{group}}"
#SERVICE_NAME="{{service_name}}"
#AUTO_START="{{auto_start}}"          # "true" or "false"

log() { printf '%s\n' ">>> $*"; }

ensure_group() {
    if ! getent group "$GROUP" >/dev/null 2>&1; then
        log "Creating group: $GROUP"
        addgroup --system "$GROUP" >/dev/null
    fi
}

ensure_user() {
    if ! id -u "$USER" >/dev/null 2>&1; then
        log "Creating user: $USER"
        adduser --system --ingroup "$GROUP" --home "${PREFIX}/${APP}/" --no-create-home \
                --shell /usr/sbin/nologin "$USER" >/dev/null
    fi
}

# Optional service account
if [ "$CREATE_USER" = "true" ] && [ -n "$USER" ] && [ -n "$GROUP" ]; then
    ensure_group
    ensure_user
fi

# Ensure runtime/config dirs
install -d -m 0755 "$ETC_DIR" "$VAR_DIR" "$LOG_DIR"

KEY_PATH="${VAR_DIR}/ssh_daemon/ssh_host_rsa_key"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"

# Generate key only if missing
if [ ! -f "$KEY_PATH" ]; then
    echo "[INFO] Generating new SSH host key: $KEY_PATH"
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N ""
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
else
    echo "[INFO] SSH host key already exists at $KEY_PATH — skipping generation."
fi

# Ownership (only if we created a user)
if [ "$CREATE_USER" = "true" ] && [ -n "$USER" ] && [ -n "$GROUP" ]; then
    chown -R "$USER:$GROUP" "$VAR_DIR" "$LOG_DIR" || true
fi

# Make sure the release script is executable
if [ -f "$BIN" ]; then
    chmod 0755 "$BIN" || true
fi

# Symlink into PATH
if [ -x "$BIN" ]; then
    if [ -L "$LINK" ] && [ "$(readlink -f "$LINK")" = "$BIN" ]; then
        : # correct link already present
    else
        log "Linking $LINK -> $BIN"
        ln -sf "$BIN" "$LINK"
    fi
fi


# If a systemd unit was installed, reload + (optional) enable/start
if command -v systemctl >/dev/null 2>&1; then
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || \
           [ -f "/lib/systemd/system/${SERVICE_NAME}.service" ]; then
        systemctl daemon-reload || true
        if [ "$AUTO_START" = "true" ]; then
            systemctl enable "${SERVICE_NAME}.service" || true
            systemctl start  "${SERVICE_NAME}.service" || true
        fi
    fi
fi

exit 0
