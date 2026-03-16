#!/bin/sh
set -eu
set -x

SERVICE_NAME="${APP}"
INSTALL_DIR="${PREFIX}/${APP}/"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="/etc/${APP}/${APP}.config"


log() { printf '%s\n' "[postinst] $*"; }

is_container() {
  # Fast paths
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0
  # cgroup hint
  if [ -r /proc/1/cgroup ]; then
    if grep -Eiq '(docker|lxc|containerd|podman)' /proc/1/cgroup; then
      return 0
    fi
  fi
  # systemd-detect-virt (optional)
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --container >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

systemd_present() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [ -d /run/systemd/system ] || return 1
  # PID 1 must be systemd
  if command -v ps >/dev/null 2>&1; then
    [ "$(ps -o comm= -p 1 2>/dev/null || echo 'unknown')" = "systemd" ] || return 1
  fi
  return 0
}

systemd_running() {
  # Accept running or degraded; avoid hard-failing during boot transitions
  if systemctl is-system-running --quiet 2>/dev/null; then
    return 0
  fi
  # Fallback: try a benign call
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  return 0
}

write_default_config() {
    umask 022

    CONFIG_DIR="$(dirname "$CONFIG_FILE")"

    # ✅ Ensure config directory exists
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "[postinst] creating config directory: $CONFIG_DIR"
        mkdir -p "$CONFIG_DIR" || {
            echo "[postinst][ERROR] failed to create config directory"
            return 1
        }
        chmod 0755 "$CONFIG_DIR"
    fi

    # ✅ Do not overwrite existing config
    if [ -f "$CONFIG_FILE" ]; then
        echo "[postinst] config exists, not overwriting: $CONFIG_FILE"
        return 0
    fi

    echo "[postinst] creating default config: $CONFIG_FILE"

    cat > "$CONFIG_FILE" <<'EOF'
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
EOF

    chmod 0644 "$CONFIG_FILE"
}



write_unit() {
  umask 022
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Damage Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=damage
Environment=SHELL=sh
EnvironmentFile=/etc/default/damage
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/bin/damage foreground -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
}

case "${1:-configure}" in
  configure)
    log "Begin configure"

    if is_container; then
      log "Container detected — skipping systemd unit install."
      exit 0
    fi

    if ! systemd_present; then
      log "systemd not present/running as PID 1 — skipping unit install."
      exit 0
    fi

    if ! systemd_running; then
      log "systemd not fully running (boot or chroot) — writing unit only, not enabling/starting."
      write_unit
      systemctl daemon-reload >/dev/null 2>&1 || true
      exit 0
    fi

    # Optional: ensure service user exists (no login, no shell)
    if ! id -u damage >/dev/null 2>&1; then
      log "Creating 'damage' system user"
      useradd -r -d "${INSTALL_DIR}" -s /usr/sbin/nologin damage 2>/dev/null || true
    fi
    # Optional: ownership (ignore errors if files are elsewhere)
    chown -R damage:damage "${INSTALL_DIR}" 2>/dev/null || true

    log "Writing systemd unit to ${SERVICE_FILE}"
    write_unit
    write_default_config

    log "Reloading systemd daemon"
    systemctl daemon-reload

    log "Enabling ${SERVICE_NAME}.service"
    systemctl enable "${SERVICE_NAME}.service"

    log "Starting (or restarting) ${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service" || systemctl start "${SERVICE_NAME}.service" || true

    log "Done."
    ;;
  abort-upgrade|abort-remove|abort-deconfigure)
    # Nothing special
    exit 0
    ;;
  *)
    # Be permissive for unknown invocations
    exit 0
    ;;
esac
