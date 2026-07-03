#!/usr/bin/env sh
set -eu
export DAMAGE_NSECBUNKER_CRYPTO_CMD="${DAMAGE_NSECBUNKER_CRYPTO_CMD:-$PWD/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c}"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase2c-eunit-passphrase}"
rebar3 eunit --module=damage_nsecbunker_phase2c_vector_tests
