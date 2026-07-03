#!/usr/bin/env sh
set -eu
: "${AUTH_TOKEN:?AUTH_TOKEN is required}"
FEATURE="features/nsecbunker/phase2c_crypto_vector_hardening.feature"
curl -sS -v --data-binary @"$FEATURE" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  https://run.dev.damagebdd.com/execute_feature
