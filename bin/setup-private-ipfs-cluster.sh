#!/bin/bash
set -e

# Variables
IPFS_USER="ipfs"
IPFS_HOME="/var/lib/ipfs"
IPFS_PATH="/etc/ipfs"
CLUSTER_PATH="/etc/ipfs-cluster"
SWARM_KEY_PATH="$IPFS_PATH/swarm.key"
CLUSTER_SECRET_PATH="$CLUSTER_PATH/service.json"

# Ensure dependencies are installed
echo "[*] Installing IPFS and IPFS Cluster..."
sudo pacman -Syu --noconfirm go-ipfs
yay -S --noconfirm ipfs-cluster-service ipfs-cluster-ctl

# Create system user
echo "[*] Creating ipfs system user..."
sudo useradd -r -m -d $IPFS_HOME -s /usr/bin/nologin $IPFS_USER || true

# Create config directories
sudo mkdir -p $IPFS_PATH $CLUSTER_PATH
sudo chown -R $IPFS_USER:$IPFS_USER $IPFS_PATH $CLUSTER_PATH

# Initialize IPFS
echo "[*] Initializing IPFS..."
sudo -u $IPFS_USER env IPFS_PATH=$IPFS_PATH ipfs init

# Generate and place swarm.key
echo "[*] Generating swarm.key..."
sudo -u $IPFS_USER env IPFS_PATH=$IPFS_PATH ipfs-swarm-key-gen > /tmp/swarm.key
sudo mv /tmp/swarm.key $SWARM_KEY_PATH
sudo chown $IPFS_USER:$IPFS_USER $SWARM_KEY_PATH
sudo chmod 600 $SWARM_KEY_PATH

# Initialize IPFS Cluster
echo "[*] Initializing IPFS Cluster..."
sudo -u $IPFS_USER env IPFS_CLUSTER_PATH=$CLUSTER_PATH \
  ipfs-cluster-service init

# Create systemd service for IPFS
echo "[*] Creating systemd service for IPFS..."
cat <<EOF | sudo tee /etc/systemd/system/ipfs.service
[Unit]
Description=IPFS daemon
After=network.target

[Service]
User=$IPFS_USER
Group=$IPFS_USER
Environment=IPFS_PATH=$IPFS_PATH
ExecStart=/usr/bin/ipfs daemon
Restart=always
LimitNOFILE=10240

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for IPFS Cluster
echo "[*] Creating systemd service for IPFS Cluster..."
cat <<EOF | sudo tee /etc/systemd/system/ipfs-cluster.service
[Unit]
Description=IPFS Cluster daemon
After=network.target ipfs.service
Requires=ipfs.service

[Service]
User=$IPFS_USER
Group=$IPFS_USER
Environment=IPFS_PATH=$IPFS_PATH
Environment=IPFS_CLUSTER_PATH=$CLUSTER_PATH
ExecStart=/usr/bin/ipfs-cluster-service daemon
Restart=always
LimitNOFILE=10240

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
echo "[*] Enabling and starting services..."
sudo systemctl daemon-reexec
sudo systemctl enable --now ipfs
sudo systemctl enable --now ipfs-cluster

echo "[✔] Setup complete!"
echo "Swarm Key: $SWARM_KEY_PATH"
echo "IPFS Config: $IPFS_PATH"
echo "Cluster Config: $CLUSTER_PATH"
