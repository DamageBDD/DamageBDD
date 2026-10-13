# DamageBDD context implementation

## Files

- `damage_context.erl`: shared ETS hot cache, encrypted DETS snapshots, versioned mutation API, redacted REST API, explicit Aeternity anchoring, and compatibility wrappers.
- `context.aes`: small commitment registry storing only `{version, sha256_root}` per account.

## Programmatic API

```erlang
{ok, Meta1} = damage_context:put(Account, <<"Server">>, <<"https://example.com">>).
{ok, Meta2} = damage_context:put(Account, <<"API_TOKEN">>, Token, #{sensitive => true}).
{ok, Value} = damage_context:get(Account, <<"Server">>).
Context = damage_context:get_context(Account).
{ok, Snapshot} = damage_context:snapshot(Account).
{ok, Meta3} = damage_context:apply_changes(Account, Changes, ExpectedVersion).
{ok, Anchor} = damage_context:anchor_context(Account).
```

## HTTP API

- `GET /context`: redacted snapshot.
- `POST /context`: set one value or submit a change set.
- `PATCH /context`: atomic change set with optional `expected_version`.
- `DELETE /context?key=...`: delete one value.
- `GET /context/anchor`: read the current contract commitment.
- `POST /context/anchor`: explicitly commit the current local version/root.

Single value request:

```json
{
  "key": "API_TOKEN",
  "value": "secret",
  "sensitive": true,
  "expected_version": 4
}
```

Atomic change set:

```json
{
  "expected_version": 4,
  "set": {
    "Server": "https://example.com",
    "API_TOKEN": {
      "value": "secret",
      "sensitive": true
    }
  },
  "delete": ["OLD_TOKEN"]
}
```

## Configuration

```erlang
{context_store_file, "/var/lib/damage/context.dets"},
{context_sync_writes, true},
{context_max_bytes, 1048576},
{context_max_request_bytes, 1048576},
{context_ct, "ct_DEPLOYED_CONTEXT_CONTRACT"}
```

The `context_ct` setting is needed only for explicit anchor operations. Normal reads and writes do not access the chain.
