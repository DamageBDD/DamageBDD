#!/bin/sh
set -eu

# Configure and activate the canonical systemd unit shipped by the package.
# This hook never generates an application service unit, preventing distro
# variants from drifting away from the packaged canonical file.

APP="${APP:-damage}"
PREFIX="${PREFIX:-/opt}"
INSTALL_DIR="${INSTALL_DIR:-${PREFIX%/}/${APP}}"
SERVICE_NAME="${SERVICE_NAME:-$APP}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
CONFIG_FILE="${CONFIG_FILE:-/etc/${APP}/${APP}.config}"
LOG_DIR="${LOG_DIR:-/var/log/${APP}}"
INSTALL_LOG="${INSTALL_LOG:-${LOG_DIR}/install.log}"
AUTO_START="${AUTO_START:-true}"

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

init_install_log() {
    mkdir -p "$LOG_DIR"
    touch "$INSTALL_LOG"
    chmod 0640 "$INSTALL_LOG" 2>/dev/null || true
}

log() {
    _line="$(utc_now) [postinst][20-systemd] $*"
    printf '%s\n' "$_line"
    printf '%s\n' "$_line" >>"$INSTALL_LOG" 2>/dev/null || true
}

is_container() {
    [ -f /.dockerenv ] && return 0
    [ -f /run/.containerenv ] && return 0
    if [ -r /proc/1/cgroup ] && grep -Eiq '(docker|lxc|containerd|podman)' /proc/1/cgroup; then
        return 0
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1 && \
       systemd-detect-virt --container >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

systemd_present() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    if command -v ps >/dev/null 2>&1; then
        [ "$(ps -o comm= -p 1 2>/dev/null || printf unknown)" = "systemd" ] || return 1
    fi
    return 0
}

systemd_running() {
    systemctl is-system-running --quiet >/dev/null 2>&1 && return 0
    systemctl daemon-reload >/dev/null 2>&1
}

write_default_config() {
    _config_dir="$(dirname "$CONFIG_FILE")"
    install -d -m 0755 "$_config_dir"

    if [ -f "$CONFIG_FILE" ]; then
        log "Keeping existing config: $CONFIG_FILE"
        return 0
    fi

    log "Creating default config: $CONFIG_FILE"
    umask 022
    cat >"$CONFIG_FILE" <<'EOF_CONFIG'
%%% -*- mode: erlang; erlang-indent-level: 2; -*-

[
    {
        damage,
        [
            %{ip, {0, 0, 0, 0}},
            {ip, {127, 0, 0, 1}},
            {port, 4888},

            {
                node_admins,
                [
                    % add any node admin wallets,
                    % WARNING: only add trusted wallets
                    % this exposes admin access to your node
                ]
            }
        ]
    }
].
EOF_CONFIG
    chmod 0644 "$CONFIG_FILE"
}

verify_unit() {
    if [ ! -f "$SERVICE_FILE" ]; then
        log "ERROR: canonical systemd unit missing from package: $SERVICE_FILE"
        return 1
    fi
    chmod 0644 "$SERVICE_FILE"
}

init_install_log
log "Starting service configuration for $SERVICE_NAME"

# Configuration is useful even in containers/chroots and must not depend on a
# running systemd instance.
write_default_config
verify_unit

if is_container; then
    log "Container detected; leaving packaged unit/config in place without systemctl actions"
    exit 0
fi

if ! systemd_present; then
    log "systemd is not running as PID 1; leaving packaged unit/config in place"
    exit 0
fi

if ! systemd_running; then
    log "systemd is not fully available; attempting daemon-reload only"
    systemctl daemon-reload >/dev/null 2>&1 || true
    exit 0
fi

log "Reloading systemd manager configuration"
systemctl daemon-reload

if [ "$AUTO_START" = "true" ]; then
    log "Enabling ${SERVICE_NAME}.service"
    systemctl enable "${SERVICE_NAME}.service"

    log "Starting/restarting ${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service" || \
        systemctl start "${SERVICE_NAME}.service" || \
        log "WARNING: service could not be started; inspect systemctl status ${SERVICE_NAME}.service"
else
    log "AUTO_START=$AUTO_START; service was not enabled or started"
fi

log "Service configuration complete"
exit 0
