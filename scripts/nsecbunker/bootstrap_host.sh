#!/usr/bin/env sh
set -eu

SERVICE_USER="${SERVICE_USER:-damage}"
STATE_DIR="${STATE_DIR:-/var/lib/damage/nsecbunker}"
LOG_DIR="${LOG_DIR:-/var/log/damage}"
CRYPTO_DIR="${CRYPTO_DIR:-/opt/damage/bin}"

sudo install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
sudo install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$LOG_DIR"
sudo install -d -m 0755 -o root -g root "$CRYPTO_DIR"

sudo touch "$LOG_DIR/nsecbunker_audit.log"
sudo chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR/nsecbunker_audit.log"
sudo chmod 0640 "$LOG_DIR/nsecbunker_audit.log"

echo "Prepared Damage nsecbunker paths:"
echo "  vault state: $STATE_DIR"
echo "  audit log:   $LOG_DIR/nsecbunker_audit.log"
echo "  backend:     $CRYPTO_DIR/damage-nsecbunker-crypto"
