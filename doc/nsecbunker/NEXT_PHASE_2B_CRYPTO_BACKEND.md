# Next after signoff — Phase 2B crypto/backend boundary

Only start this after ClawDog approves the Phase 2A BDD contract.

## Goal

Implement the external crypto backend behind the fail-closed vault boundary.

The backend must provide:

- key generation inside the vault boundary
- public key derivation
- `npub` derivation
- NIP-44 decrypt/encrypt for NIP-46 payloads
- Nostr event ID verification
- Schnorr signing
- encrypted vault storage
- no `nsec` return path

## Recommended shape

A small Rust or Go executable called by the Erlang port boundary:

```erlang
crypto_backend_cmd => "/opt/damage/bin/damage-nsecbunker-crypto"
```

The Erlang layer keeps responsibility for:

- OTP supervision
- policy
- replay guard
- rate guard
- audit line generation
- relay adapter boundary
- BDD signoff enforcement

The backend keeps responsibility for:

- secrets
- crypto correctness
- encrypted vault material
- signature production

## Phase 2B estimate

1–2 working days depending on which backend library is selected and how much test-vector coverage is required.

## Phase 2B exit criteria

- backend executable installed
- `get_public_key` works from sealed/unsealed vault path
- generated public key matches vault state
- NIP-44 decrypt/encrypt test vectors pass
- Nostr signing test vectors pass
- DamageBDD Phase 2A contract still passes
- no `nsec` appears in logs, responses, crash dumps, or reports
