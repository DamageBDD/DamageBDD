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

log "Installing Kubo $KUBO_VERSION ..."

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

log "Ensuring /usr/local/bin/ipfs is executable"
chmod 755 /usr/local/bin/ipfs

# Initialize IPFS repo if first install
if [ ! -d "$IPFS_HOME/.ipfs" ]; then
    log "Initializing IPFS repo in $IPFS_HOME"
    su -s /bin/sh -c "/usr/local/bin/ipfs init --profile=server" $IPFS_USER
fi

# Set permissions
chown -R $IPFS_USER:$IPFS_USER $IPFS_HOME

# Install systemd service
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

log "Cleaning up"
rm -rf "$TMPDIR"

log "Kubo installation complete."

exit 0
