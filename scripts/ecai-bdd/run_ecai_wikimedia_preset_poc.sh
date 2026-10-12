#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FEATURE="$SCRIPT_DIR/ecai_wikimedia_preset_poc.feature"

: "${DAMAGEBDD_BASE_URL:?Set DAMAGEBDD_BASE_URL, e.g. https://run.dev.damagebdd.com}"
: "${DAMAGEBDD_TOKEN:?Set DAMAGEBDD_TOKEN to authorize the outer DamageBDD run}"

echo "==> Running ECAI preset POC through: $DAMAGEBDD_BASE_URL"
echo "==> ECAI target comes from the node's ecai.api_url setting"

curl --fail-with-body --no-buffer --silent --show-error \
  --request PUT "${DAMAGEBDD_BASE_URL%/}/execute_feature/" \
  --header "Authorization: Bearer $DAMAGEBDD_TOKEN" \
  --header "Content-Type: text/plain" \
  --data-binary @"$FEATURE"
