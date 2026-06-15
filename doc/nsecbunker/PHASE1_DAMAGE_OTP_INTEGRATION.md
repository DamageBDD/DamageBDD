# Phase 1 — Damage OTP integration

This patch integrates `damage_nsecbunker` into the existing `damage` OTP app. It does not define a new OTP application or standalone release.

## Files added

```text
apps/damage/src/damage_nsecbunker_sup.erl
apps/damage/src/damage_nsecbunker.erl
apps/damage/src/damage_nsecbunker_policy.erl
apps/damage/src/damage_nsecbunker_gate.erl
apps/damage/src/damage_nsecbunker_rate.erl
apps/damage/src/damage_nsecbunker_replay.erl
apps/damage/src/damage_nsecbunker_audit.erl
apps/damage/src/damage_nsecbunker_signing_guard.erl
apps/damage/src/damage_nsecbunker_vault_guard.erl
apps/damage/src/damage_nsecbunker_vault.erl
apps/damage/src/damage_nip46.erl
apps/damage/src/damage_nostr_event.erl
apps/damage/src/damage_nostr_relay_client.erl
```

## Supervisor integration

Add this to the existing `damage_sup` child list:

```erlang
damage_nsecbunker_sup:child_spec()
```

The supervisor reads:

```erlang
application:get_env(damage, nsecbunker)
```

When `enabled => false`, it starts no child workers. When true, it starts:

- `damage_nsecbunker_replay`
- `damage_nsecbunker_rate`
- `damage_nsecbunker`
- optionally `damage_nostr_relay_client` if `relay_client_enabled => true`

## Fail-closed default

The vault remains sealed unless:

1. `crypto_backend_cmd` or `crypto_port_cmd` is configured,
2. the configured executable exists,
3. `bunker_pubkey_hex` is a real 64-character hex pubkey,
4. the request passes vault, policy, replay, rate and signing timeout gates.

Until then, NIP-46 requests produce error responses rather than signatures.

## Config

Merge `config/sys.config.nsecbunker.fragment.config` under the existing `damage` app environment.

Start with:

```erlang
enabled => false
```

Then get Phase 0 ClawDog signoff on expected BDD behaviour. Only then set:

```erlang
enabled => true
```

## BDD/plain request hook

For BDD tests that should not involve relay encryption yet, use:

```erlang
damage_nsecbunker:handle_plain_request(#{
    requester_pubkey => <<"AUTHORISED_CLIENT_PUBKEY_HEX">>,
    request_id => <<"bdd-001">>,
    method => <<"ping">>,
    created_at => erlang:system_time(second),
    params => []
}).
```

For real NIP-46 relay events, use:

```erlang
damage_nsecbunker:handle_nip46_event(Event).
```

## Crypto backend contract preview

The phase-1 vault calls an external executable with one JSON request on stdin and expects one JSON response on stdout:

```json
{"ok": true, "result": {}}
```

Required operations are:

- `generate_identity`
- `get_public_key`
- `npub`
- `nip44_decrypt`
- `nip44_encrypt`
- `sign_event`

Implementation of that backend belongs to Phase 2.
