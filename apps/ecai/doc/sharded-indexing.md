# Desktop-scale ECAI index shards (v1)

This implementation introduces **independent, byte-bounded NDJSON/JSONL index jobs**.
It supports `yelp_ndjson` and normalized `wikipedia_jsonl` inputs, reusing the
existing durable ECAI job scheduler. It does **not** partition the upstream
Wikimedia pageview-selection job across computers; that existing adapter still
runs its selection and content-extraction stages sequentially, with streaming
month/partition operations. For Wikimedia visibility corpora, use the normalized
JSONL outputs as shard-planner inputs *after* extraction, or extend that stage to
emit queued shard jobs before building the large search snapshot.

## Operator example (Erlang shell on the ECAI node)

```erlang
Spec = #{
  kind => wikipedia_jsonl,
  owner => <<"operator">>,
  source => #{paths => [<<"/data/wiki/normalized-articles.jsonl">>]},
  target => #{mode => live_search, base_dir => <<"/var/lib/damage/ecai-index">>,
              index_id => <<"wikipedia">>},
  options => #{batch_size => 1},
  finalize => #{build_nft_manifest => false}
}.

{ok, PlanPath, Plan} = ecai_index_shards:plan(
    Spec, "/var/lib/damage/ecai-shard-plans",
    #{max_shard_bytes => 8388608, max_line_bytes => 2097152,
      max_lines_per_shard => 1000, max_files_per_job => 1, max_shards => 4096}).

length(maps:get(entries, Plan)).
{ok, Batch1} = ecai_index_shards:enqueue_batch(PlanPath, 1, 32).
%% Repeat with Start=33, 65 ... once the pending-queue budget allows.
%% Track jobs with ecai_index_jobs_srv:list(#{limit => 100}).
%% Once ALL jobs in the plan are completed:
{ok, Merged} = ecai_index_shards:merge(
    PlanPath, "/var/lib/damage/ecai-shard-plans/wiki-merged.etf").
{ok, Hits} = ecai_index_shards:search(
    "/var/lib/damage/ecai-shard-plans/wiki-merged.etf",
    #{name => <<"elliptic curve">>}, 10).
```

A repeated `enqueue_batch` is safe after an interrupted submission: the per-shard
idempotency key is stable, and queue receipts are persisted in `plan.etf`.
Each split output is a complete-line slice, independently SHA-256 checked at
queue and merge time. Reading uses 64-KiB blocks, caps the longest incomplete
line, and never buffers the corpus. Each shard worker gets private ETS tables
and an immutable SHA-addressed `.etf` snapshot in `<base_dir>/shard-snapshots/`.
No worker mutates the global live-search index in shard mode. The public
`POST /ecai/index-jobs` collection rejects `shard_search` target mode; only
trusted operator-side `ecai_index_shards:enqueue_batch/3` can admit these
filesystem-writing jobs.

**Merge semantics:** `merge/2` requires *every* child job to be `completed`,
verifies its original spec hash and source bytes, and checks the snapshot file
hash. It atomically writes a manifest listing ordered shard commitments. It
**does not concatenate all ETS postings**; that would defeat memory limits and
could corrupt local doc integer IDs. `search/3` loads **one verified shard at a
time**, fetches that shard's local top-K, and maintains only the current
bounded top-K in memory, plus proof headers for contributing shards. Those
headers do not establish global search completeness. Local ranking scores
are not globally calibrated (IDF/stats vary by
shard); the combined top-K is a deterministic heuristic, not a true global
TF-IDF ranking. Duplicate document IDs are de-duplicated at query time. A
future global statistics/merge stage should reconcile duplicate IDs and
rebuild global proof roots before promoting a merged index as globally ranked.

**Durability and resource constraints:** `plan/3` creates immutable source parts
in a content-identified group directory and refuses to overwrite that group's
existing plan; use `read_plan/1` instead. An interrupted *planning* operation
may leave an incomplete directory (remove it only after inspection). Shard
snapshots remain available after completed jobs terminate; the manifest is a
portable description of their hashes but currently contains local snapshot
paths. Copy shards to their new paths and rebuild the manifest after moving to
other machines. Multi-node job transport is not implemented. Keep plan and
snapshot directories trusted and access-controlled; do not accept arbitrary
filesystem paths through public HTTP. Default 8-MiB input and 2-MiB line limits
should be tuned for the expansion factor of your actual dataset and host RAM.
A completed shard snapshot is capped at 256 MiB by default (tunable via
`ecai.shard_snapshot_max_bytes`, between 1 MiB and 1 GiB); oversized snapshots
fail closed rather than being loaded into a desktop's search process.
`max_shards=4096` bounds plan size, and at most 64 jobs are enqueued per
`enqueue_batch/3` call. The durable queue enforces its own pending quotas.
Receipts are serialized through a `plan.etf.lock` file; if the shell or node
crashes during admission, confirm no writer is still active before removing a
stale lock. Job idempotency keys make a repeat of the same batch safe.

For a memory-limited desktop, start with `max_shard_bytes=2097152`,
`max_lines_per_shard=250`, `max_files_per_job=1`, and
`ecai.index_jobs_max_concurrency=1`. Monitor actual peak BEAM memory and
snapshot size, then tune upward; input bytes alone do not bound ETS expansion.

This intermediate shard manifest is *not* a finalized NFT manifest. Shard mode
rejects `build_nft_manifest` or IPFS publication. Future publication requires
a separate, verified global index/commitment and approval workflow.

## EUnit and operator checks

```bash
rebar3 compile
rebar3 eunit --app ecai
```

The new `ecai_index_shards_tests.erl` checks byte-exact NDJSON partitioning,
per-file caps, oversize-line rejection, manifest-root tampering and the
prohibition on minting individual shards. The existing
`ecai_index_jobs_srv_tests` regression now cleans up its own supervisor even
on failed assertions. An expected injected WAL crash is **not** an EUnit
failure; inspect the final failure summary rather than the crash reports.
