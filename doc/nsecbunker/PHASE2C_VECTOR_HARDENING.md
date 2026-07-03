# Phase 2C — crypto vector hardening

Phase 2B proved the process boundary: Damage OTP can call an external C crypto backend, receive structured JSON envelopes, and fail closed on malformed responses.

Phase 2C proves protocol semantics before any LodgeiT key ceremony.

## Scope

Included in this phase:

- BIP340 Schnorr signing vector operation
- BIP340 Schnorr verification operation
- NIP-01 event id vector operation
- NIP-19 `npub` vector operation
- real NIP-44 v2 encrypt/decrypt implementation
- NIP-44 v2 official vector 0 checks
- vault wrong-passphrase fail-closed check
- production guard against Phase 2B plain NIP44 loopback

Still out of scope:

- relay wiring
- production key ceremony
- LodgeiT bank-back
- HSM or hardware key integration

## Backend operations added

```json
{"op":"event_id","pubkey_hex":"...","event":{}}
{"op":"schnorr_sign_vector","secret_key_hex":"...","message_hex":"...","aux_rand_hex":"..."}
{"op":"schnorr_verify","pubkey_hex":"...","message_hex":"...","signature_hex":"..."}
{"op":"nip44_encrypt_vector","secret_key_hex":"...","peer_pubkey_hex":"...","nonce_hex":"...","plaintext":"..."}
{"op":"nip44_decrypt_vector","secret_key_hex":"...","peer_pubkey_hex":"...","payload":"..."}
{"op":"plain_mode_status"}
```

Existing production-path operations now use real NIP-44 v2 unless the explicit test-only plain loopback is enabled:

```json
{"op":"nip44_encrypt","vault_path":"...","client_pubkey":"...","plaintext":"..."}
{"op":"nip44_decrypt","vault_path":"...","client_pubkey":"...","ciphertext":"..."}
```

## Test sequence

```sh
scripts/nsecbunker/build_phase2c_crypto_c_backend.sh
scripts/nsecbunker/smoke_phase2c_crypto_vectors.sh

export DAMAGE_NSECBUNKER_CRYPTO_CMD="$PWD/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE='phase2c-eunit-passphrase'
scripts/nsecbunker/run_phase2c_crypto_eunit.sh

export AUTH_TOKEN='...'
scripts/nsecbunker/run_phase2c_crypto_feature.sh
```

## Completion criteria

Phase 2C is not complete until all of the following pass:

- local C vector smoke
- EUnit vector tests
- DamageBDD Phase 2C feature
- artifact manifest is committed
- ClawDog report hash is recorded

## Security notes

The old Phase 2B plain NIP44 loopback is now test-only. It is blocked when:

```sh
DAMAGE_NSECBUNKER_PRODUCTION=1
```

Do not generate the real LodgeiT key until Phase 2C and Phase 3 both pass with disposable keys.
