#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/../../priv/crypto/damage-nsecbunker-crypto-c"
make clean all
