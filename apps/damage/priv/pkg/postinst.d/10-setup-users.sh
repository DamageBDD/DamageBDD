#!/bin/sh
set -eu

# Create the package service account and runtime directories.
# Portable across Debian/Ubuntu, RHEL/Fedora, Arch and similar Linux systems.

APP="${APP:-damage}"
PREFIX="${PREFIX:-/opt}"
INSTALL_DIR="${INSTALL_DIR:-${PREFIX%/}/${APP}}"
BIN="${BIN:-${INSTALL_DIR}/bin/${APP}}"
LINK="${LINK:-/usr/bin/${APP}}"
ETC_DIR="${ETC_DIR:-/etc/${APP}}"
VAR_DIR="${VAR_DIR:-/var/lib/${APP}}"
LOG_DIR="${LOG_DIR:-/var/log/${APP}}"
CREATE_USER="${CREATE_USER:-true}"

# Prefer package-specific variables. USER may be inherited as root when a
# package manager invokes the hook, so only use it when it is non-root.
PKG_USER="${PKG_USER:-${SERVICE_USER:-}}"
if [ -z "$PKG_USER" ]; then
    case "${USER:-}" in
        ""|root) PKG_USER="$APP" ;;
        *) PKG_USER="$USER" ;;
    esac
fi
PKG_GROUP="${PKG_GROUP:-${SERVICE_GROUP:-$PKG_USER}}"
INSTALL_LOG="${INSTALL_LOG:-${LOG_DIR}/install.log}"

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

init_install_log() {
    mkdir -p "$LOG_DIR"
    touch "$INSTALL_LOG"
    chmod 0640 "$INSTALL_LOG" 2>/dev/null || true
}

log() {
    _line="$(utc_now) [postinst][10-setup-users] $*"
    printf '%s\n' "$_line"
    printf '%s\n' "$_line" >>"$INSTALL_LOG" 2>/dev/null || true
}

fatal() {
    log "ERROR: $*"
    exit 1
}

group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$PKG_GROUP" >/dev/null 2>&1
    else
        grep -q "^${PKG_GROUP}:" /etc/group 2>/dev/null
    fi
}

ensure_group() {
    group_exists && return 0

    log "Creating system group: $PKG_GROUP"
    if command -v groupadd >/dev/null 2>&1; then
        groupadd -r "$PKG_GROUP"
    elif command -v addgroup >/dev/null 2>&1; then
        addgroup --system "$PKG_GROUP" >/dev/null 2>&1 || \
            addgroup -S "$PKG_GROUP" >/dev/null 2>&1
    else
        fatal "No supported group creation command found (groupadd/addgroup)"
    fi
}

nologin_shell() {
    if command -v nologin >/dev/null 2>&1; then
        command -v nologin
    elif [ -x /usr/sbin/nologin ]; then
        printf '%s\n' /usr/sbin/nologin
    elif [ -x /sbin/nologin ]; then
        printf '%s\n' /sbin/nologin
    else
        printf '%s\n' /bin/false
    fi
}

ensure_user() {
    id -u "$PKG_USER" >/dev/null 2>&1 && return 0

    _shell="$(nologin_shell)"
    log "Creating system user: $PKG_USER (group=$PKG_GROUP home=$VAR_DIR)"
    if command -v useradd >/dev/null 2>&1; then
        useradd -r -g "$PKG_GROUP" -d "$VAR_DIR" -M -s "$_shell" "$PKG_USER"
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --ingroup "$PKG_GROUP" --home "$VAR_DIR" \
            --no-create-home --shell "$_shell" "$PKG_USER" >/dev/null 2>&1 || \
            adduser -S -D -H -G "$PKG_GROUP" -h "$VAR_DIR" -s "$_shell" "$PKG_USER"
    else
        fatal "No supported user creation command found (useradd/adduser)"
    fi
}

init_install_log
log "Starting account/directory setup for $APP"

if [ "$CREATE_USER" = "true" ] && [ -n "$PKG_USER" ] && [ -n "$PKG_GROUP" ]; then
    ensure_group
    ensure_user
fi

# Configuration remains root-managed. Runtime and log directories are writable
# by the service account.
install -d -m 0755 "$ETC_DIR"
install -d -m 0755 "$VAR_DIR" "$LOG_DIR"

if [ "$CREATE_USER" = "true" ] && id -u "$PKG_USER" >/dev/null 2>&1; then
    chown -R "$PKG_USER:$PKG_GROUP" "$VAR_DIR" "$LOG_DIR"
    chmod 0640 "$INSTALL_LOG" 2>/dev/null || true
fi

if [ -f "$BIN" ]; then
    chmod 0755 "$BIN"
else
    log "Release executable not found yet: $BIN"
fi

if [ -x "$BIN" ]; then
    _current=""
    if [ -L "$LINK" ]; then
        _current="$(readlink "$LINK" 2>/dev/null || true)"
    fi
    if [ "$_current" != "$BIN" ]; then
        log "Linking $LINK -> $BIN"
        ln -sf "$BIN" "$LINK"
    fi
fi

log "Account/directory setup complete"
exit 0
