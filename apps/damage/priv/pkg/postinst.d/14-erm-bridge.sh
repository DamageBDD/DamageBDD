#!/bin/sh
set -eu
# Prepare an empty authorization registry. Never grant access automatically.
APP="${APP:-damage}"
ETC_DIR="${ETC_DIR:-/etc/${APP}}"
PKG_GROUP="${PKG_GROUP:-${SERVICE_GROUP:-${APP}}}"
GRANTS_FILE="${ETC_DIR%/}/erm-users.config"
if [ -L "$ETC_DIR" ] || [ -L "$GRANTS_FILE" ]; then
    printf '%s\n' 'Refusing symlink in ERM bridge grants path' >&2
    exit 1
fi
install -d -m 0755 "$ETC_DIR"
if [ -e "$GRANTS_FILE" ]; then
    [ -f "$GRANTS_FILE" ] || exit 1
    printf '%s\n' "Keeping existing ERM grants: $GRANTS_FILE"
else
    # Parent is administrator-owned. Exclusive creation preserves upgrades.
    (umask 077; set -C; printf '%% Explicitly provision each desktop user.\n[].\n' > "$GRANTS_FILE")
    chown "root:$PKG_GROUP" "$GRANTS_FILE"
    chmod 0640 "$GRANTS_FILE"
fi
