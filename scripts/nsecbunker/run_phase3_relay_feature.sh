#!/usr/bin/env sh
set -eu
: "${AUTH_TOKEN:?AUTH_TOKEN is required}"

curl -sS -v \
  --data-binary @features/nsecbunker/phase3_relay_nip46_path.feature \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  "https://run.dev.damagebdd.com/execute_feature"
