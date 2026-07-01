#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
export DAMAGE_NSECBUNKER_CRYPTO_CMD="${DAMAGE_NSECBUNKER_CRYPTO_CMD:-$ROOT/priv/crypto/damage-nsecbunker-crypto/target/release/damage-nsecbunker-crypto}"
export DAMAGE_NSECBUNKER_TEST_VAULT="${DAMAGE_NSECBUNKER_TEST_VAULT:-/tmp/damage-nsecbunker-phase2b-eunit.vault}"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase2b-eunit-passphrase}"

rebar3 eunit --module=damage_nsecbunker_phase2b_crypto_backend_tests
