#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/../.."
cd priv/crypto/damage-nsecbunker-crypto-c
make clean
make
