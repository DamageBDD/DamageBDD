#!/bin/sh
set -eu

# Install Kubo only when no IPFS executable is already available. The script
# avoids distro package-manager assumptions and supports common Linux CPU
# architectures used by DEB/RPM/Arch packages.

APP="${APP:-damage}"
LOG_DIR="${LOG_DIR:-/var/log/${APP}}"
INSTALL_LOG="${INSTALL_LOG:-${LOG_DIR}/install.log}"

KUBO_VERSION="${KUBO_VERSION:-v0.38.2}"
IPFS_USER="${IPFS_USER:-ipfs}"
IPFS_GROUP="${IPFS_GROUP:-$IPFS_USER}"
IPFS_HOME="${IPFS_HOME:-/var/lib/ipfs}"
IPFS_PATH="${IPFS_PATH:-${IPFS_HOME}/.ipfs}"
IPFS_BIN="${IPFS_BIN:-/usr/local/bin/ipfs}"
IPFS_AUTO_START="${IPFS_AUTO_START:-true}"
IPFS_SYSTEMD="${IPFS_SYSTEMD:-auto}"

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

init_install_log() {
    mkdir -p "$LOG_DIR"
    touch "$INSTALL_LOG"
    chmod 0640 "$INSTALL_LOG" 2>/dev/null || true
}

log() {
    _line="$(utc_now) [postinst][12-ipfs] $*"
    printf '%s\n' "$_line"
    printf '%s\n' "$_line" >>"$INSTALL_LOG" 2>/dev/null || true
}

fatal() {
    log "ERROR: $*"
    exit 1
}

ipfs_exists() {
    if command -v ipfs >/dev/null 2>&1; then
        IPFS_BIN="$(command -v ipfs)"
        export IPFS_BIN
        return 0
    fi

    [ -x "$IPFS_BIN" ]
}

kubo_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' linux-amd64 ;;
        aarch64|arm64) printf '%s\n' linux-arm64 ;;
        armv7l|armv7) printf '%s\n' linux-arm ;;
        *) return 1 ;;
    esac
}

group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$IPFS_GROUP" >/dev/null 2>&1
    else
        grep -q "^${IPFS_GROUP}:" /etc/group 2>/dev/null
    fi
}

ensure_ipfs_account() {
    if ! group_exists; then
        log "Creating IPFS system group: $IPFS_GROUP"
        if command -v groupadd >/dev/null 2>&1; then
            groupadd -r "$IPFS_GROUP"
        elif command -v addgroup >/dev/null 2>&1; then
            addgroup --system "$IPFS_GROUP" >/dev/null 2>&1 || \
                addgroup -S "$IPFS_GROUP" >/dev/null 2>&1
        else
            fatal "No supported group creation command found"
        fi
    fi

    if ! id -u "$IPFS_USER" >/dev/null 2>&1; then
        log "Creating IPFS system user: $IPFS_USER"
        _shell="$(command -v nologin 2>/dev/null || true)"
        [ -n "$_shell" ] || _shell=/bin/false
        if command -v useradd >/dev/null 2>&1; then
            useradd -r -g "$IPFS_GROUP" -d "$IPFS_HOME" -M -s "$_shell" "$IPFS_USER"
        elif command -v adduser >/dev/null 2>&1; then
            adduser --system --ingroup "$IPFS_GROUP" --home "$IPFS_HOME" \
                --no-create-home --shell "$_shell" "$IPFS_USER" >/dev/null 2>&1 || \
                adduser -S -D -H -G "$IPFS_GROUP" -h "$IPFS_HOME" -s "$_shell" "$IPFS_USER"
        else
            fatal "No supported user creation command found"
        fi
    fi

    install -d -m 0755 "$IPFS_HOME"
    chown "$IPFS_USER:$IPFS_GROUP" "$IPFS_HOME"
}

download_file() {
    _url="$1"
    _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$_out" "$_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$_out" "$_url"
    else
        fatal "curl or wget is required to install Kubo"
    fi
}


verify_sha512() {
    _tarball="$1"
    _checksum="$2"
    if command -v sha512sum >/dev/null 2>&1; then
        (cd "$(dirname "$_tarball")" && sha512sum -c "$(basename "$_checksum")")
    elif command -v shasum >/dev/null 2>&1; then
        _expected="$(awk '{print $1}' "$_checksum")"
        _actual="$(shasum -a 512 "$_tarball" | awk '{print $1}')"
        [ "$_actual" = "$_expected" ] || fatal "Kubo SHA-512 checksum mismatch"
    else
        fatal "sha512sum or shasum is required to verify Kubo"
    fi
}

run_as_ipfs() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$IPFS_USER" -- env IPFS_PATH="$IPFS_PATH" "$@"
    elif command -v su >/dev/null 2>&1; then
        _cmd="IPFS_PATH='$IPFS_PATH' '$1'"
        shift
        for _arg in "$@"; do
            _cmd="${_cmd} '${_arg}'"
        done
        su -s /bin/sh -c "$_cmd" "$IPFS_USER"
    else
        fatal "runuser or su is required to initialize IPFS as $IPFS_USER"
    fi
}

systemd_running() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1

    if command -v ps >/dev/null 2>&1; then
        [ "$(ps -o comm= -p 1 2>/dev/null || printf unknown)" = "systemd" ]
    fi
}

install_ipfs_systemd_unit() {
    if [ "$IPFS_SYSTEMD" = "false" ]; then
        log "IPFS_SYSTEMD=false; skipping ipfs.service installation"
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemd is not installed; skipping ipfs.service installation"
        return 0
    fi

    install -d -m 0755 /etc/systemd/system
    cat > /etc/systemd/system/ipfs.service <<EOF_UNIT
[Unit]
Description=IPFS daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$IPFS_USER
Group=$IPFS_GROUP
Environment=IPFS_PATH=$IPFS_PATH
ExecStart=$IPFS_BIN daemon --migrate=true
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 /etc/systemd/system/ipfs.service

    if systemd_running; then
        systemctl daemon-reload
        systemctl enable ipfs.service >/dev/null 2>&1 || true
        if [ "$IPFS_AUTO_START" = "true" ]; then
            systemctl restart ipfs.service >/dev/null 2>&1 || \
                systemctl start ipfs.service >/dev/null 2>&1 || true
        fi
    else
        log "systemd is not running; installed ipfs.service without enabling/starting it"
    fi
}

init_install_log
log "Starting IPFS/Kubo setup"
ensure_ipfs_account

if ipfs_exists; then
    log "Using existing IPFS executable: $IPFS_BIN"
else
    _arch="$(kubo_arch)" || fatal "Unsupported Kubo architecture: $(uname -m)"
    _tarball="kubo_${KUBO_VERSION}_${_arch}.tar.gz"
    _url="https://dist.ipfs.tech/kubo/${KUBO_VERSION}/${_tarball}"
    _tmp="$(mktemp -d)"
    trap 'rm -rf "${_tmp:-}"' EXIT HUP INT TERM

    log "Downloading Kubo $KUBO_VERSION for $_arch"
    download_file "$_url" "${_tmp}/${_tarball}"
    download_file "${_url}.sha512" "${_tmp}/${_tarball}.sha512"
    log "Verifying Kubo SHA-512 checksum"
    verify_sha512 "${_tmp}/${_tarball}" "${_tmp}/${_tarball}.sha512"
    tar -xzf "${_tmp}/${_tarball}" -C "$_tmp"
    [ -x "${_tmp}/kubo/ipfs" ] || fatal "Kubo archive did not contain an ipfs executable"
    install -m 0755 "${_tmp}/kubo/ipfs" "$IPFS_BIN"
    log "Installed Kubo executable at $IPFS_BIN"

    rm -rf "$_tmp"
    trap - EXIT HUP INT TERM
fi

install -d -m 0755 "$IPFS_PATH"
chown -R "$IPFS_USER:$IPFS_GROUP" "$IPFS_HOME"

if [ ! -f "$IPFS_PATH/config" ]; then
    log "Initializing IPFS repository: $IPFS_PATH"
    run_as_ipfs "$IPFS_BIN" init --profile=server
else
    log "Keeping existing IPFS repository: $IPFS_PATH"
fi

install_ipfs_systemd_unit
log "IPFS/Kubo setup complete"
exit 0
