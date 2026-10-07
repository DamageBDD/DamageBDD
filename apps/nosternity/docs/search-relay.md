# Nosternity search relay

This implementation adds a basic Nostr relay, local search API, and optional
retrieval-to-LLM bridge to the existing DamageBDD/ECAI application stack. Signed
events enter through WebSocket or HTTP, DamageBDD verifies their event IDs and
BIP-340 signatures, and ECAI indexes permitted public text. DETS is the durable
source of accepted events; the ECAI index is rebuilt from it on restart.

It is a bounded, single-node implementation. It does not crawl upstream relays,
implement NIP-42 authentication, NIP-45 counts, negentropy reconciliation, or a
distributed search service. The existing separate note viewer and Nostr clients
are not a new ingestion crawler.

## Build and start

Apply these app changes to the matching complete
[DamageBDD repository](https://github.com/DamageBDD/DamageBDD). The `apps/`
snapshot alone does not contain the root `rebar.config`, lockfile, release
configuration, or downloaded dependencies needed for a full release build.

The relay uses real `jsx`, `nostrlib_schnorr`, `damage_nostr_event`, and
`ecai_search` modules. ECAI's native library must be built and available; there
is no substitute verifier or fake search backend in the runtime path.

From the full repository root:

```sh
rebar3 compile
rebar3 eunit --module=nosternity_config_tests,nosternity_startup_tests,nosternity_search_tests,nosternity_llm_bridge_tests,nosternity_search_http_tests,nosternity_search_integration_tests
```

The focused relay test runner can also run after project dependencies and the
ECAI native library have been built:

```sh
bash apps/nosternity/test/search_relay/run.sh
```

The DamageBDD feature at `priv/features/search_relay.feature` exercises relay
discovery, search responses, malformed-filter rejection, and context retrieval
using the existing `steps_http` implementation. Run it through the repository's
usual DamageBDD feature workflow against a running listener; edit its base URL
if necessary. These HTTP smoke scenarios permit an empty index and are not a
substitute for the signed-event lifecycle EUnit suite. This document does not
claim that the DamageBDD feature has been executed.

Use the repository's existing release profile and start procedure, including
the `nosternity` application. Its declared dependencies now include `ecai` as
well as `damage`, so their existing application startup configuration also
applies. Its supervisor starts the archive worker before the relay. The
application's existing HTTP start phase mounts the routes below. Its other
pre-existing clients and workers still apply; this change is not a standalone
release recipe.

Merge [search-relay.example.config](search-relay.example.config) into the
release's existing application configuration. The listener defaults to
`127.0.0.1:9001`. Use the configured listener address for the examples below.
For a public deployment, terminate TLS and enforce deployment-level connection,
request, and inference concurrency limits at the reverse proxy.

## Configuration

| Application key | Default | Behavior |
| --- | --- | --- |
| `ip` | `{127,0,0,1}` | Cowboy listener address. |
| `port` | `9001` | Cowboy clear-text listener port. |
| `search_store_file` | `"data/nosternity/search.dets"` | Durable local event file; preserve it across deployment/restart. |
| `search_max_events` | `10000` | Maximum retained events; valid range is 1 to 100000. |
| `ae_event_store_enabled` | `false` | Existing optional Aeternity archive writes. |
| `ae_event_store_rehydrate` | `true` | Import from the existing archive in background; the example explicitly disables it. |
| `search_llm_enabled` | `false` | Enable inference through `/api/nostr/ask`. |
| `search_llm_opts` | `#{}` | Trusted server-side inference options; an explicit model is required. |

The process environment variable `NOSTERNITY_LLM_API_TOKEN` protects the HTTP
inference endpoint. It is separate from any provider API credential. Search,
event publication, status, and context retrieval do not require this token.
The WebSocket protocol has no authentication handshake in this implementation.

## Enabling and tuning the service

The complete `sys.config` and `sys.config.sample` Nosternity entries now list
these settings explicitly. HTTP REST, the note viewer, NIP-11 discovery, and
WebSocket upgrades share the same `ip` and `port`; the Nostr WebSocket path is
`/nostr`. With the supplied settings the address is `127.0.0.1:9001`. Change
`ip` to a specific interface tuple or `{0,0,0,0}` to listen on all IPv4
interfaces. An eight-element IPv6 tuple is also accepted.

| Setting | Code default | Effect |
| --- | --- | --- |
| `enabled` | `true` | Start Nosternity workers and phases; false leaves its supervisor empty. |
| `http_enabled` | `true` | Start the shared HTTP/WebSocket listener; false retains the internal relay. |
| `websocket_enabled` | `true` | Permit WebSocket upgrades; false returns HTTP 403 for upgrades while HTTP discovery/API remain available. |
| `nostr_clients_enabled` | `true` | Start the two legacy signing clients; supplied configurations set this to false for a search-only relay. |
| `http_num_acceptors` | `10` | Ranch acceptor count. |
| `http_max_connections` | `1024` | Ranch soft connection limit, using one connection supervisor so the limit is not multiplied by the acceptor count. |
| `http_idle_timeout_ms` | `60000` | Cowboy HTTP connection idle timeout. |
| `http_request_timeout_ms` | `10000` | Cowboy request reception timeout. |
| `websocket_idle_timeout_ms` | `120000` | Cowboy WebSocket idle timeout. |
| `max_subscriptions` | `32` | Maximum subscriptions per WebSocket connection. |
| `max_total_subscriptions` | `4096` | Maximum subscriptions across the relay. |
| `max_filters` | `8` | Filters per query/subscription. |
| `max_filter_values` | `256` | Values in any filter list. |
| `search_default_limit` | `50` | Results per filter when no limit is supplied. |
| `search_max_limit` | `200` | Maximum per-filter result limit; must be at least the default limit. |
| `websocket_messages_per_minute` | `120` | Message quota per connection; CLOSE remains available for cleanup. |
| `subscriber_queue_max` | `256` | Connection mailbox threshold for ending slow subscriptions. |

Invalid listener or relay-limit configuration fails startup with the offending key, without
printing its value. Apply listener and worker changes by restarting the
Nosternity application. Existing WebSocket connections must reconnect to pick
up transport settings. `enabled=false` does not stop shared dependencies such
as DamageBDD, ECAI, or Gun; OTP manages their application lifecycle separately.

Application environment cannot add an application omitted from a release.
Keep `nosternity` in the existing release application list. In an already
running node where the application is available, load the edited configuration
through the release's normal mechanism, then start it with:

```erlang
application:ensure_all_started(nosternity).
```

The supplied configuration uses proplists for `search_llm_opts`, consistent
with the sample's application-owned configuration format. Existing maps are
also accepted. Inference remains separately controlled by
`search_llm_enabled` and the HTTP bearer credential. Setting
`nostr_clients_enabled=false` only disables the legacy publishing identities;
it does not disable accepting and verifying signed events from Nostr clients.

The previously documented `ae_event_store_hydrate_page_size` and
`ae_event_store_retry_ms` now control archive import page size and retry delay.
This reuses the existing keys. Fixed protocol/security bounds remain: a
64-character subscription ID, 64 KiB incoming message/body caps, 16 KiB event
content, 256 tags, and the ECAI 256-content-token indexing limit. GET search
uses the same configured default and maximum result limits as POST/WebSocket
search. The LLM context source cap remains 8.

## Protocol support

| NIP | Implemented behavior |
| --- | --- |
| [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Signed event validation; `EVENT`, `REQ`, `CLOSE`; `OK`, `EVENT`, `EOSE`, `CLOSED`, `NOTICE`; connection-scoped subscriptions; replacement and ephemeral semantics. |
| [NIP-09](https://github.com/nostr-protocol/nips/blob/master/09.md) | Author-scoped `e` deletion requests and timestamp-bounded `a` deletion requests; durable tombstones prevent delayed deleted-event ingestion. |
| [NIP-11](https://github.com/nostr-protocol/nips/blob/master/11.md) | Relay information and declared limits on the same `/nostr` endpoint. |
| [NIP-40](https://github.com/nostr-protocol/nips/blob/master/40.md) | Expired ingress is rejected and expired stored events are omitted from matching results. |
| [NIP-50](https://github.com/nostr-protocol/nips/blob/master/50.md) | `search` filters, ECAI ranking, other filter constraints, and limits applied after matching/ranking. |

Connect a Nostr client to `ws://127.0.0.1:9001/nostr`. The information document
can be fetched with:

```sh
curl -H 'Accept: application/nostr+json' http://127.0.0.1:9001/nostr
```

Send these JSON messages over that WebSocket:

```json
["REQ", "search-1", {"search":"bitcoin lightning", "kinds":[1], "limit":20}]
```

The relay sends matching stored `EVENT` frames followed by `EOSE`, then keeps
the subscription active for new matching events. A new `REQ` using `search-1`
replaces that connection's previous subscription. `limit:0` suppresses stored
results but still subscribes to live matches. Stop it with:

```json
["CLOSE", "search-1"]
```

Publish a complete, already signed event with `["EVENT", <event-object>]`.
Sign the exact NIP-01 serialization; changing the content or tags after signing
will invalidate the event. The relay does not accept private keys or sign
events for clients.

Filters support `ids`, `authors`, `kinds`, `since`, `until`, `limit`, `search`,
and single-letter tag filters such as `#e`, `#p`, and `#t`. IDs, authors, `#e`,
and `#p` values must be complete 64-character lowercase hexadecimal strings;
prefix matching is not supported. Conditions within a filter are ANDed, values
within a list are ORed, and multiple filters are ORed with event-ID deduplication.

Each filter has its own limit, default 50 and capped at 200 unless configured otherwise. A multi-filter
result is a union in filter order, not one globally re-ranked list. `total`
reports the returned union size after those limits; it is not an uncapped count
of all matching stored events.

## Search behavior and bounds

Only kinds **0, 1, and 30023** enter the text index and LLM context. These are
profile metadata, public notes, and long-form articles. Encrypted messages,
gift wraps, and signer commands are excluded from the text/LLM path. Other
valid event kinds can still be stored and returned by ordinary structured
filters without `search`; the allowlist is not a blanket relay storage policy.

The index uses the existing ECAI tokenizer and lexical scoring. Matching any
query token is sufficient; it does not require every word to appear. Search
examines the first **256 content tokens** per event, lowercases ASCII letters,
and uses the tokenizer's punctuation boundaries. The remainder of the event
is preserved, but terms appearing only after that cap cannot retrieve it.
Kind-0 content is tokenized as its JSON text, not parsed as a special profile
schema. Unsupported NIP-50 `key:value` extensions are ignored. An empty or
extension-only WebSocket/POST search matches the indexed public kinds without
a lexical restriction.

Search results prioritize the number of distinct query tokens matched in the
first 256 content tokens, with a bounded ECAI relevance score as the next
criterion, then newest timestamp and lowest event ID. The returned numeric
score combines token coverage with `atan(ECAI_score) / pi + 0.5`, so coverage
has priority. Ordinary filters use newest timestamp and lowest ID. Scores are
implementation-specific relevance values, not probabilities, factual
confidence, semantic understanding, or evidence that a claim is true.

The ingress limits are 16 KiB of content, 256 tags, a serialized event of at
most 65000 bytes, and a creation time no more than 300 seconds ahead of the
relay clock. WebSocket frames are bounded to 64 KiB; each connection permits
32 subscriptions and 120 text messages per minute by default. A subscription
defaults to at most 8 filters, and filter lists to at most 256 values. These
limits are configurable as listed above. Slow subscriber queues
are closed rather than retained indefinitely.

Expired events remain in DETS and the derived index, although query matching
excludes them. They still count toward capacity. Deletion requests also remain
durable so their tombstones survive restart. There is no automatic expiry
compaction, tombstone compaction, pagination cursor, global spam classifier,
or global HTTP/inference rate limiter. Replacement/deletion admission uses
the resulting retained-event count, so an operation that makes room can still
be accepted when the store is full.

## HTTP search and ingestion

| Method | Endpoint | Body or query |
| --- | --- | --- |
| `GET` | `/api/nostr/status` | Local event/index counts, subscriptions, hydration state, capacity. |
| `GET` | `/api/nostr/search` | `q` and optional `limit`; configured default 50 and maximum 200. |
| `POST` | `/api/nostr/search` | `{"filters":[<NIP-01/50 filter>, ...]}`. |
| `POST` | `/api/nostr/events` | Raw signed NIP-01 event object. |
| `POST` | `/api/nostr/context` | Retrieval request described below; no inference. |
| `POST` | `/api/nostr/ask` | Same retrieval request, with bearer authentication and enabled inference. |

POST requests require `Content-Type: application/json` and are limited to
65536 bytes. Body reading has a 10-second overall deadline; exceeding it
returns 408. Errors return an `error` field without internal provider details.

```sh
curl --get http://127.0.0.1:9001/api/nostr/search \
  --data-urlencode 'q=bitcoin lightning' --data-urlencode 'limit=20'

curl http://127.0.0.1:9001/api/nostr/search \
  -H 'Content-Type: application/json' \
  --data '{"filters":[{"search":"lightning","kinds":[1],"#t":["bitcoin"],"limit":10}]}'

curl http://127.0.0.1:9001/api/nostr/events \
  -H 'Content-Type: application/json' --data-binary @signed-event.json
```

The event endpoint returns HTTP 202 with `accepted:true` and the event ID
after local acceptance. Stored events are durable; ephemeral events are
broadcast without persistence. It does not assert chain confirmation. Search
returns full signed wire events in `results`, each paired with a numeric
`score`, and the returned count in `total`.

## Retrieval and LLM bridge

Request evidence without calling a model:

```sh
curl http://127.0.0.1:9001/api/nostr/context \
  -H 'Content-Type: application/json' \
  --data '{"query":"lightning","question":"What do these sources say about Lightning?","limit":4,"filters":[{"kinds":[1,30023]}]}'
```

`query` is required, at most 1024 bytes. `question` defaults to `query` and is
at most 8192 bytes. `limit` is 1 through 8, default 8. Optional `filters`
restrict sources by author, kind, time, or tags; the bridge forces the query
and public-kind allowlist onto every filter. Unknown top-level properties,
including request-supplied model, provider URL, or options, are rejected.

The response contains `query`, `question`, `public:true`, `total`, and
`sources`. Each source provides citation label `S1`, `S2`, etc., its event ID,
author pubkey, kind, creation time, ECAI score, `text`, and `truncated` flag.
Each excerpt is bounded to 4096 bytes on a UTF-8 boundary. Use the search API
with an exact `ids` filter when the full signed event is needed.

For inference, replace the example model with a model available to your
operator-configured provider, enable `search_llm_enabled`, and set
`NOSTERNITY_LLM_API_TOKEN` in the relay process environment. Then:

```sh
curl http://127.0.0.1:9001/api/nostr/ask \
  -H "Authorization: Bearer $NOSTERNITY_LLM_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"query":"lightning","question":"Summarize the evidence and cite the sources.","limit":4}'
```

The response adds `answer` and `llm_called`. With no sources it returns
`"Not in sources."` and `llm_called:false`; there is no model call. An unset
HTTP token produces 503, a mismatched token produces 401, disabled/unconfigured
inference produces 503, and a failed provider call produces a redacted 502.

`search_llm_opts` accepts the existing `ecai_ollama_client` providers `ollama`
and `openai`. Supported operator options include `model`, `host`, `port`,
`transport`, `auth`, `base_path`, `reasoning_effort`, `temperature`, and
`max_output_tokens`. Provider credentials belong in trusted server
configuration, never request bodies. The bridge fixes its system instruction,
disables provider storage where supported, uses a direct connection, caps
output to at most 4096 tokens, and sets a 60-second request timeout and a
5-second connection timeout. The encoded question/source prompt is capped
at 65536 bytes. The existing client maps this output cap to Ollama's native
`num_predict` option as well as the OpenAI provider's output-token option.

Only the question and selected public source excerpts are passed to the
configured model. Sources are untrusted data; the instruction asks the model
to cite them and ignore instructions embedded in them. The bridge grants no
tools and never executes, publishes, or signs generated output. Prompt
instructions do not guarantee factual or injection-free output. A valid Nostr
signature authenticates the event's author and bytes, not the truth of its
claims or of the model's answer.

## Durability and the optional chain archive

Accepted non-ephemeral events are synced to DETS before acknowledgment.
Replacement removes stale indexed records. A deletion request is durable
before its targets are removed. Restart revalidates stored signatures, replays
deletion requests first, resolves replacement winners, then rebuilds ECAI.
Deleting a deletion request does not undo it.

The pre-existing `nosternity_event_store` may additionally archive selected
events to Aeternity when explicitly configured. Its existing selection defaults
are kinds 1, 7, and 30023; archive writes are asynchronous and separate from
local acceptance. **Chain archival is immutable: local NIP-09 deletion and
NIP-40 expiration stop this relay serving an event; they do not erase an
already archived chain copy.** Do not enable archival expecting reversible
deletion. It also uses the existing chain account/configuration and may incur
the normal chain transaction costs.

When `ae_event_store_rehydrate` is enabled, the relay imports archive pages in
a monitored background worker. Imports use the same full signature validator,
replacement, deletion, expiry, and capacity policies as live ingress. Chain
timeouts do not run inside the relay process. The status endpoint's `hydrated`
flag indicates that the import pass completed (or archive access was disabled),
not that every archive event was accepted or that the chain archive is a full
backup of relay state.

Keep the DETS file: archive selection need not include deletion requests, and
restoring from the chain alone cannot reconstruct locally retained tombstones.
The archive and the local search store have different retention guarantees.

## Applying the configuration follow-up

Apply `nosternity-config-wiring.patch` after the search-relay patch, from the
matching full repository root. Replace your existing `sys.config` and
`sys.config.sample` with the accompanying updated files in their existing
locations. The source patch contains the runtime wiring; adding config keys
alone to the previous implementation will not enable the new controls.

```sh
git apply --check /path/to/nosternity-config-wiring.patch
git apply /path/to/nosternity-config-wiring.patch
rebar3 compile
bash apps/nosternity/test/search_relay/run.sh
```

Both complete config files passed Erlang `file:consult/1`, duplicate-key and
runtime-setting checks. Every byte outside their Nosternity sections was
preserved, and other application terms compare exactly equal.

## Code map

| File | Responsibility |
| --- | --- |
| `src/nosternity_config.erl` | Validated application settings and defaults. |
| `src/nosternity_filter.erl` | Strict event/filter validation and shared matching rules. |
| `src/nosternity_relay.erl` | Durable acceptance, lifecycle rules, ECAI index, subscriptions, archive import. |
| `src/nosternity_websocket.erl` | Nostr wire transport and NIP-11 information. |
| `src/nosternity_search_http.erl` | JSON API, bounded decoding, inference bearer authentication. |
| `src/nosternity_llm_bridge.erl` | Public source selection, bounded context, controlled provider call. |
| `src/nosternity_app.erl` | Route and listener integration. |
| `src/nosternity_sup.erl` | Relay and existing archive supervision. |
| `test/nosternity_config_tests.erl` | Config validation and live limit/transport overrides. |
| `test/nosternity_startup_tests.erl` | Startup gates, listener binding/options and shared dependency lifecycle. |
| `test/nosternity_search_tests.erl` | Signed ingress, real ECAI, filters, lifecycle, restart, subscriptions, capacity tests. |
| `test/nosternity_llm_bridge_tests.erl` | Context boundary and configuration tests. |
| `test/nosternity_search_http_tests.erl` | API parsing and authentication tests. |
| `test/nosternity_search_integration_tests.erl` | Real HTTP routing and provider-client transport against a deterministic response fixture. |
| `priv/features/search_relay.feature` | DamageBDD HTTP smoke scenarios using existing steps. |

## Validation record

The combined focused runner passed **45 tests**: 6 configuration tests,
7 startup/lifecycle tests, 15 relay/core and WebSocket tests, 5 API tests,
11 bridge tests, and 1 HTTP/provider transport integration test. These exercised real JSX serialization, BIP-340 signatures, the ECAI
native library, and Cowboy/Gun loopback HTTP and WebSocket traffic. Protocol
checks included relay discovery, event acknowledgments, filtered/union
subscriptions, EOSE, live-only ephemeral delivery, per-connection subscription
IDs, close behavior, invalid filters/signatures, ping, quota responses, and
queued-expiration/generation guards.

The provider integration exercised the actual `ecai_ollama_client` and
`damage_gun` transport against a deterministic local response fixture,
including transmission of the output-token cap. It did not run an actual
language model. A complete release/rebar build, the DamageBDD feature runner,
public deployment, and live chain archive integration were not executed in
this validation. Use the full-checkout build/test commands above before
deployment; the unit/transport tests do not establish model quality or
deployment readiness.
