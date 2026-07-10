# nsecbunker unified sys.config review

The nsecbunker configuration must live under the existing Damage application env:

```erlang
{damage, [
    {nsecbunker, [
        {enabled, false},
        {crypto_backend_cmd, "/opt/damage/bin/damage-nsecbunker-crypto-c"}
    ]}
]}.
```

Do not introduce a standalone `{damage_nsecbunker, ...}` OTP application env and do not use map syntax or binary strings in `sys.config`.

## Required sys.config shape

Use standard Erlang proplists:

- tuples: `{key, Value}`
- strings: `"/opt/damage/..."`, `"wss://..."`, `"connect"`
- integers and booleans as normal Erlang terms
- nested proplists for `limits`, `kind_30023`, and `genesis`

Avoid in release `sys.config`:

- maps: `#{...}`
- binary strings: `<<"...">>`
- separate app env: `{damage_nsecbunker, [...]}`

## Code review notes

- `damage_nsecbunker:config/0` reads only `application:get_env(damage, nsecbunker)` and canonicalises the proplist into internal maps.
- `damage_nsecbunker:policy/1` converts external strings to the binary values expected by NIP-46/Nostr policy checks.
- `damage_nsecbunker_vault` receives the canonical config map only; it does not read application env directly.
- `damage_nsecbunker_sup` gates the worker tree from the canonical `enabled` value.
- Phase 4A and Phase 4B BDD steps now also read ceremony script paths from the same `{damage, [{nsecbunker, [...]}]}` env before falling back to release paths.
- Phase 4B fallback now points to the production script, not the dev script.
- Phase 4B backend fallback prefers `/opt/damage/bin/damage-nsecbunker-crypto-c`, then falls back to the source-tree backend for local tests.

## Config keys for ceremony scripts

```erlang
{phase4a_dev_key_script, "/opt/damage/scripts/nsecbunker/phase4a_create_dev_damagebdd_key.sh"},
{phase4b_production_key_script, "/opt/damage/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh"}
```

Fallback aliases supported by the steps:

- `dev_key_script`
- `production_key_script`
- `key_ceremony_script`
- `ceremony_script_path`

Prefer the explicit phase-specific keys.
