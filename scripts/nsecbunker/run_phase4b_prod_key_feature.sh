#!/usr/bin/env bash
set -euo pipefail

: "${AUTH_TOKEN:?Set AUTH_TOKEN for run.dev.damagebdd.com}"
FEATURE="${1:-features/nsecbunker/phase4b_damagebdd_node_production_key.feature}"

curl -v --data-binary "@$FEATURE" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  https://run.dev.damagebdd.com/execute_feature
