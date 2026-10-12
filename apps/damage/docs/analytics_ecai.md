# DamageBDD analytics and ECAI projection

DamageBDD analytics uses a server-side materialized read model. The dashboard does
not scan Aeternity Middleware or IPFS directly.

## Data flow

1. Completed non-dry DamageBDD runs are written through to `damage_analytics_store`.
2. Settlement updates attach the spend transaction and confirmation state.
3. `damage_analytics_indexer` reconciles token-contract and local-node activity from
   AEMDW. When an authenticated account opens Analytics, that account is also
   registered as a bounded historical activity source so legacy/direct executions are
   discovered without scanning the whole network first. The indexer hydrates immutable
   `run.meta` records from IPFS and persists per-source checkpoints.
4. `damage_analytics_store` keeps canonical run facts in ETS, persists them in DETS,
   and maintains per-account UTC-day buckets for 7/30/90-day queries.
5. `damage_analytics_ecai_worker` asynchronously projects changed canonical runs
   through `damage_analytics_ecai` into the shared public ECAI search context and
   deterministic typed relations. Projection is isolated from the analytics store
   and verification execution path; slow ECAI work cannot delay dashboard reads.
6. `/api/analytics/summary` serves the materialized view with private browser cache
   headers and an ETag. Cached data remains readable when AEMDW/IPFS is degraded.

## ECAI semantics

The ECAI relation projection creates explicit facts such as:

- run `verifies` feature
- run `belongs_to_account` account
- run `executed_on` node
- run `produced` report
- run `has_result` verification result
- run `settled_by` transaction
- run `has_failure_signature` deterministic failure signature

When `ecai_transform` is available, relation curve features are measured and retained
with a deterministic geometry fingerprint for experimental analysis. A compatibility
path can derive the same affine-coordinate measurement from domain-separated
`ecai_relation:entity_point/1` values. These measurements are **not** elliptic-curve
group subtraction and are **not** treated as semantic similarity. Analytic
pass/fail/regression signals continue to come from verified run facts and explicit
aggregation rules.

The public ECAI search projection deliberately excludes raw failure/result text. It
indexes bounded verification metadata and deterministic failure signatures. Private
incident content should use ECAI's private-index path rather than this public
projection.

## Resilience

- AEMDW is consumed only by the background indexer.
- The indexer advances per-source transaction head checkpoints and stops incremental
  scans when the previous head is encountered. A separate durable continuation cursor
  progressively backfills older history without re-fetching the same old pages.
- Authenticated account activity is a first-class source. It is registered lazily by
  `/api/analytics/summary`, starts an async sync immediately, and uses a larger default
  historical backfill batch than global token scanning. The dashboard polls briefly
  while the first account import is in progress.
- Missing `run.meta` hydration uses exponential retry backoff rather than re-fetching
  the same immutable path on every sync.
- Partial source failures are exposed as degraded freshness while cached data remains
  available.
- ECAI work is serialized in a dedicated supervised worker and fails open. It does
  not run inside the analytics store or verification process. Public-index mutations
  are not killed mid-write merely to enforce a dashboard timeout.
- DETS failures degrade to ETS-only operation instead of preventing application start.

## Configuration

All settings are optional:

```erlang
{damage, [
    {analytics_store_path, "/var/lib/damage/analytics/analytics.dets"},
    {analytics_sync_interval_ms, 30000},
    {analytics_start_delay_ms, 1500},
    {analytics_retry_ms, 30000},
    {analytics_page_limit, 100},
    {analytics_max_pages, 6},
    {analytics_backfill_pages_per_sync, 2},
    {analytics_account_backfill_pages_per_sync, 6},
    {analytics_request_timeout_ms, 10000},
    {analytics_meta_retry_limit, 24},

    %% ECAI projection is enabled by default when the ECAI modules are installed.
    {analytics_ecai_enabled, true},
    {analytics_ecai_search_enabled, true}
]}.
```

`analytics_token_contract` can override the compiled DAMAGE token contract for a
controlled deployment. `run_history_node_account` is reused when configured;
otherwise the node public key is read from `secrets:node_keypair/0`.

## HTTP API

- `GET /api/analytics/summary?window=7|30|90`
- `GET /api/analytics/status`
- `POST /api/analytics/refresh`

The summary endpoint is authenticated and account-scoped. It emits
`Cache-Control: private, max-age=15, stale-while-revalidate=120,
stale-if-error=300` plus a restart-stable ETag derived from the materialized summary content.

## Historical recovery

Historical verification analytics cannot be reconstructed from the AEX9 `Transfer`
event alone: the transfer log contains token movement, not the feature/report CIDs.
The recovery path therefore reads the original DAMAGE-token `spend(node, amount,
feature_hash, report_hash)` transaction (including wrapped `PayingForTx` forms), then
loads `<report_cid>/run.meta` from IPFS when available. Older reports without `run.meta` fall back to the immutable `reports/*.plain.txt` output for a conservative pass/fail signal and to the feature CID for a title. If neither report format is readable, the chain run is still materialized with an unknown outcome when the transaction gives enough identity to scope it.

Use `GET /api/analytics/status` to inspect `scanned_transactions`, `decoded_runs`,
source cursors, `cached_runs`, `total_cached_runs` and `unscoped_runs`. A high scanned
count with zero decoded runs indicates transaction-shape/contract configuration issues;
non-zero unscoped runs indicates that report metadata/account identity could not yet be
recovered.
