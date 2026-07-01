#!/usr/bin/env sh
set -eu
export DAMAGE_NSECBUNKER_CRYPTO_CMD="${DAMAGE_NSECBUNKER_CRYPTO_CMD:-$PWD/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c}"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase2b-c-eunit-passphrase}"
export DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44=1
rebar3 eunit --module=damage_nsecbunker_phase2b_crypto_backend_tests
