# Phase 3 — relay and encrypted NIP46 path

## Goal

Complete the relay-facing NIP46 path with disposable keys:

```text
relay kind:24133 request
  -> damage_nostr_relay_client
  -> damage_nsecbunker:handle_nip46_event/1
  -> NIP44 decrypt via C backend
  -> guards/policy
  -> sign allowed event
  -> NIP44 encrypted response
  -> signed kind:24133 response event
  -> relay publication adapter
```

## Invariant

The signing decision is independent of relay publication.

A relay failure may produce:

```erlang
{ok, #{signing_result := ok, publish_result := {error, _}}}
```

It must not erase the signed response event or change the bunker decision.

## Live disposable test order

1. Generate disposable bunker identity.
2. Configure disposable client pubkey in `authorized_clients`.
3. Set `relay_client_enabled => true`.
4. Test with `relay_publication_mode => return_only` first.
5. Run EUnit.
6. Run DamageBDD Phase 3 feature.
7. Switch to `relay_publication_mode => normal`.
8. Wire `relay_publish_mfa` / `relay_subscribe_mfa` if automatic detection is not enough.
9. Test `connect`, `ping`, `get_public_key`, `sign_event` over relays.
10. Do not use LodgeiT production key material.

## Completion criteria

- Subscription filter includes `kind:24133`.
- Subscription filter is p-tagged to bunker pubkey.
- Inbound non-24133 event is rejected.
- Inbound event not p-tagged to bunker is rejected when required.
- Signed response event is returned to relay layer.
- Relay publication result is recorded separately.
- Relay publication failure does not change signing decision.
- DamageBDD Phase 3 feature passes.
