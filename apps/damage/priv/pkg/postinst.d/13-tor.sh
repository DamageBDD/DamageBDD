#!/bin/sh
set -eu

DAMAGE_STATE=/var/lib/damage
DAMAGE_TOR_STATE="$DAMAGE_STATE/tor"
TOR_HS_DIR=/var/lib/tor/damagebdd
TOR_FRAGMENT=/etc/tor/torrc.d/damagebdd.conf
TORRC=/etc/tor/torrc

log() {
    printf 'damage: %s\n' "$*"
}

fail() {
    printf 'damage: %s\n' "$*" >&2
    exit 1
}

# The Debian package declares Depends: tor, so APT/dpkg must satisfy Tor
# before this postinst fragment runs. Never run apt from a maintainer script:
# apt/dpkg may already hold the package database locks at this point.
if ! command -v tor >/dev/null 2>&1; then
    fail "Tor is not installed even though the Damage Debian package depends on tor"
fi

# Damage service identity should already exist by the time postinst.d runs.
if ! getent passwd damage >/dev/null 2>&1; then
    fail "damage service user does not exist"
fi
if ! getent group damage >/dev/null 2>&1; then
    fail "damage service group does not exist"
fi

mkdir -p "$DAMAGE_TOR_STATE"
chown damage:damage "$DAMAGE_TOR_STATE"
# hostname is public node metadata. Keep the directory traversable so local
# tooling can inspect it without granting access to Damage private state.
chmod 0755 "$DAMAGE_TOR_STATE"

[ -f "$TORRC" ] || fail "Tor configuration file not found: $TORRC"
mkdir -p /etc/tor/torrc.d

cat > "$TOR_FRAGMENT" <<'TORCONF'
# Managed by the DamageBDD package.
# The private onion-service identity remains owned exclusively by Tor.
HiddenServiceDir /var/lib/tor/damagebdd/
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:8080

SocksPort 127.0.0.1:9050
ControlPort 127.0.0.1:9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
TORCONF

chmod 0644 "$TOR_FRAGMENT"

# Tor supports %include. Keep the distro torrc intact and add one stable
# package-managed include only when it is not already present.
if ! grep -Eq '^[[:space:]]*%include[[:space:]]+/etc/tor/torrc\.d/' "$TORRC"; then
    printf '\n%%include /etc/tor/torrc.d/*.conf\n' >> "$TORRC"
fi

# Debian/Tor Project packages normally use debian-tor. Some Debian-derived or
# manually installed Tor packages use tor. Damage only needs group access to
# the ControlPort authentication cookie; the hidden-service secret key remains
# mode 0600 and is never copied or made group-readable.
TOR_GROUP=
if getent group debian-tor >/dev/null 2>&1; then
    TOR_GROUP=debian-tor
elif getent group tor >/dev/null 2>&1; then
    TOR_GROUP=tor
fi

if [ -n "$TOR_GROUP" ]; then
    usermod -a -G "$TOR_GROUP" damage || true
fi

# Debian ships tor.service plus tor@default.service. The latter is the actual
# default instance on systemd Debian packages. Other Debian-derived packages
# may only expose tor.service.
TOR_UNIT=tor.service
if command -v systemctl >/dev/null 2>&1; then
    if systemctl cat tor@default.service >/dev/null 2>&1; then
        TOR_UNIT=tor@default.service
    elif systemctl cat tor.service >/dev/null 2>&1; then
        TOR_UNIT=tor.service
    else
        fail "Tor is installed but no Tor systemd service unit was found"
    fi

    systemctl enable "$TOR_UNIT" >/dev/null 2>&1 || true

    # The Tor package may have started the default instance already.
    # Wait for that startup to settle before forcing a restart.
    i=0
    while systemctl is-active "$TOR_UNIT" 2>/dev/null | grep -q '^activating$' &&
          [ "$i" -lt 300 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    # Apply our configuration.
    if systemctl is-active --quiet "$TOR_UNIT"; then
        systemctl restart "$TOR_UNIT" >/dev/null 2>&1 || true
    else
        systemctl start "$TOR_UNIT" >/dev/null 2>&1 || true
    fi

    # systemd may perform an automatic restart after a failed attempt.
    i=0
    while [ "$i" -lt 300 ]; do
        if systemctl is-active --quiet "$TOR_UNIT"; then
            break
        fi

        sleep 0.1
        i=$((i + 1))
    done

    if ! systemctl is-active --quiet "$TOR_UNIT"; then
        systemctl --no-pager --full status "$TOR_UNIT" >&2 || true
        journalctl -u "$TOR_UNIT" -n 100 --no-pager >&2 || true
        fail "failed to start $TOR_UNIT"
    fi
else
    # The generated Debian package currently installs a systemd unit for
    # Damage, so this is mainly a diagnostic guard for unusual environments.
    fail "systemctl is required to configure the packaged Tor service"
fi

# Tor generates the persistent v3 identity asynchronously after startup.
# Wait up to 30 seconds; do not regenerate or remove the service directory on
# upgrades, because its hs_ed25519_secret_key defines the stable .onion name.
i=0
while [ ! -s "$TOR_HS_DIR/hostname" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
done

if [ ! -s "$TOR_HS_DIR/hostname" ]; then
    systemctl --no-pager --full status "$TOR_UNIT" >&2 || true
    fail "Tor did not generate Onion Service hostname at $TOR_HS_DIR/hostname"
fi

# Publish ONLY the public onion hostname for Damage. The Tor-owned directory
# remains private (typically 0700) and hs_ed25519_secret_key remains 0600.
install \
    -o damage \
    -g damage \
    -m 0644 \
    "$TOR_HS_DIR/hostname" \
    "$DAMAGE_TOR_STATE/hostname"

ONION_HOST=$(tr -d '\r\n' < "$DAMAGE_TOR_STATE/hostname")
case "$ONION_HOST" in
    *.onion) ;;
    *) fail "Tor generated an invalid Onion Service hostname: $ONION_HOST" ;;
esac

log "DamageBDD Onion address: http://$ONION_HOST/"

# Restart after group membership and public hostname publication so the Damage
# service sees the Tor control-cookie group immediately.
systemctl restart damage.service >/dev/null 2>&1 || true
