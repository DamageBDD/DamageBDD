#!/usr/bin/env sh
set -eu

: "${AUTH_TOKEN:?AUTH_TOKEN is required}"

FEATURE="${1:-features/nsecbunker/phase4a_dev_key_rehearsal.feature}"
RUNNER="${DAMAGEBDD_RUNNER:-https://run.dev.damagebdd.com/execute_feature}"

# Defaults for the BDD step module. Override if needed.
export DAMAGE_NSECBUNKER_DEV_VAULT="${DAMAGE_NSECBUNKER_DEV_VAULT:-/tmp/damage-nsecbunker-phase4a-dev-bdd.vault}"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase4a-bdd-dev-passphrase}"
export RESET_DEV_VAULT="${RESET_DEV_VAULT:-1}"

curl -v --data-binary @"$FEATURE" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "$RUNNER"
