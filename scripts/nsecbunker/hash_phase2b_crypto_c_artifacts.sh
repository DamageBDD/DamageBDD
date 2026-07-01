#!/usr/bin/env sh
set -eu
find priv/crypto/damage-nsecbunker-crypto-c apps/damage/src config doc/nsecbunker features/nsecbunker scripts/nsecbunker \
  -type f | sort | xargs sha256sum
