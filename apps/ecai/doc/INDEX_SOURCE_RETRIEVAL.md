# ECAI indexing: complete-source retrieval, live knowledge and deployment review

Review date: 20 October 2026. Baseline: the supplied `latest-ecai.tar.gz`, SHA-256
`93697e6050b6fd31a78d91f8ba1bd372599d1e0fe4766600733a9fa7905b55ca`.

**Status: implementation patch with static and isolated-browser validation. Erlang
compilation, EUnit, real ingestion benchmarks, cloud execution, Lightning settlement,
IPFS publication and blockchain minting were NOT executed in this environment.**
The supplied snapshot contains `apps/ecai`, not the full DamageBDD umbrella. Neither
`erl`, `erlc` nor `rebar3` is installed here; package acquisition was unavailable.

## 1. What the source actually implements

This is not one uniform index. The following boundaries matter for retrieval,
recovery, funding and publication.

| Path | Inspected implementation | Change in this patch |
|---|---|---|
| Durable indexing queue | Normalized specs, persisted jobs/checkpoints, lifecycle controls, retry/fencing and artifact stages in `ecai_index_jobs_srv`, `ecai_index_job_worker`, `ecai_index_job_store` | Existing scheduling and checkpoints retained |
| Quick Index | Inspects bounded UTF-8 uploads, public URLs or IPFS; stages accepted file/URL bytes in Kubo; enqueues `ipfs_cid` into `searchable_disk` | Inherits exact-byte retention through the IPFS disk adapter |
| IPFS searchable disk | Fetches source bytes, creates versioned overlapping chunks, stores metadata in DETS, publishes posting segments | Retains original UTF-8 bytes separately, resolves complete sources by record or source identity, publishes smaller batches, fixes live cache invalidation |
| IPFS ledger-only | Persists ingest events, not necessarily a queryable document store | Unchanged; a WAL acknowledgement is NOT a full-source retrieval promise |
| Legacy Wikipedia/Yelp live loaders | Shared in-memory records; checkpoint offsets are distinct from index persistence | Unified knowledge search reads the shared context; Wikipedia propagates complete-source fields when present |
| Wikimedia visibility | Pageviews selection, source extraction/normalization, isolated build, live-record callback, snapshot activation | Retains complete available dump text independently of excerpts; live query need not finalize all proof roots |
| Funded shard pool | Owner/admin controls, signed participant binding, frozen placements, shard execution and configured verification, reward accounting and guarded payout workflow | Publishes owner-scoped partial manifests after acceptance, making accepted shards searchable before the whole job finishes |
| Cloud settings | Per-account provider settings and verification, operator-priced quotes, budget reservations, mint intents | Reviewed, not converted into an external cloud dispatcher |
| Artifact / NFT preparation | File digests, manifest identity, snapshots, optional IPFS publication and metadata readiness | Disk artifact inventory includes source blobs; accepted partial search views are NOT finalized NFT releases |
| Private corpora | Separate authorization, encrypted storage and controlled model destinations | Deliberately excluded from the new public registry and public source reads |
| Legacy fixed-width / hybrid exports | `ecai_disk_index` encodes point/offset entries; `ecai_disk_indexer_srv` ignores its `_Rec` argument and persists postings only | Not silently promoted to a complete-source store; requires its backing payload store or migration |

Quick Index in this archive explicitly rejects PDF/ZIP/Office-container extraction.
Its HTML mode indexes source markup as UTF-8 text, not a rendered page. This patch
therefore does not claim original PDF-byte retrieval, image extraction, OCR or
complete document support for adapters which never supplied those bytes.

### Cloud execution is still a missing integration

`ecai_compute_settings` explicitly reports `execution_integration = pending` and
`mint_submission_integration = pending`. Reservations enter `awaiting_dispatch`;
mint requests enter `awaiting_wallet_signature`. Provider identity checks and
budget holds do not launch an AWS Batch or Cloud Run task. The funded cluster
path is a different, more developed execution workflow; it requires configured
trusted Erlang nodes and shared storage, not arbitrary Internet worker discovery.

Remaining external-cloud work includes an idempotent provider submission adapter,
provider execution ID persistence, polling/callback authentication, cancellation,
retry reconciliation, real invoice reconciliation, and verified artifact import.
A provider identity check alone is insufficient to certify job permissions,
runtime capacity, availability or billed cost. No cloud reservation, grant,
invoice payment, channel operation or mint was performed while preparing this patch.

### NFT readiness is not on-chain settlement

Artifact construction and `ready_to_mint` mean the required artifact preparation
conditions were met in that path, not that a token was signed, broadcast or confirmed.
Cloud mint intents still need wallet signing/submission and receipt tracking.
Content-addressed references also need retention/pinning. This patch leaves those
states explicit and does not issue an NFT for a partial funded manifest.

## 2. Complete-source contract

The new `ecai_source_retrieval` module provides:

```erlang
%% Trusted internal application APIs; Dir must be an operator-selected PUBLIC store.
{ok, BlobRef} = ecai_source_retrieval:retain(Dir, ExactUtf8Bytes, SourceKey, SourceVersion).
{ok, Source} = ecai_source_retrieval:disk(Dir, DocInt).
{ok, Source} = ecai_source_retrieval:disk_source(Dir, SourceKey, SourceVersion).
{ok, Source} = ecai_source_retrieval:from_record(StoredRecord).
{ok, Source} = ecai_source_retrieval:reassemble(Chunks, ExpectedOriginalBytes, ExpectedSha256Hex).
```

`retain/4` returns a descriptor; it does not itself publish a searchable record.
The supported IPFS adapter adds the descriptor to records and publishes those
through the existing disk indexer. `disk_source/3` uses that persisted catalog.

For new IPFS/Quick Index text ingestion, exact fetched bytes are stored at
`sources/<sha256>.bin`. Metadata stores the source key/version, SHA-256, byte
length, completeness and representation. Source key/version conflicts are rejected.
Reads check the byte length and digest. There is no automatic fetch of a missing
URL, no external spending, and no reconstruction of data from an elliptic-curve
point or digest. A digest verifies bytes against a reference; it does not establish
that a source assertion is true or that an untrusted descriptor is authoritative.

The `complete` field is always qualified by `representation`:

| Representation | Meaning |
|---|---|
| `original_utf8_bytes` | Exact UTF-8 bytes fetched and retained by the IPFS/Quick Index path |
| `cirrus_text_field` | Complete supplied CirrusSearch `text` field, not the original rendered webpage or all revision history |
| `cirrus_source_text_field` | Complete supplied source-text field when that is the available dump representation |
| `cirrus_excerpt` | Opening/description fallback only; `complete=false` |
| `stored_excerpt` | Legacy record without retained full-source bytes; `complete=false`, integrity unverified |
| `reconstructed_utf8_bytes` | Validated reconstruction from contiguous chunks matching a trusted original length and SHA-256 |

Default source-read/retention cap is 64 MiB, configurable up to 256 MiB. This is
a byte cap, not a memory budget: JSON encoding, parsed records and concurrent
requests add overhead. The HTTP response contains the full retained text; the
browser viewer deliberately renders only its first 64,000 characters and labels
that display limit. A smaller reverse-proxy response cap may need adjustment.

Explicit chunk reconstruction rejects ordinal gaps, mixed source/version/chunker
identities, malformed ranges, changed chunk hashes, inconsistent overlap, missing
tails and a final digest mismatch. It requires an externally known original size
and digest. It cannot certify completeness merely because the available chunks
can be concatenated. Existing incomplete sources must be re-ingested from an
authorized complete source to become complete.

### Search coverage is distinct from retained length

Wikimedia normalization now uses `ecai-wikimedia-content/v2`. Normalized JSONL and
snapshots contain `source_text`, `source_sha256`, `source_bytes`,
`source_complete`, `source_representation` and `source_index_token_limit`.
The default additional body-term cap is 4,096 tokens per record. Legacy abstract
caps are unchanged. Thus the whole retained field can be retrieved even when
terms near its end are not indexed. Larger caps have memory/build-cost implications;
this patch does not claim every token in every long article is searchable.

Additional body terms are recorded in the index's term list so replacing a record
removes old body postings. Search summaries omit `source_text`; complete payloads
are requested separately. A projected record is not a substitute for the original
canonical record when independently validating a v2 record membership proof.
Existing low-level search APIs retain their compatibility behavior; new unified
knowledge reads use explicit projections and omit release proofs.

## 3. Search while an index is being built

`ecai_knowledge` supplies one retrieval registry for shared live search, the active
Wikimedia context, configured public disk indexes and caller-owned funded manifests.
Independent index scores are fused by reciprocal rank, not treated as a single
corpus-wide IDF score. Shard-internal ranking remains the existing per-shard heuristic.

| Backend | When data becomes queryable | Recovery / consistency boundary |
|---|---|---|
| Public disk | After a batch synchronizes metadata and publishes its immutable posting segment | Readers never depend on the writer's unpublished batch. Queries reread the segment manifest; hot-cache keys include corpus path and segment generation |
| Shared JSONL live loader | After the loader adds records to the shared context | ETS is not itself durable; restore a snapshot or replay inputs after loss |
| Wikimedia live build | During indexing after extraction/selection and live-record upsert | One live build is exposed per search server. An interrupted worker loses its live preview; normalized input supports replay |
| Funded shards | After a unit reaches the existing acceptance state and a verified partial manifest is written | Unaccepted units are excluded. Only the owning account sees this manifest through unified knowledge search. Final merged output remains a separate state |

Default disk publication threshold is 1,000 records or two seconds elapsed at an
`add_doc` call. It is NOT a background wall-clock timer. A stalled writer with an
unflushed tail must call `flush/1` or `close/1`; the elapsed-time check fires on a
subsequent add. The canonical query bug is fixed: lexical queries now use the
same field-prefixed terms as stored postings. Query-owned hot ETS tables and
DETS opens are released on normal/error exits.

Live previews carry `live` / `final` labels and omit Merkle proof generation.
A live build is not a globally consistent or final cryptographic release.
`complete=true` on one source says nothing about completion of its entire corpus.
The active Wikimedia search context hides the stable snapshot while a live build
is active; this is not a simultaneous live+stable union. Source references include
a SHA-256 pin where available, so replacement between search and source-read
produces `source_version_changed` instead of quietly returning different text.
Historical snapshot lookup is not implemented by this endpoint.

### Conversation and model routes

The dashboard conversation path no longer reads the hard-coded `"ecai_index"`
directory. It queries `ecai_knowledge:context/3`, using the authenticated account
on the persisted-conversation path; the legacy caller path remains public-only.
Managed Ollama-compatible RAG/strict profiles also read the public registry and
retain their configured disk fallback. Code-only profiles stay code-only; private
corpus access stays on its existing separate authorization path. Managed public
model profiles do not automatically expose owner-funded or private corpora.

Model context contains bounded excerpts (2,048 bytes per text/abstract field in
unified hits), not automatic full-document injection. Existing overall model
context limits remain in force. Operators must still treat retrieved source text
as untrusted evidence, not executable instructions or verified factual truth.

Knowledge Search now calls the unified endpoint, offers **Retrieve source**, and
can refresh every three seconds while that panel is visible. Source viewing pauses
refresh. Identity changes clear existing results/source views, cancel refresh and
fence late results by the authentication epoch. The console asset URL is versioned
to prevent retaining the previous JavaScript in cache.

## 4. HTTP usage

```http
POST /ecai/knowledge/search
Content-Type: application/json
Authorization: Bearer <existing valid account token>

{"q":"elliptic curves","limit":5}
```

Public corpora may be queried without credentials. Owner-funded views require a
verified owner account. An invalid explicitly supplied bearer token is rejected;
it cannot piggyback on a valid cookie or select an arbitrary owner. These read
endpoints do not create accounts, bypass private-corpus access, or authorize funds.

Each result contains a `source_ref`. Send it back unchanged:

```http
POST /ecai/knowledge/source
Content-Type: application/json
Authorization: Bearer <same valid account token>

{"source_ref":{"index":"public-ipfs","doc_id":123,"sha256":"<64-lowercase-hex-digest-from-result>"}}
```

The placeholders above are descriptive, not values to copy literally. A funded
reference also contains `shard_ordinal`; its document ID is the stored binary/string
identifier rather than a disk integer. Clients cannot provide local paths, URLs,
provider credentials or arbitrary source options. A request body is capped at
16 KiB; the configured source byte cap bounds source reads. Responses are `no-store`.
`GET /ecai/knowledge/status` shows logical public indexes and only the caller's
funded views. The existing authenticated Wikimedia surface also gains
`GET /ecai/wikimedia/source/:id` for the current active context.

For a shell-level live smoke test, after normal initialization:

```erlang
{ok, Search} = ecai_knowledge:search(<<"needle">>, #{limit => 5}).
[First | _] = maps:get(results, Search).
{ok, Source} = ecai_knowledge:source(maps:get(source_ref, First), undefined).
maps:with([complete, representation, bytes, sha256, integrity], Source).
```

Use an authenticated owner identity only from trusted server code for a funded
corpus. The public source reader does not expose private corpus paths.

## 5. Benchmark profiles and reproducibility

Profiles are in `priv/config/index_benchmark_profiles.json`; the local executable
harness is `ecai_index_benchmark` plus `scripts/benchmark_index.sh`. They are
resource envelopes, NOT verified cloud instance capacities or price quotes.

| Profile | Logical CPUs / schedulers | RAM envelope | Publish batch (records/chunks) | Suggested shard input cap |
|---|---:|---:|---:|---:|
| smoke | 1 | 1 GiB | 16 | 1 MiB |
| edge-2g | 2 | 2 GiB | 64 | 2 MiB |
| small-4g | 2 | 4 GiB | 128 | 4 MiB |
| medium-8g | 4 | 8 GiB | 500 | 8 MiB |
| large-16g | 8 | 16 GiB | 1,000 | 16 MiB |
| xlarge-32g | 16 | 32 GiB | 2,000 | 32 MiB |
| workstation-128g | 32 | 128 GiB | 5,000 | 64 MiB |

The shell sets BEAM scheduler count. It does not provision memory/CPUs, enforce a
container/cgroup limit, launch cloud resources, set concurrency on a live server,
or apply shard-policy JSON automatically. Resource enforcement belongs to your
runner. Shard byte/line limits are input limits, not predicted ETS footprints.

Run from the FULL DamageBDD umbrella root with dependencies/NIFs built:

```bash
rebar3 compile
apps/ecai/scripts/benchmark_index.sh smoke /tmp/ecai-source-smoke-001
RECORDS=4096 apps/ecai/scripts/benchmark_index.sh small-4g /tmp/ecai-small-001
RECORDS=4096 apps/ecai/scripts/benchmark_index.sh medium-8g /tmp/ecai-medium-001
RECORDS=4096 apps/ecai/scripts/benchmark_index.sh workstation-128g /tmp/ecai-workstation-001
```

Every output directory must be NEW. The runner refuses existing paths and never
deletes them. `RECORDS` may be 1 through 100,000; it changes source count only. The
same 2,048-byte deterministic UTF-8 sources and overlapping text windows are used
across profiles. Default smoke has 64 sources; other profiles use 4,096. A common
4,096-source run is an approximately 8 MiB input correctness/latency comparison,
not a saturation test of a 128 GiB workstation. Increase count in controlled steps
and monitor disk, inode, memory and DETS sizes; do not assume any maximum is safe
on a particular host merely because the harness accepts it.

`benchmark.json` records corpus SHA-256, source/record counts, ingest elapsed time,
throughput, output bytes, sampled peak BEAM memory, concurrent probe count, query
p50/p95, first-searchable time, query errors and exact source round-trips for the
first/last source. `live_query_observed` is false when no probe succeeded before
ingestion ended. A fast smoke run can legitimately have no concurrent probe sample;
that is NOT evidence of live-query latency. Sampling peak BEAM memory is not peak
RSS/cgroup memory. Query timings are a mixed-cache synthetic repeated-key workload,
not a full relevance evaluation or a cold-start corpus scan benchmark.

For defensible comparisons, keep corpus hash/count, OTP/NIF build, storage type,
source policy and filesystem cache conditions fixed. Record host/instance SKU,
CPU model, architecture, volume type, filesystem, cgroup limits and co-tenancy.
Repeat runs into separate fresh directories and report distributions; do not drop
errors. The patch contains NO measured hardware performance results.

Profiles also contain `quote_only_examples` matching the existing application's
AWS Batch / Cloud Run request schema and resource caps. They contain no prices,
credentials, reservations or automatic submission. A quote remains the operator's
configured upper bound, not a real provider invoice. Workstation-scale resources
beyond that schema have no cloud quote example.

## 6. Configuration and migration

Merge relevant entries from `priv/config/source_retrieval.example.config` into your
existing `ecai` application environment; do not replace your full `sys.config`.
The default public disk registry resolves `ecai_paths:ipfs_index_dir()` automatically.
The explicit directory in the sample is illustrative: use the actual directory for
your deployment, or omit the entry. Never point it at private corpus storage.

New source-retention behavior applies to NEW ingestion. Historical snapshots or
existing normalized inputs do not magically gain discarded text. Rebuild from a
complete source into a fresh corpus/job/artifact identity. Content/v2 must not be
advertised for untouched v1 results; old checkpoints may reuse their old normalized
inputs, so a fresh job/rebuild is required to establish the new guarantee.

For the single-live Wikimedia service, the sample serializes the queue with
`index_jobs_max_concurrency=1`. That is a conservative queue-wide limit; it is not
per-kind admission control. Use isolated shard jobs for parallel independent
builds. Full dump text increases normalized-file and snapshot size and can be
resident in both the builder and live search context. Lower shard sizes before
increasing parallelism, especially on small-memory machines.

## 7. Remaining operational risks and boundaries

- **Immutable artifact capture:** disk artifact assembly still reads the mutable
  corpus/docstore and its files. This patch includes source blobs but does NOT add
  a transactionally consistent snapshot/export lock around concurrent writers.
  Quiesce writers for final export; then verify and reload the artifact in an
  isolated consumer. Do not call a concurrent export a coherent final release.
- **Single live Wikimedia context:** concurrent jobs can replace the live view.
  This patch does not implement a durable multi-live-corpus server. Activation,
  owner death and restart remain explicit consistency changes.
- **Funded preview cost:** each newly accepted unit republishes a manifest over
  accepted shards using the existing verification path. Large pools may need
  incremental verification/caching and publication retries. A publication error
  is recorded as `live_search_error`; it is not proof that the accepted work was
  indexed into the preview. A later acceptance/final merge can retry through the
  normal flow; no standalone background repair queue was added.
- **Query scale:** backends are queried sequentially with per-backend timeouts
  (default five seconds), not a global latency SLA. All owner-visible manifests
  are considered. Shard reads load one snapshot at a time within that backend;
  snapshot decode and concurrent clients can still increase memory and latency.
  Bound exposed corpora and concurrent requests at deployment, and benchmark the
  combined workload. No inference provider latency is included in the local test.
- **DETS and storage lifecycle:** document metadata remains in DETS, with its
  documented 2 GiB file-size limit. Source blobs are outside DETS, but chunk text
  remains inside metadata. Sharding is still required at scale. Orphan blob GC,
  version deletion, source TTLs and source-history lookup are not implemented.
- **Durability scope:** writes sync files and atomically rename; this does not
  establish power-loss durability on every filesystem or network mount, nor a
  directory-fsync guarantee. Existing shared-filesystem and single-writer
  assumptions remain. Source keys and versions are trusted ingestion metadata.
- **Trust:** source hashes verify byte consistency, not source truth, publisher
  identity, post-quantum security, correct answers or immunity to prompt injection.
  Public corpus configuration is an operator trust boundary. Private indexes and
  permissioned data need their existing dedicated route and destination policies.

Official DETS reference: https://www.erlang.org/doc/apps/stdlib/dets.html .
Cloud runtime policies and actual quotas must be checked with the chosen provider;
application quote validation is not a provider-capability test.

## 8. Validation performed and required release gates

Executed here:

| Check | Result |
|---|---|
| New source-retrieval static contract suite | 15 passed |
| Existing console contract suite | 21 passed |
| Existing Compute & NFTs contract suite | 6 passed |
| Existing funded-pool contract suite | 12 passed |
| Isolated Chromium production search-function scenarios | 6 passed; request/auth helpers and responses mocked |
| Wider Python `*contract.py` discovery | 102 total, 93 passed; same 5 failures + 4 errors present in untouched baseline |
| Untouched baseline comparison | 87 total; those same 9 issues, no new failure/error names |
| JavaScript and benchmark shell syntax | Passed |
| Erlang compile / EUnit / actual benchmark | Not run: runtime/toolchain absent |

The baseline errors reference absent `apps/damage` auth/market-maker assets. Baseline
failures include source-format-specific auth/reward assertions and an already
mismatched video asset cache-version assertion. They remain visible in the logs;
this patch does not claim the whole umbrella test suite passes.

Included new EUnit cases cover exact UTF-8/source round-trip after reopening,
changed bytes, conflicting versions, legacy partial records, no read-side store
creation, inline descriptor validation, chunk continuity/overlap, live publication,
cache freshness, query ETS cleanup, source pins, body-term replacement, and complete
versus opening-only Wikimedia normalization. Run them before deployment:

```bash
rebar3 compile
rebar3 eunit --module=ecai_source_retrieval_tests
rebar3 eunit --module=ecai_live_disk_search_tests
rebar3 eunit --module=ecai_source_search_tests
rebar3 eunit --module=ecai_wikimedia_content_tests
rebar3 eunit --module=ecai_compute_settings_tests
rebar3 eunit
python3 -m unittest discover -s apps/ecai/test -p test_source_retrieval_contract.py
python3 apps/ecai/test/test_knowledge_search_browser.py
```

The browser scenarios execute the production search function block with a small
fixture DOM. They are not a test of the full dashboard auth stack or a real backend.
Native tests require the matching umbrella dependencies and ECAI native libraries.

Before enabling real spending, additionally prove restart/replay from a partial
build, rejection of tampered artifacts, two-account funded isolation, source-version
pinning across activation, verifier disagreement handling, cancellation during
execution, payout uncertainty/reconciliation, and final artifact restoration on
another node. Test cloud submission and on-chain confirmation separately only
when their missing adapters are implemented and operator approval is explicit.

## 9. Source locator ledger

Line numbers below refer to the patched source bundled with this report.

- `apps/ecai/src/ecai_source_retrieval.erl:17` — `retain(`
- `apps/ecai/src/ecai_source_retrieval.erl:49` — `disk_source(`
- `apps/ecai/src/ecai_source_retrieval.erl:70` — `from_record(`
- `apps/ecai/src/ecai_source_retrieval.erl:144` — `reassemble(`
- `apps/ecai/src/ecai_knowledge.erl:8` — `search(Query, Opts)`
- `apps/ecai/src/ecai_knowledge.erl:36` — `source(#{`
- `apps/ecai/src/ecai_knowledge.erl:26` — `context(`
- `apps/ecai/src/ecai_knowledge.erl:15` — `disk_indexes()`
- `apps/ecai/src/ecai_index_pool_runner.erl:150` — `publish_live_manifest(`
- `apps/ecai/src/ecai_index_pool_runner.erl:137` — `finish(`
- `apps/ecai/src/ecai_index_pool.erl:68` — `handle_call({knowledge_manifests,`
- `apps/ecai/src/ecai_compute_settings.erl:386` — `<<"execution_integration">>`
- `apps/ecai/src/ecai_compute_settings.erl:387` — `<<"mint_submission_integration">>`
- `apps/ecai/src/ecai_index_artifact.erl:261` — `"sources", "*.bin"`
- `apps/ecai/src/ecai_quick_index_detector.erl:28` — `classify(<<"%PDF-"`
