#!/usr/bin/env sh
set -eu

: "${AUTH_TOKEN:?Set AUTH_TOKEN for run.dev.damagebdd.com}"

FEATURE="features/nsecbunker/phase2b_crypto_backend.feature"

curl -sS -v \
  --data-binary "@$FEATURE" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "https://run.dev.damagebdd.com/execute_feature"
