# Phase 4A — dev DamageBDD key rehearsal

Goal: create a disposable dev DamageBDD nsecbunker identity inside the C backend vault.

Invariants:

- dev-only key
- generated inside vault/backend boundary
- `nsec` never printed, returned, logged, committed, or sent over chat
- only `pubkey_hex` and `npub` are exported
- dev vault is not reused for Phase 4B

Commands:

```sh
scripts/nsecbunker/build_phase2c_crypto_c_backend.sh

export DAMAGE_NSECBUNKER_DEV_VAULT="$PWD/.damage-nsecbunker/dev_damagebdd.vault"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE='dev-only-change-me'

RESET_DEV_VAULT=1 scripts/nsecbunker/phase4a_create_dev_damagebdd_key.sh
```

Next after key creation:

1. Put the dev `pubkey_hex` into the Phase 4A dev config.
2. Start Damage with `nsecbunker.enabled => true`.
3. Keep `relay_client_enabled => false` until local status checks pass.
4. Run disposable-key rehearsal.
5. Only after Phase 4A passes, prepare Phase 4B production key ceremony.
