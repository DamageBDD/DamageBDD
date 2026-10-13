#!/usr/bin/env bash
# bootstrap_sudoers.sh — install tight sudoers for DamageBDD
# Usage: sudo ./bootstrap_sudoers.sh [user-or-%group]
set -euo pipefail

APP_SUBJECT="${1:-damagebdd}"        # e.g. "damagebdd" user or "%damage" group
SUDOERS_DIR=/etc/sudoers.d
SUDOERS_FILE="$SUDOERS_DIR/damagebdd"
TMP="$(mktemp)"
cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

# Safety: must be root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [user-or-%group]" >&2
  exit 1
fi

# Safety: ensure sudoers.d is included; if not, bail (don't auto-edit /etc/sudoers)
if ! grep -Eq '^[[:space:]]*#?includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  echo "/etc/sudoers.d not included in /etc/sudoers. Enable it with visudo, then re-run." >&2
  exit 1
fi

# OPTIONAL: create a locked-down service user/group if you want:
# id -u damagebdd &>/dev/null || useradd -r -s /usr/bin/nologin -m -U damagebdd

# Pin absolute paths and list ONLY what you need on this host.
# Adjust these to your real commands (Arch paths shown).
cat >"$TMP" <<'EOF'
# DamageBDD minimal privileges
# Keep this file 0440 root:root and validate with visudo -c -f.
#
# Define the exact commands (ABSOLUTE PATHS!) this app may run as root.
Cmnd_Alias DAMAGE_CMDS = \
  /usr/bin/systemctl restart damagebdd.service, \
  /usr/bin/systemctl status damagebdd.service, \
  /usr/bin/ip link set dev wg0 up

# Defaults just for our alias to reduce attack surface.
Defaults!DAMAGE_CMDS env_reset,secure_path=/usr/bin:/usr/sbin,noexec

# SUBJECT_PLACEHOLDER ALL=(root) NOPASSWD: DAMAGE_CMDS
EOF

# Replace the placeholder with the subject (user or %group)
sed -i "s|SUBJECT_PLACEHOLDER|${APP_SUBJECT}|g" "$TMP"

# Validate BEFORE installing
if ! visudo -c -f "$TMP" >/dev/null; then
  echo "visudo validation failed; refusing to install sudoers snippet." >&2
  exit 1
fi

# Install atomically with correct perms
install -o root -g root -m 0440 "$TMP" "$SUDOERS_FILE"

echo "Installed $SUDOERS_FILE for ${APP_SUBJECT}."
echo "Test with: sudo -n -l -U ${APP_SUBJECT#%}  (or su to the user and run one allowed command)."
