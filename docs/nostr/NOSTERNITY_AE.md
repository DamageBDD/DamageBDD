# Nosternity Aeternity Event Store

This patch adds an opt-in Aeternity-backed event store to the `nosternity` application while keeping generic Aeternity contract lifecycle plumbing in `damage`.

## Layout

- `apps/damage/src/damage_ae_contract.erl`
  - Generic application-owned contract source resolution, configured/runtime contract IDs, optional deployment, tracked writes and dry-run reads.
- `apps/damage/src/damage_nostr_event.erl`
  - Shared canonical Nostr event-id and BIP-340 signature verification.
- `apps/nosternity/priv/contracts/NostrEventStore.aes`
  - Nosternity-owned append-only Sophia contract. Full events are stored by id, globally indexed by insertion order, and indexed per kind.
- `apps/nosternity/src/nosternity_event_store.erl`
  - Policy, queueing, batching, retries, deployment/config resolution, reads and decoded paged scans.
- `apps/nosternity/src/nosternity_relay.erl`
  - Deduplicates events, sends selected events asynchronously to the chain store, and rehydrates ETS from the chain after restart.
- `apps/nosternity/src/nosternity_sup.erl`
  - Supervises the event store and relay.
- `apps/nosternity/src/nosternity_app.erl`
  - Uses the actual `nosternity_websocket` module in the Cowboy route.
- `apps/nosternity/src/nosternity_websocket.erl`
  - Uses `nosternity_relay` and reports rejected publishes rather than crashing on `{error, Reason}`.
- `apps/nosternity/test/nosternity_event_store_tests.erl`
  - Signature, tamper detection, policy and size-limit tests.

## Configuration

See `config/nosternity_event_store.config.example`.

The feature is disabled by default. The default persisted kinds are:

- `1` — text notes/posts
- `7` — reactions
- `30023` — long-form articles

`ae_event_store_kinds` also accepts the aliases `posts`, `reactions`, and `articles`. Use `all` to archive every valid kind.

For a public relay, configure `ae_event_store_pubkeys` as an allow-list unless intentionally paying AE fees for arbitrary public writers.

Production should normally deploy `NostrEventStore.aes` once and configure:

```erlang
{ae_event_store_enabled, true},
{ae_event_store_contract, "ct_..."},
{ae_event_store_auto_deploy, false}
```

`ae_event_store_auto_deploy` is intended for development/bootstrap. Its discovered address is remembered only for the current VM; put the resulting `ct_...` address in persistent application configuration before relying on it across restarts.

## Runtime API

```erlang
nosternity_event_store:status().
nosternity_event_store:contract_id().
nosternity_event_store:exists(EventId).
nosternity_event_store:get_event(EventId).
nosternity_event_store:get_event_count().
nosternity_event_store:get_event_id(Index).
nosternity_event_store:get_events(Offset, Limit).   %% limit <= 100
nosternity_event_store:get_kind_count(Kind).
nosternity_event_store:get_kind_event_id(Kind, Index).
```

Writes are idempotent in the contract. With `ae_event_store_confirm_writes = true`, a batch leaves the local retry queue only after the tracked Aeternity transaction is observed as confirmed. Unknown/submitted outcomes are retried safely.

## Sophia design

The contract uses compiler-compatible Sophia constructs already used elsewhere in DamageBDD: records, maps, `Map.member`, `Map.lookup`, default map reads (`m[k = default]`), immutable record/map updates, `stateful` entrypoints and `put`.

Only the contract owner can write. The owner is the account that deploys the contract. Read entrypoints are public.

The chain store intentionally retains every unique event id, including historical versions of addressable/replaceable Nostr events. The Nostr query layer can apply replacement semantics while the chain remains an audit/event log.

## Validation

Before queueing a write, the shared Damage helper verifies:

1. required Nostr event shape;
2. lowercase hex sizes for id/pubkey/signature in the Nosternity persistence policy;
3. canonical NIP-01 event id; and
4. the BIP-340 Schnorr signature over that id.

The contract itself does not reproduce BIP-340 verification; it accepts writes only from its owner. This keeps expensive Nostr validation off-chain while preventing arbitrary accounts from mutating the archive.

## Tests / compile

Run in the DamageBDD repository:

```sh
rebar3 eunit --module=nosternity_event_store_tests
rebar3 compile
```

Then exercise the contract through the normal `damage_ae`/`vanillae` contract path against the configured Aeternity node.

The environment used to prepare this patch did not contain Erlang/rebar3/aesophia executables, so the included code was statically checked and the Sophia syntax was cross-checked against the current upstream aesophia language documentation, but a local compiler execution could not be performed here.
