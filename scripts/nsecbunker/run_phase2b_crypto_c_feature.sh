#!/usr/bin/env sh
set -eu
: "${AUTH_TOKEN:?set AUTH_TOKEN for run.dev.damagebdd.com}"
curl -sS -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  --data-binary @features/nsecbunker/phase2b_crypto_backend_c.feature \
  https://run.dev.damagebdd.com/execute_feature
