#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
sha256sum \
  priv/crypto/damage-nsecbunker-crypto-c/src/main.c \
  apps/damage/src/steps_nsecbunker_crypto.erl \
  apps/damage/test/damage_nsecbunker_phase2c_vector_tests.erl \
  features/nsecbunker/phase2c_crypto_vector_hardening.feature \
  scripts/nsecbunker/smoke_phase2c_crypto_vectors.sh \
  doc/nsecbunker/PHASE2C_VECTOR_HARDENING.md \
  > MANIFEST.phase2c.sha256
cat MANIFEST.phase2c.sha256
