#!/bin/bash
set -e

# Variables
IPFS_USER="ipfs"
IPFS_DATA="/var/lib/ipfs"
IPFS_CONFIG="/etc/ipfs"
IPFS_EXEC="/usr/bin/ipfs"

echo "[*] Bootstrapping system-wide IPFS node..."

# Install IPFS
echo "[*] Installing go-ipfs..."
sudo pacman -Sy --needed --noconfirm go-ipfs

# Create system user if it doesn't exist
if ! id $IPFS_USER &>/dev/null; then
  echo "[*] Creating system user '$IPFS_USER'..."
  sudo useradd -r -m -d $IPFS_DATA -s /usr/bin/nologin $IPFS_USER
fi

# Create config and data directories
echo "[*] Setting up config at $IPFS_CONFIG and data at $IPFS_DATA..."
sudo mkdir -p $IPFS_CONFIG $IPFS_DATA
sudo chown -R $IPFS_USER:$IPFS_USER $IPFS_CONFIG $IPFS_DATA

# Temporary HOME to make IPFS init place config and data separately
TMP_HOME="$IPFS_DATA/init-home"
sudo mkdir -p "$TMP_HOME"
sudo chown -R $IPFS_USER:$IPFS_USER "$TMP_HOME"


echo "[*] Initializing IPFS with split config/data..."
sudo -u $IPFS_USER HOME=$TMP_HOME IPFS_PATH=$IPFS_CONFIG $IPFS_EXEC init

# Move data repo (blocks, datastore, etc.) to /var/lib/ipfs
echo "[*] Moving data files to $IPFS_DATA..."
sudo mv "$IPFS_CONFIG"/blocks "$IPFS_DATA"
sudo mv "$IPFS_CONFIG"/datastore "$IPFS_DATA"
sudo mv "$IPFS_CONFIG"/keystore "$IPFS_DATA"
sudo mv "$IPFS_CONFIG"/version "$IPFS_DATA"

# Symlink data back to config path
echo "[*] Symlinking data directories to keep IPFS happy..."
sudo -u $IPFS_USER ln -s $IPFS_DATA/blocks $IPFS_CONFIG/blocks
sudo -u $IPFS_USER ln -s $IPFS_DATA/datastore $IPFS_CONFIG/datastore
sudo -u $IPFS_USER ln -s $IPFS_DATA/keystore $IPFS_CONFIG/keystore
sudo -u $IPFS_USER ln -s $IPFS_DATA/version $IPFS_CONFIG/version

# Clean up temp
rm -rf "$TMP_HOME"

# Create systemd service
echo "[*] Creating systemd unit..."
sudo tee /etc/systemd/system/ipfs.service > /dev/null <<EOF
[Unit]
Description=IPFS daemon
After=network.target

[Service]
User=$IPFS_USER
Group=$IPFS_USER
ExecStart=$IPFS_EXEC daemon
Environment=IPFS_PATH=$IPFS_CONFIG
Restart=always
LimitNOFILE=10240

[Install]
WantedBy=multi-user.target
EOF

# Enable + start service
echo "[*] Starting systemd service..."
sudo systemctl daemon-reexec
sudo systemctl enable --now ipfs

echo "[✅] IPFS is now running system-wide"
echo "Config: $IPFS_CONFIG"
echo "Data:   $IPFS_DATA"

