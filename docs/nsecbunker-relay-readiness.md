# NIP-46 relay readiness and external signing checks

Review baseline: repository `develop` at
`a13a88a3d8c784de0411523f1d829b72b8ead84d`. The adapter and readiness code at the
reported test release, `28a4047ece90d15f1ba94ece4a6b0fcbbf57b808`, were also
checked: both versions mark subscriptions ready on REQ send and ignore CLOSED.
This patch targets the newer baseline; it has not been deployed.

The live feature opens separate WebSocket connections for publication and reply
listening. It checks relay acceptance, adapter observation of the request event
ID, and a decrypted response. This is a real network path, but it uses the node's
`damage_nostr` identity and succeeds when at least one configured relay works.
It does not prove that an independent client's key and relay selection work.

Relevant implementation:

- `apps/damage/src/damage_nsecbunker_relay.erl`: persistent inbound sockets and response publication.
- `apps/damage/src/damage_nostr_relay_client.erl`: kind and recipient checks, bunker dispatch, response publication.
- `apps/damage/src/steps_nsecbunker_live.erl`: separate-connection black-box checks.
- `features/nsecbunker/generic_live_nsecbunker_operations.feature`: live acceptance scenarios.

## Readiness semantics

`request_sent` means the adapter sent `REQ`. `subscribed` becomes true only after
a matching `EOSE` or `EVENT` returns on that connection. This confirms relay
activity for the subscription; only a correlated signing round trip proves the
whole client path. The top-level `subscribed` field still means **any relay** is
confirmed. Inspect each entry in `connections` for individual relay readiness.

A matching `CLOSED` removes the connection from the healthy set and records its
reason in `retry_state`. Transient failures retry with backoff; authentication,
restriction, invalid-filter, and blocked responses require operator attention.
The confirmation timeout defaults to 15 seconds and can be changed with
`relay_subscription_timeout_ms`. Retry history resets on confirmation, not merely
when a socket opens.

An `AUTH` challenge is recorded as `auth_challenge_received` without retaining
the challenge. A challenge alone does not invalidate a subscription. This
adapter does not implement NIP-42 authentication; a relay that closes the
subscription with `auth-required:` is not usable through this adapter until that
capability or the agreed relay configuration changes. Do not expand the signing
policy merely to make a relay test pass.

The BDD readiness step now only observes startup state. It no longer calls
`subscribe()` and thereby repairs missing startup wiring before testing it.

## Check the deployed node before changing relays

Capture this public routing subset from an attached Erlang shell:

```erlang
RoutingKeys = [relays, relay_client_enabled, relay_autosubscribe,
               relay_publication_mode, require_inbound_p_tag, bunker_pubkey_hex,
               relay_subscribe_mfa, relay_publish_mfa],
maps:with(RoutingKeys, damage_nsecbunker:config()).

BridgeStatus = damage_nostr_relay_client:status(),
maps:with(RoutingKeys, maps:get(config, BridgeStatus, #{})).

damage_nsecbunker_relay:status().
```

The bridge caches its configuration at startup. A bunker-only reload or an
application-environment edit does not update that cached bridge configuration.
After changing persistent deployment configuration, restart the bunker subtree
or service through the normal deployment procedure, then inspect readiness
**before** running the feature. This patch does not deploy or restart a service.

## Proposed routing configuration for the shared smoke test

Merge these fields into the existing `damage` application's `nsecbunker` config.
Keep the custody provider, vault, authorization, and signing policy settings.
Use the same agreed relay URLs on both the bunker and client:

```erlang
{relay_client_enabled, true},
{relay_autosubscribe, true},
{relay_publication_mode, normal},
{require_inbound_p_tag, true},
{bunker_pubkey_hex,
 "e55bc4b82dbd981262dc8d351e4e01e586e2c45189c26881f23f2d4176ed4535"},
{relays, [
    #{url => "wss://relay.damus.io", profile => cloudflare_browser, proxy => direct},
    #{url => "wss://relay.primal.net", profile => primal, proxy => direct},
    #{url => "wss://nos.lol"}
]},
{relay_subscribe_mfa, {damage_nsecbunker_relay, subscribe}},
{relay_publish_mfa, {damage_nsecbunker_relay, publish_event}}
```

These are the relays named in the external test, not a claim that they are
currently healthy. The sample `config/sys.config.sample` has the relay client
disabled and publication set to `return_only`; copying those sample values into
production will not establish a working public signing path.

Verify that the existing authorization list includes the corrected client key:
`4b81f037343f30a30ca1da52d13b5a78ef4d1c0e44375823c019981bb460830f`.

## External acceptance evidence

1. Record the deployed release SHA and the routing readback above after restart.
2. Test each agreed relay separately with a fresh request event ID and request
   payload ID. Subscribe for replies before publishing: kind 24133 is ephemeral.
3. Use the authorized external client for `ping`, `get_public_key`, then
   `sign_event` for allowed kind 30023. The request must use NIP-44 encryption and
   a `p` tag addressed to the bunker. Verify the response author, recipient,
   decrypted request ID, and returned event signature.
4. Record each relay's `OK` acceptance/rejection, the request event ID and UTC
   timestamp, adapter observation of that ID, dispatch result, and reply event
   ID. An open WebSocket or publish `OK` alone is not an end-to-end pass.
5. If the adapter never observes the request, investigate relay selection,
   subscription state, filtering, and relay rejection. If it does observe it,
   follow the same event ID through decryption, policy, and reply publication.

A valid decryptable request from an unauthorized key should follow the policy
error-response path. It cannot establish successful authorized signing. A
decryption or payload-decode error is returned internally and is not published
as a NIP-46 response by the bridge, so client silence is not proof of a missing
subscription by itself.

Keep separate acceptance records for step 7 (AWSPENDING to AWSCURRENT rehearsal),
step 8 (vault backup/restore), step 9 (META/010), and the DETS passphrase
delete-then-restart scenario. The existing green signing report does not replace
those records.

## Validation

Run the adapter regression tests and existing bridge contract tests:

```sh
rebar3 eunit --module=damage_nsecbunker_relay,damage_nsecbunker_phase3_relay_tests
```

Then run the live feature and the external checks above on the intended release.
The patch's local review included whitespace and clean-application checks.
Erlang/EUnit and the live node were unavailable in the review environment; the
new regression tests and public-relay behavior require execution before rollout.

Protocol references: [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md),
[NIP-42](https://github.com/nostr-protocol/nips/blob/master/42.md), and
[NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md).
