#!/bin/sh
set -e

KUBO_VERSION="v0.38.2"
ARCH="linux-amd64"
KUBO_TARBALL="kubo_${KUBO_VERSION}_${ARCH}.tar.gz"
KUBO_URL="https://dist.ipfs.tech/kubo/${KUBO_VERSION}/${KUBO_TARBALL}"

IPFS_USER="ipfs"
IPFS_HOME="/var/lib/ipfs"
IPFS_BIN="/usr/local/bin/ipfs"

log() {
    echo "[postinst] $1"
}

# Helper: detect if ipfs exists anywhere in path or at install location
ipfs_exists() {
    if command -v ipfs >/dev/null 2>&1; then
        return 0
    fi
    if [ -x "$IPFS_BIN" ]; then
        return 0
    fi
    return 1
}

case "${1:-configure}" in
    configure)
        log "Checking for existing ipfs installation ..."

        if ipfs_exists; then
            FOUND=$(command -v ipfs 2>/dev/null || echo "$IPFS_BIN")
            log "ipfs already installed at: $FOUND"
            log "Skipping kubo installation."
        else
            log "No existing ipfs found. Installing Kubo $KUBO_VERSION ..."

            # Create system user
            if ! id -u $IPFS_USER >/dev/null 2>&1; then
                log "Creating system user: $IPFS_USER"
                adduser --system --group --home $IPFS_HOME $IPFS_USER
            fi

            # Create download directory
            TMPDIR=$(mktemp -d)
            cd "$TMPDIR"

            log "Downloading kubo from $KUBO_URL"
            wget -q "$KUBO_URL"

            log "Extracting $KUBO_TARBALL"
            tar -xzf "$KUBO_TARBALL"

            cd kubo

            log "Running kubo install.sh"
            bash install.sh

            log "Ensuring $IPFS_BIN is executable"
            chmod 755 "$IPFS_BIN"

            log "Cleaning up temporary files"
            rm -rf "$TMPDIR"

            log "Kubo binaries installed."
        fi

        # Ensure permissions
        chown -R $IPFS_USER:$IPFS_USER $IPFS_HOME || true

        # Initialize IPFS repo if first install
        if [ ! -d "$IPFS_HOME/.ipfs" ]; then
            log "Initializing IPFS repo in $IPFS_HOME"
            su -s /bin/sh -c "$IPFS_BIN init --profile=server" $IPFS_USER
        else
            log "IPFS repo already exists, skipping init."
        fi

        # Install systemd service (idempotently)
        log "Installing/updating systemd service"

        cat <<EOF >/etc/systemd/system/ipfs.service
[Unit]
Description=IPFS daemon
After=network.target

[Service]
User=$IPFS_USER
Group=$IPFS_USER
Environment=IPFS_PATH=$IPFS_HOME/.ipfs
ExecStart=$IPFS_BIN daemon --migrate=true
Restart=always
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable ipfs.service >/dev/null 2>&1 || true

        log "Kubo installation/configuration complete."
        ;;

    abort-upgrade|abort-remove|abort-deconfigure)
        log "Abort state detected, nothing to do."
        ;;

    *)
        log "Unknown argument $1"
        ;;
esac

exit 0

