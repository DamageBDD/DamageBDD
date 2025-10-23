#!/bin/sh
set -e
set -x
KEY_PATH="${VAR_DIR}/ssh_daemon/ssh_host_rsa_key"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"

# Generate key only if missing
if [ ! -f "$KEY_PATH" ]; then
    echo "[INFO] Generating new SSH host key: $KEY_PATH"
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N ""
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
else
    echo "[INFO] SSH host key already exists at $KEY_PATH — skipping generation."
fi

exit 0
