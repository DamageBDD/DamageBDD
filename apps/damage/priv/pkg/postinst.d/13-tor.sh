#!/bin/sh
# DamageBDD Tor post-install hook.
#
# Goals:
# - safe in Debian/Ubuntu/Mint, Arch and other Linux package environments
# - never invoke apt/pacman/dnf/apk from a maintainer script
# - never make package installation fail merely because Tor cannot be started
# - preserve an existing onion-service identity across upgrades
# - avoid /etc/tor/torrc.d/* because older Debian/Ubuntu Tor AppArmor
#   profiles may allow /etc/tor/* but not nested /etc/tor/torrc.d/*
#
# This script intentionally treats Tor provisioning as best-effort. Package
# installation must remain usable on systems where Tor is installed/configured
# later by the administrator.

set -u

DAMAGE_USER=damage
DAMAGE_GROUP=damage
DAMAGE_STATE=/var/lib/damage
DAMAGE_TOR_STATE="$DAMAGE_STATE/tor"

TOR_HS_DIR=/var/lib/tor/damagebdd
TOR_FRAGMENT=/etc/tor/damagebdd.conf
OLD_TOR_FRAGMENT=/etc/tor/torrc.d/damagebdd.conf
TORRC=/etc/tor/torrc

log() {
    printf 'damage: %s\n' "$*"
}

warn() {
    printf 'damage: WARNING: %s\n' "$*" >&2
}

have_user() {
    id "$1" >/dev/null 2>&1
}

have_group() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$1" >/dev/null 2>&1
    elif [ -r /etc/group ]; then
        grep -Eq "^$1:" /etc/group
    else
        return 1
    fi
}

find_tor_group() {
    if have_group debian-tor; then
        printf '%s\n' debian-tor
    elif have_group tor; then
        printf '%s\n' tor
    else
        return 1
    fi
}

add_damage_to_tor_group() {
    TOR_GROUP_TO_ADD=$1

    if ! have_user "$DAMAGE_USER"; then
        warn "Damage service user is absent; skipping Tor control-cookie group membership."
        return 0
    fi

    # Do not fail package configuration because user/group tooling varies
    # between distributions. Debian/Ubuntu/Mint and Arch normally provide
    # usermod; BusyBox/OpenRC systems may provide addgroup instead.
    if command -v usermod >/dev/null 2>&1; then
        if ! usermod -a -G "$TOR_GROUP_TO_ADD" "$DAMAGE_USER"; then
            warn "Could not add $DAMAGE_USER to Tor group $TOR_GROUP_TO_ADD."
        fi
    elif command -v addgroup >/dev/null 2>&1; then
        if ! addgroup "$DAMAGE_USER" "$TOR_GROUP_TO_ADD" >/dev/null 2>&1; then
            warn "Could not add $DAMAGE_USER to Tor group $TOR_GROUP_TO_ADD."
        fi
    else
        warn "No supported user/group management command; Tor ControlPort cookie may be inaccessible to Damage."
    fi
}

prepare_damage_state() {
    if ! have_user "$DAMAGE_USER" || ! have_group "$DAMAGE_GROUP"; then
        warn "Damage service identity is not available yet; public onion hostname publication will be deferred."
        return 0
    fi

    if ! mkdir -p "$DAMAGE_TOR_STATE"; then
        warn "Cannot create $DAMAGE_TOR_STATE; onion hostname publication will be deferred."
        return 0
    fi

    chown "$DAMAGE_USER:$DAMAGE_GROUP" "$DAMAGE_TOR_STATE" 2>/dev/null ||
        warn "Cannot set ownership on $DAMAGE_TOR_STATE."
    chmod 0755 "$DAMAGE_TOR_STATE" 2>/dev/null ||
        warn "Cannot set permissions on $DAMAGE_TOR_STATE."

    return 0
}

write_tor_fragment() {
    FRAGMENT_TMP=$1

    cat > "$FRAGMENT_TMP" <<'TORCONF'
# Managed by the DamageBDD package.
#
# Keep this file directly below /etc/tor. Older Debian/Ubuntu Tor AppArmor
# profiles allow /etc/tor/* but can reject nested /etc/tor/torrc.d/*.conf.
#
# The hidden-service private key remains owned exclusively by Tor.
HiddenServiceDir /var/lib/tor/damagebdd/
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:4888

# Tor's distro default normally exposes SOCKS on 127.0.0.1:9050.
# Do not duplicate or override an administrator's SocksPort directives here.
ControlPort 127.0.0.1:9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
TORCONF
}

prepare_torrc() {
    INPUT_TORRC=$1
    OUTPUT_TORRC=$2
    MIGRATE_OLD=$3

    if [ "$MIGRATE_OLD" -eq 1 ]; then
        # Remove only the exact legacy include written by older DamageBDD
        # packages. Do not rewrite arbitrary administrator-managed includes.
        awk '
            /^[[:space:]]*%include[[:space:]]+\/etc\/tor\/torrc\.d\/\*\.conf[[:space:]]*$/ {
                next
            }
            { print }
        ' "$INPUT_TORRC" > "$OUTPUT_TORRC"
    else
        cat "$INPUT_TORRC" > "$OUTPUT_TORRC"
    fi

    if ! grep -Eq '^[[:space:]]*%include[[:space:]]+/etc/tor/damagebdd\.conf[[:space:]]*$' \
        "$OUTPUT_TORRC"; then
        {
            printf '\n'
            printf '%%include /etc/tor/damagebdd.conf\n'
        } >> "$OUTPUT_TORRC"
    fi
}

verify_tor_config() {
    command -v tor >/dev/null 2>&1 || return 1
    tor --verify-config -f "$TORRC" >/dev/null 2>&1
}

configure_tor() {
    # Arch packages currently do not necessarily depend on Tor. Other package
    # targets may intentionally install Damage without Tor. In those cases the
    # post-install hook must be a successful no-op.
    if ! command -v tor >/dev/null 2>&1; then
        log "Tor is not installed; skipping onion-service provisioning."
        return 0
    fi

    if [ ! -f "$TORRC" ]; then
        warn "Tor is installed but $TORRC is absent; leaving Tor configuration untouched."
        return 0
    fi

    if [ -L "$TORRC" ] || [ -L "$TOR_FRAGMENT" ]; then
        warn "Refusing symlinked Tor configuration paths; leaving Tor configuration untouched."
        return 0
    fi

    if [ ! -w "$TORRC" ] || [ ! -w /etc/tor ]; then
        warn "Tor configuration is not writable; leaving it untouched."
        return 0
    fi

    # If the host Tor configuration was already invalid, do not mutate it.
    # This avoids making an administrator's pre-existing Tor problem part of
    # the Damage package transaction.
    if ! verify_tor_config; then
        warn "Existing Tor configuration does not validate; skipping DamageBDD Tor configuration."
        return 0
    fi

    TMP_BASE=${TMPDIR:-/tmp}
    TORRC_TMP=$(mktemp "$TMP_BASE/damage-torrc.XXXXXX") || {
        warn "Cannot create temporary Tor configuration."
        return 0
    }
    FRAGMENT_TMP=$(mktemp "$TMP_BASE/damage-tor-fragment.XXXXXX") || {
        rm -f "$TORRC_TMP"
        warn "Cannot create temporary Tor fragment."
        return 0
    }
    TORRC_BACKUP=$(mktemp "$TMP_BASE/damage-torrc-backup.XXXXXX") || {
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP"
        warn "Cannot create Tor configuration backup."
        return 0
    }

    cp -p "$TORRC" "$TORRC_BACKUP" 2>/dev/null || {
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP"
        warn "Cannot back up $TORRC; leaving Tor configuration untouched."
        return 0
    }

    HAD_FRAGMENT=0
    FRAGMENT_BACKUP=
    if [ -f "$TOR_FRAGMENT" ]; then
        HAD_FRAGMENT=1
        FRAGMENT_BACKUP=$(mktemp "$TMP_BASE/damage-tor-fragment-backup.XXXXXX") || {
            rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP"
            warn "Cannot back up $TOR_FRAGMENT; leaving Tor configuration untouched."
            return 0
        }
        cp -p "$TOR_FRAGMENT" "$FRAGMENT_BACKUP" 2>/dev/null || {
            rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" "$FRAGMENT_BACKUP"
            warn "Cannot back up $TOR_FRAGMENT; leaving Tor configuration untouched."
            return 0
        }
    fi

    MIGRATE_OLD=0
    if [ -f "$OLD_TOR_FRAGMENT" ] && [ ! -L "$OLD_TOR_FRAGMENT" ]; then
        MIGRATE_OLD=1
    elif [ -L "$OLD_TOR_FRAGMENT" ]; then
        warn "Legacy Tor fragment is a symlink; refusing to remove it automatically."
    fi

    if ! write_tor_fragment "$FRAGMENT_TMP"; then
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
        warn "Cannot prepare DamageBDD Tor fragment."
        return 0
    fi

    if ! prepare_torrc "$TORRC" "$TORRC_TMP" "$MIGRATE_OLD"; then
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
        warn "Cannot prepare updated Tor configuration."
        return 0
    fi

    # Install the fragment first so the explicit include resolves during
    # validation, then atomically replace torrc content while preserving its
    # original ownership/mode via the existing file.
    if ! cp "$FRAGMENT_TMP" "$TOR_FRAGMENT"; then
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
        warn "Cannot install $TOR_FRAGMENT."
        return 0
    fi
    chmod 0644 "$TOR_FRAGMENT" 2>/dev/null || true

    if ! cat "$TORRC_TMP" > "$TORRC"; then
        cat "$TORRC_BACKUP" > "$TORRC" 2>/dev/null || true
        if [ "$HAD_FRAGMENT" -eq 1 ]; then
            cp -p "$FRAGMENT_BACKUP" "$TOR_FRAGMENT" 2>/dev/null || true
        else
            rm -f "$TOR_FRAGMENT"
        fi
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
        warn "Cannot update $TORRC; restored previous configuration."
        return 0
    fi

    if ! verify_tor_config; then
        cat "$TORRC_BACKUP" > "$TORRC" 2>/dev/null || true
        if [ "$HAD_FRAGMENT" -eq 1 ]; then
            cp -p "$FRAGMENT_BACKUP" "$TOR_FRAGMENT" 2>/dev/null || true
        else
            rm -f "$TOR_FRAGMENT"
        fi
        rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
        warn "DamageBDD Tor configuration did not validate; restored previous Tor configuration."
        return 0
    fi

    # Remove only our known legacy fragment after the new exact include
    # validates. Never remove the hidden-service directory or its key.
    if [ "$MIGRATE_OLD" -eq 1 ]; then
        rm -f "$OLD_TOR_FRAGMENT" 2>/dev/null || true
    fi

    rm -f "$TORRC_TMP" "$FRAGMENT_TMP" "$TORRC_BACKUP" ${FRAGMENT_BACKUP:+"$FRAGMENT_BACKUP"}
    log "Installed Tor configuration at $TOR_FRAGMENT."
    return 0
}

restart_tor() {
    TOR_SERVICE_KIND=
    TOR_SERVICE_NAME=

    # systemctl can exist in containers/chroots where systemd is not PID 1.
    # Only use it when the systemd runtime directory is present.
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl cat tor@default.service >/dev/null 2>&1; then
            TOR_SERVICE_KIND=systemd
            TOR_SERVICE_NAME=tor@default.service
        elif systemctl cat tor.service >/dev/null 2>&1; then
            TOR_SERVICE_KIND=systemd
            TOR_SERVICE_NAME=tor.service
        fi
    fi

    if [ -z "$TOR_SERVICE_KIND" ] && command -v rc-service >/dev/null 2>&1; then
        if rc-service tor status >/dev/null 2>&1 ||
           [ -x /etc/init.d/tor ]; then
            TOR_SERVICE_KIND=openrc
            TOR_SERVICE_NAME=tor
        fi
    fi

    if [ -z "$TOR_SERVICE_KIND" ] && command -v service >/dev/null 2>&1; then
        if [ -x /etc/init.d/tor ]; then
            TOR_SERVICE_KIND=sysv
            TOR_SERVICE_NAME=tor
        fi
    fi

    case "$TOR_SERVICE_KIND" in
        systemd)
            systemctl enable "$TOR_SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl reset-failed "$TOR_SERVICE_NAME" >/dev/null 2>&1 || true
            if systemctl is-active --quiet "$TOR_SERVICE_NAME"; then
                systemctl restart "$TOR_SERVICE_NAME" >/dev/null 2>&1 || {
                    warn "Could not restart $TOR_SERVICE_NAME; Tor provisioning will complete when Tor starts successfully."
                    return 1
                }
            else
                systemctl start "$TOR_SERVICE_NAME" >/dev/null 2>&1 || {
                    warn "Could not start $TOR_SERVICE_NAME; Tor provisioning will complete when Tor starts successfully."
                    return 1
                }
            fi
            ;;
        openrc)
            if ! rc-service tor restart >/dev/null 2>&1; then
                rc-service tor start >/dev/null 2>&1 || {
                    warn "Could not start Tor through OpenRC."
                    return 1
                }
            fi
            ;;
        sysv)
            if ! service tor restart >/dev/null 2>&1; then
                service tor start >/dev/null 2>&1 || {
                    warn "Could not start Tor through the service command."
                    return 1
                }
            fi
            ;;
        *)
            log "No active supported service manager; Tor configuration installed without starting Tor."
            return 1
            ;;
    esac

    return 0
}

publish_onion_hostname() {
    if ! have_user "$DAMAGE_USER" || ! have_group "$DAMAGE_GROUP"; then
        warn "Damage service identity is unavailable; cannot publish the onion hostname yet."
        return 0
    fi

    i=0
    while [ ! -s "$TOR_HS_DIR/hostname" ] && [ "$i" -lt 300 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if [ ! -s "$TOR_HS_DIR/hostname" ]; then
        warn "Tor has not generated $TOR_HS_DIR/hostname yet; package installation remains successful."
        return 0
    fi

    if ! cp "$TOR_HS_DIR/hostname" "$DAMAGE_TOR_STATE/hostname"; then
        warn "Cannot publish the Tor hostname into $DAMAGE_TOR_STATE."
        return 0
    fi

    chown "$DAMAGE_USER:$DAMAGE_GROUP" "$DAMAGE_TOR_STATE/hostname" 2>/dev/null || true
    chmod 0644 "$DAMAGE_TOR_STATE/hostname" 2>/dev/null || true

    ONION_HOST=$(tr -d '\r\n' < "$DAMAGE_TOR_STATE/hostname")
    case "$ONION_HOST" in
        *.onion)
            log "DamageBDD Onion address: http://$ONION_HOST/"
            ;;
        *)
            warn "Tor hostname is not a valid .onion name; leaving the copied value for diagnostics."
            ;;
    esac

    return 0
}

restart_damage_service() {
    # Restart only when a service manager is live and the package unit/service
    # is actually known. Never fail the package transaction for this.
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl cat damage.service >/dev/null 2>&1; then
            systemctl try-restart damage.service >/dev/null 2>&1 || true
        fi
    elif command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/damage ]; then
        rc-service damage restart >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/damage ]; then
        service damage restart >/dev/null 2>&1 || true
    fi
}

main() {
    # Native Termux and unusual non-root packaging environments must not be
    # broken by host-level /etc/tor provisioning.
    if [ "$(id -u)" -ne 0 ]; then
        log "Non-root package environment; skipping host Tor provisioning."
        exit 0
    fi

    prepare_damage_state

    if ! command -v tor >/dev/null 2>&1; then
        log "Tor is not installed; skipping onion-service provisioning."
        exit 0
    fi

    TOR_GROUP_FOUND=$(find_tor_group 2>/dev/null || true)
    if [ -n "$TOR_GROUP_FOUND" ]; then
        add_damage_to_tor_group "$TOR_GROUP_FOUND"
    else
        warn "Could not determine Tor service group; ControlPort cookie access may need administrator configuration."
    fi

    configure_tor

    # If configuration was skipped/rolled back, only restart Tor when our
    # fragment is actually installed and included.
    if [ ! -f "$TOR_FRAGMENT" ] ||
       ! grep -Eq '^[[:space:]]*%include[[:space:]]+/etc/tor/damagebdd\.conf[[:space:]]*$' "$TORRC" 2>/dev/null; then
        log "DamageBDD Tor configuration is not active; package installation will continue."
        exit 0
    fi

    if restart_tor; then
        publish_onion_hostname
        restart_damage_service
    fi

    # Tor provisioning is deliberately non-fatal. The package can be repaired
    # later by fixing Tor and restarting it without reinstalling DamageBDD.
    exit 0
}

main "$@"
