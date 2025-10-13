#!/bin/sh
set -e
set -x

SERVICE_NAME="$PKG_NAME"
INSTALL_DIR="${PREFIX}/{{app}}/"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "[postinst] Installing systemd service for $SERVICE_NAME..."

# Create the service unit file
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Damage Node
After=network.target

[Service]
Type=simple
User=damage
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/bin/damage foreground
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Ensure correct permissions
chmod 644 "$SERVICE_FILE"

# Reload systemd to pick up the new unit
systemctl daemon-reload

# Enable and start the service
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "[postinst] Systemd service for $SERVICE_NAME installed and started."
