#!/usr/bin/env sh
set -eu
SRC="$(cd "$(dirname "$0")/../../priv/crypto/damage-nsecbunker-crypto-c" && pwd)/damage-nsecbunker-crypto-c"
DEST="${DEST:-/opt/damage/bin/damage-nsecbunker-crypto-c}"
install -m 0755 "$SRC" "$DEST"
echo "installed $DEST"
