#!/bin/sh
# Install a built, immutable userspace release and vendor user service.
# This does not start a desktop process or grant access to Damage.
set -eu
if [ "$#" -gt 1 ]; then
    echo 'usage: install.sh [RELEASE_DIRECTORY]' >&2
    exit 64
fi
script=$(readlink -f -- "$0")
source=${1:-$(CDPATH= cd -- "$(dirname -- "$script")/../.." && pwd -P)}
target=/opt/erm-user
unit_dir=/usr/lib/systemd/user
[ "$(id -u)" = 0 ] || { echo 'run installer as root' >&2; exit 77; }
[ -x "$source/bin/erm-user" ] && [ -f "$source/releases/start_erl.data" ] || {
    echo 'RELEASE_DIRECTORY must be a built erm_user release' >&2; exit 66;
}
# Avoid following a user-created destination into an unrelated tree.
for path in /opt "$target" /usr/lib/systemd "$unit_dir"; do
    [ ! -L "$path" ] || { echo "refusing symlink destination: $path" >&2; exit 73; }
done
if [ "$(readlink -f -- "$source")" != "$target" ]; then
    install -d -m 0755 "$target"
    cp -a -- "$source/." "$target/"
    chown -R root:root "$target"
fi
install -d -m 0755 "$unit_dir"
install -m 0644 "$target/share/erm-user/systemd/user/erm-user.service" "$unit_dir/erm-user.service"
printf '%s\n' \
    'Installed ERM userspace runtime.' \
    'As each desktop user: systemctl --user daemon-reload' \
    'Then: systemctl --user enable erm-user.service' \
    'Start graphical-session.target only after publishing valid X11 credentials.' \
    'Provision Damage bridge access separately before testing communication.'
