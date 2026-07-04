# Nsecbunker standard sys.config format

Use normal Erlang `sys.config` terms for `nsecbunker`:

- proplists / tuples
- strings for textual values
- atoms for modes and methods
- integers for numeric limits

Do **not** use maps or binary strings in config fragments:

```erlang
%% avoid
{nsecbunker, #{enabled => true}}.
{bunker_pubkey_hex, <<"...">>}.
```

Use:

```erlang
{nsecbunker, [
    {enabled, true},
    {bunker_pubkey_hex, "..."},
    {authorized_clients, ["..."]},
    {allowed_methods, [connect, ping, get_public_key, sign_event]},
    {relays, ["wss://relay.damus.io"]},
    {limits, [
        {created_at_skew_seconds, 600},
        {max_kind_1_bytes, 4096},
        {max_kind_30023_bytes, 131072}
    ]},
    {kind_30023, [
        {require_tags, ["d", "title", "published_at"]},
        {reject_html, true}
    ]}
]}.
```

`damage_nsecbunker:config/0` canonicalises this into internal maps. `damage_nsecbunker:policy/1` then converts strings to the binaries expected by the NIP-46 policy layer.

This keeps the release config readable and standard, while preserving the internal binary discipline required by Nostr events.
