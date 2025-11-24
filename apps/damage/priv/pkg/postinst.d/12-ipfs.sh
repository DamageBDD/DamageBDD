#!/bin/sh
set -e

KUBO_VERSION="v0.38.2"
ARCH="linux-amd64"
KUBO_TARBALL="kubo_${KUBO_VERSION}_${ARCH}.tar.gz"
KUBO_URL="https://dist.ipfs.tech/kubo/${KUBO_VERSION}/${KUBO_TARBALL}"

IPFS_USER="ipfs"
IPFS_HOME="/var/lib/ipfs"

log() {
    echo "[postinst] $1"
}

log "Postinst starting..."

# ----------------------------------------------------------------------
# 1. Create system user (always needed)
# ----------------------------------------------------------------------
if ! id -u $IPFS_USER >/dev/null 2>&1; then
    log "Creating system user: $IPFS_USER"
    adduser --system --group --home $IPFS_HOME $IPFS_USER
fi

# ----------------------------------------------------------------------
# 2. Install IPFS ONLY IF NOT PRESENT
# ----------------------------------------------------------------------
if command -v ipfs >/dev/null 2>&1; then
    log "ipfs binary already present – skipping Kubo install."
else
    log "ipfs not found – installing Kubo $KUBO_VERSION ..."

    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"

    log "Downloading kubo from $KUBO_URL"
    wget -q "$KUBO_URL"

    log "Extracting $KUBO_TARBALL"
    tar -xzf "$KUBO_TARBALL"
    cd kubo

    log "Running kubo install.sh"
    bash install.sh

    log "Ensuring /usr/local/bin/ipfs is executable"
    chmod 755 /usr/local/bin/ipfs

    log "Cleaning up temporary files"
    rm -rf "$TMPDIR"
fi

# ----------------------------------------------------------------------
# 3. Initialize repo if needed
# ----------------------------------------------------------------------
if [ ! -d "$IPFS_HOME/.ipfs" ]; then
    log "Initializing IPFS repo in $IPFS_HOME"
    su -s /bin/sh -c "/usr/local/bin/ipfs init --profile=server" $IPFS_USER
fi

# Ensure permissions
chown -R $IPFS_USER:$IPFS_USER $IPFS_HOME

# ----------------------------------------------------------------------
# 4. Install systemd service (always refresh to ensure correct config)
# ----------------------------------------------------------------------
log "Installing systemd service"
cat <<EOF >/etc/systemd/system/ipfs.service
[Unit]
Description=IPFS daemon
After=network.target

[Service]
User=$IPFS_USER
Group=$IPFS_USER
Environment=IPFS_PATH=$IPFS_HOME/.ipfs
ExecStart=/usr/local/bin/ipfs daemon --migrate=true
Restart=always
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipfs.service

log "Kubo setup complete."
exit 0

