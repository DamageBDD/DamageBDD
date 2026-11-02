# Knowledge search: unfinished-word matching

## Apply

Apply `ecai-knowledge-prefix.patch` from the monorepo root. The baseline is the
uploaded `ecai-search-backend-current.tar.gz`, not the older ECAI application
archive. This patch does not edit the browser, themes, contracts or configuration.

```sh
git apply --check "$HOME/Downloads/ecai-knowledge-prefix.patch"
git apply "$HOME/Downloads/ecai-knowledge-prefix.patch"
rebar3 compile
rebar3 eunit --module=ecai_text_query_tests
rebar3 eunit --module=ecai_knowledge_prefix_tests
```

Restart the node between indexing runs after compilation. A rebuild/re-upload of
existing indexes, re-minting of NFTs, or changes to the browser request are **not**
required. In-flight code reloads are best avoided while old segment handles are
in use; their internal Erlang record has gained a transient dictionary field.

## Root cause

`ecai_knowledge:query_map/1` in the supplied baseline explicitly used
`prefix => false`. Its disk adapter also delegated to the exact-only
`ecai_ollama_rag:retrieve_sources_lexical/3` path. Meanwhile, legacy
`ecai_terms:terms_from_query/2` with prefix enabled emits all shorter prefix terms
and the legacy scorer ORs matches. Turning that flag on alone would admit records
matching only a shorter prefix, or missing other query words.

The browser's debounce/cancellation changes therefore did not implement word
completion. This patch adds an independent query policy over existing postings.

## API

Both GET and JSON POST `/ecai/knowledge/search` default to:

```json
{"q":"redire","limit":10,"matching":"bool_prefix"}
```

Omitting `matching` produces the same mode. The response echoes `matching`.
`matching: "exact"` requests ANDed complete tokens without unfinished-word
expansion. Invalid modes return HTTP 400; there is no dynamic atom creation.
The existing `/ecai/knowledge/source` API and its source references are unchanged.

| Query | Behaviour for a record titled `Redirect test` |
| --- | --- |
| `redire` | Matches `redirect` as the last-token prefix. |
| `redirect te` | Requires `redirect` AND a token starting with `te`. |
| `redirect xyz` | Does not match unless the record also has a matching `xyz` token. |
| `redire te` | Does not match this title alone: `redire` is now a completed token. |
| `redirex` | Does not match by falling back to `re`, `red`, etc. |
| `redire`, `matching: exact` | Does not match the complete token `redirect`. |

Completed tokens can occur in different indexed fields of the same document.
The last token expands only in `name`, `title`, `heading`, `text`, `abstract` and
`city`. Exact terms also cover the legacy scalar/tag fields where those exact
keys exist. This is lexical word completion, not substring search, typo
correction, phrase positioning, synonym expansion, or specialized phone-number
format parsing. It uses the existing tokenizer's ASCII case normalization.

At least two Unicode characters are needed for prefix expansion. A one-character
last token gets exact-token matching only. At the API boundary, trailing
whitespace or tokenizer punctuation completes the final word. The existing
browser trims its request text, so it continues to treat its final word as a
possible prefix. `matching: exact` is the explicit complete-token mode.

## Index compatibility and execution paths

- **Shared/live ETS contexts:** seek into ordered `{Term, DocInt}` keys. Enumerate
  only complete, existing term keys starting with the entire typed prefix; then
  read bounded postings for them. No `ets:tab2list` or full-record scan is added.
- **Wikimedia live/stable contexts:** the same matching policy runs before the
  existing language/visibility filtering and entity deduplication.
- **ECS1 disk segments:** binary-seek the segment's sorted term dictionary. Open
  one segment at a time, union each query token's matches across segments, and
  intersect token groups before top-k. Only candidate metadata is read from DETS.
- **Accepted funded snapshots:** the existing owner-filtered manifest discovery,
  manifest root check, snapshot SHA-256 check and one-shard-at-a-time loading are
  retained. Each shard uses the same text-query policy.

`ecai_terms.erl`, `ecai-terms/v1`, ECS1 bytes, snapshot serialization and artifact
commitments are unchanged. Prefixes longer than the old eight-byte materialized
prefix maximum work by enumerating existing **exact** term keys. This also lets
body/abstract prefixes work without adding body-prefix postings or rebuilding.
Only previously indexed text is searchable: this cannot recover omitted terms
or index a body that was never ingested. Source retrieval remains separate.

The new policy prefers an exact token over its longer completions, then applies
field weights. Backend results still use reciprocal-rank fusion. Legacy
structured `ecai_search:search/3,4`, direct Ollama lexical retrieval, and the
conversation `ecai_knowledge:context/3` path retain their earlier query behaviour.
The prefix path is a retrieval preview and generates no new posting proofs;
existing structured proof APIs and immutable artifact roots are unchanged.

## Work limits and partial responses

Queries are at most 4096 bytes and 16 tokens. Defaults:

```erlang
%% Inside the ecai application environment; all new configuration uses tuples.
{knowledge_search_limits, [
    {max_expansions_per_field, 128},
    {max_postings_per_term, 10000},
    {max_postings, 50000}
]}.
```

An operator may lower these bounds, but this implementation does not accept
higher values. They cannot be changed by an HTTP request. Expansion/posting
limits apply per field/term in each segment or memory context; disk queries share
the 50,000-posting budget across their segment traversal. Snapshot fan-out is
still sequential and has one such budget per shard. At most 128 disk segments
are consulted, in manifest order. The existing per-backend timeout also remains.

When a bound is reached, returned hits still satisfy all query tokens, but the
backend reports `state: "limited"`, `search.truncated: true`, a `search.reasons`
list and its counters/limits. The top-level `partial` flag then remains true.
An unavailable backend instead reports `state: "unavailable"` or `"timeout"`.
Expand Retrieval status or inspect the response to distinguish them. The earlier
browser warning labels `partial` as backend unavailability; its wording is not
changed by this backend-only patch, even when the detailed reason is a limit.

In-memory lookups use the existing ordered postings tree; disk lookup first
loads a segment's term dictionary, as the existing disk reader already did. This
is not a new persistent dictionary cache or an index-wide latency guarantee.
A single large dictionary or immutable snapshot can still be expensive to load.
No prefix completion should be represented as a fix for unavailable services.

## Regression coverage

`ecai_text_query_tests` contains 12 EUnit cases for planning, final-token-only
expansion, case handling, UTF-8 prefixes, exact mode, minimum length, invalid
queries, false-short-prefix rejection, conjunction, long/body prefixes, ranking,
bounded ranges, limit reporting and stale posting removal.

`ecai_knowledge_prefix_tests` covers live contexts, body terms past the preview,
Wikimedia filters/deduplication, real ECS1/DETS ingestion and retrieval, published
versus pending batches, cross-segment matching, source integrity, private-store
rejection, verified snapshots and funded owner filtering. Its HTTP regression
starts a real loopback Cowboy listener and submits actual JSON requests to
`/ecai/knowledge/search`; it does not mock the result array. A small registered
process supplies only the shared test context. It checks `redire`, `redirect te`,
negative/exact cases, source round-trip, invalid credentials/mode and disk lookup.

Run these tests in a fresh test VM, not an attached production node. The HTTP case
requires the repository's Cowboy/Ranch, JSX and OTP inets dependencies. The
snapshot test requires the same built ECAI curve NIF as the existing snapshot and
proof tests. No payment, minting, remote indexing, or LLM generation is exercised.

## Validation performed for this delivery

- Patch application to a clean extraction: checked during packaging.
- Source-overlay byte equality after application: checked during packaging.
- Eight existing source/auth/privacy integration checks: passed (Python static
  checks, **not runtime authorization tests**).
- Changed Erlang files: lexical/delimiter comparison and diff whitespace checks.
- EUnit tests and full `rebar3 compile`: **not executed in the delivery container**.
  Erlang was absent; attempts to install it failed because network access was
  unavailable. The checks above are not a substitute for compilation or EUnit.

Review the source and run the commands above before deploying. No performance
or successful production-search claim is based on an unexecuted test.
