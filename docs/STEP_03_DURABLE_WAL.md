# ECAI production step 03: durable committed-batch WAL

Step 3 creates the first explicit durability boundary in the ECAI IPFS ingest
path.

Steps 1 and 2 established deterministic chunks and deterministic `event_id`
values. Step 3 uses those identities to make an entire source-version batch
recoverable and logically idempotent.

## The atomic guarantee

For one call to:

```erlang
ecai_ingest_writer:submit_batch(Writer, Records)
```

the writer performs:

```text
validate and canonicalize every record
        ↓
remove event_id values already durable or repeated in this request
        ↓
write batch_begin + event frames + batch_commit
        ↓
file:sync/1
        ↓
install the committed records in the in-memory ledger
        ↓
reply {ok, Ack}
```

A successful acknowledgment means the new records are present in a complete,
checksummed WAL batch that passed `file:sync/1`.

The acknowledgment deliberately states:

```erlang
#{
    accepted => true,
    durable => true,
    ledger_visible => true,
    index_searchable => false
}.
```

`index_searchable => false` is important. Step 3 makes ingestion durable; it
does not yet publish ECAI terms to an immutable searchable segment and
manifest. That publication checkpoint is Step 4.

## Crash outcomes

| Failure point | Restart result |
|---|---|
| Before any WAL write | Nothing is committed. The caller can retry. |
| During `batch_begin` or an event frame | The incomplete batch is discarded and its physical tail is truncated. |
| After all events but before a complete commit frame | The complete uncommitted batch is discarded. |
| After commit write but before or during sync | The client outcome is uncertain. Restart validates the log; a retry is deduplicated by `event_id`. |
| After sync but before ETS installation or reply | Recovery installs the committed records. A retry is a durable no-op. |
| Corruption inside previously complete history | Startup fails closed with `wal_corrupt`; the history is not silently treated as empty. |

The implementation provides logical exactly-once ingestion over an at-least-once
caller: clients may retry uncertain calls, while the durable ledger stores one
logical record for each deterministic `event_id`.

## Scope of this step

This step provides:

- one supervised writer process per local index directory;
- one owner for WAL appends and local document-ID allocation;
- bounded, versioned record encoding without Erlang term deserialization;
- framed WAL batches with header and payload checksums;
- commit followed by `file:sync/1` before success is returned;
- replay of complete committed batches after restart;
- automatic removal of incomplete physical tails;
- fail-closed handling of corruption in complete history;
- durable deduplication by the Step 2 `event_id`;
- stable local document IDs derived from durable event order;
- bounded source chunk generation using the writer's batch limit;
- an operator status map and explicit durability/publication state;
- focused recovery, corruption, limit, replay, and supervisor tests.

It does not yet provide:

- searchable term-index publication;
- active/frozen search memtables;
- immutable segment or manifest checkpoints;
- safe WAL prefix reclamation;
- update tombstones or source-version replacement;
- inter-node replication;
- a cross-process operating-system file lock;
- authenticated WAL frames.

## Package contents

### Runtime modules

```text
apps/ecai/src/ecai_ingest_record.erl
apps/ecai/src/ecai_wal.erl
apps/ecai/src/ecai_ingest_writer.erl
apps/ecai/src/ecai_ingest_sup.erl
apps/ecai/src/ecai_ipfs_ingest.erl
```

The package also carries the cumulative Step 1 and Step 2 modules and tests:

```text
apps/ecai/src/ecai_chunker.erl
apps/ecai/src/ecai_ingest_event.erl
apps/ecai/src/ecai_disk_indexer.erl
apps/ecai/test/ecai_chunker_tests.erl
apps/ecai/test/ecai_ingest_event_tests.erl
apps/ecai/test/fixtures/ecai_ingest_event_v1_golden.json
apps/ecai/test/fixtures/ecai_wal_v1_golden.json
```

### Step 3 tests

```text
apps/ecai/test/ecai_step03_test_support.erl
apps/ecai/test/ecai_ingest_record_tests.erl
apps/ecai/test/ecai_wal_tests.erl
apps/ecai/test/ecai_ingest_writer_tests.erl
apps/ecai/test/ecai_ipfs_ingest_step03_tests.erl
```

### DamageBDD integration

```text
apps/ecai/src/ecai_sup.erl
patches/ecai_sup_step03.patch
patches/ecai_sup.erl.before_step3
config/ecai_step03_sys_config.fragment.config
```

The replacement `ecai_sup.erl` is included for inspection. On a branch that has
changed since the package was built, apply or manually merge the small patch
rather than overwriting the local supervisor.

# Install in DamageBDD

## 1. Start from a clean, reviewed branch

Run from the DamageBDD repository root, where the top-level `rebar.config` and
`apps/` directory are present:

```sh
cd /path/to/DamageBDD

test -f rebar.config
test -d apps/ecai/src
test -d apps/ecai/test

git status --short
git checkout -b ecai-step-03-durable-wal
```

Step 3 assumes the Step 1 and Step 2 changes have already been accepted. Commit
or otherwise preserve that state before applying this package.

## 2. Extract the package outside the repository

```sh
rm -rf /tmp/ecai-step-03
mkdir -p /tmp/ecai-step-03

unzip /path/to/ecai_step_03_durable_wal.zip \
  -d /tmp/ecai-step-03

PKG=/tmp/ecai-step-03/ecai_step_03_durable_wal
```

Optionally verify the package manifest before copying:

```sh
(
  cd "$PKG"
  sha256sum -c SHA256SUMS
)
```

## 3. Copy runtime modules and tests

Do not copy the packaged `ecai_sup.erl` yet.

```sh
cp "$PKG/apps/ecai/src/ecai_chunker.erl" \
  apps/ecai/src/ecai_chunker.erl
cp "$PKG/apps/ecai/src/ecai_ingest_event.erl" \
  apps/ecai/src/ecai_ingest_event.erl
cp "$PKG/apps/ecai/src/ecai_disk_indexer.erl" \
  apps/ecai/src/ecai_disk_indexer.erl
cp "$PKG/apps/ecai/src/ecai_ingest_record.erl" \
  apps/ecai/src/ecai_ingest_record.erl
cp "$PKG/apps/ecai/src/ecai_wal.erl" \
  apps/ecai/src/ecai_wal.erl
cp "$PKG/apps/ecai/src/ecai_ingest_writer.erl" \
  apps/ecai/src/ecai_ingest_writer.erl
cp "$PKG/apps/ecai/src/ecai_ingest_sup.erl" \
  apps/ecai/src/ecai_ingest_sup.erl
cp "$PKG/apps/ecai/src/ecai_ipfs_ingest.erl" \
  apps/ecai/src/ecai_ipfs_ingest.erl

mkdir -p apps/ecai/test/fixtures
cp "$PKG/apps/ecai/test/"*.erl apps/ecai/test/
cp "$PKG/apps/ecai/test/fixtures/"*.json \
  apps/ecai/test/fixtures/
```

Install the operator documents in the repository:

```sh
mkdir -p docs/ecai
cp "$PKG/docs/STEP_03_DURABLE_WAL.md" docs/ecai/
cp "$PKG/docs/STEP_03_VALIDATION.md" docs/ecai/
```

## 4. Merge the supervisor child

First check whether the patch applies to the current branch:

```sh
git apply --check "$PKG/patches/ecai_sup_step03.patch"
```

When that succeeds:

```sh
git apply "$PKG/patches/ecai_sup_step03.patch"
```

When it does not apply, manually merge these two changes into
`apps/ecai/src/ecai_sup.erl`:

1. Prepend `maybe_ingest_specs()` to the top-level child list.
2. Add `maybe_ingest_specs/0`, which enables `ecai_ingest_sup` only when
   `{ingest_wal_enabled, true}` is configured.

Inspect the packaged replacement and patch:

```sh
git diff --no-index \
  "$PKG/patches/ecai_sup.erl.before_step3" \
  "$PKG/apps/ecai/src/ecai_sup.erl" || true
```

The feature is disabled by default, so installing the code alone does not start
a second ingest path.

## 5. Confirm the `crypto` application dependency

`ecai_ingest_event` and `ecai_wal` use `crypto:hash/2`.

```sh
grep -n "applications" apps/ecai/src/ecai.app.src
```

The existing application dependencies must include `crypto`, while preserving
all other dependencies. Conceptually:

```erlang
{applications, [
    kernel,
    stdlib,
    crypto
]}.
```

Do not replace the actual dependency list with this abbreviated example.

## 6. Merge the release configuration

The package contains:

```text
config/ecai_step03_sys_config.fragment.config
```

Merge these keys into the existing `ecai` application configuration. Do not add
a second duplicate `{ecai, [...]}` tuple.

```erlang
{ecai, [
    {ingest_wal_enabled, true},
    {ipfs_index_dir, "/var/lib/damage/ecai/ipfs-index"},
    {ingest_wal_max_batch_events, 4096},
    {ingest_wal_max_batch_bytes, 67108864}
]}.
```

Meanings:

- `ingest_wal_enabled`: starts the durable ingest supervisor.
- `ipfs_index_dir`: owns the `wal/ecai-ingest-v1.wal` file.
- `ingest_wal_max_batch_events`: maximum new events in one physical WAL batch.
- `ingest_wal_max_batch_bytes`: maximum encoded bytes in one physical batch.

The code also has hard ceilings of 65,535 events, 1 GiB per batch, and 32 MiB
per encoded record. Do not set operational limits near the hard ceilings without
load testing.

## 7. Pre-provision storage

Use the real DamageBDD service account and group in place of the placeholders:

```sh
sudo install -d \
  -o DAMAGEBDD_USER \
  -g DAMAGEBDD_GROUP \
  -m 0750 \
  /var/lib/damage/ecai/ipfs-index/wal

sudo -u DAMAGEBDD_USER sh -c \
  'umask 027; touch /var/lib/damage/ecai/ipfs-index/wal/ecai-ingest-v1.wal'

sudo chown DAMAGEBDD_USER:DAMAGEBDD_GROUP \
  /var/lib/damage/ecai/ipfs-index/wal/ecai-ingest-v1.wal
sudo chmod 0640 \
  /var/lib/damage/ecai/ipfs-index/wal/ecai-ingest-v1.wal

sync
```

Pre-creating the file during deployment avoids making the first application
commit depend on persistence of a newly created directory entry. The runtime
syncs the WAL data file, but it does not currently open and sync the parent
directory as a separate durability operation.

Recommended storage properties:

- local persistent block storage;
- sufficient free space and inode capacity;
- no shared multi-writer mount;
- backups or storage snapshots appropriate to the deployment;
- monitoring on both bytes and filesystem errors.

Exactly one ECAI writer service instance may use a given `ipfs_index_dir`.
Step 3 detects unexpected size changes before an append but does not yet acquire
a robust cross-process filesystem lock.

## 8. Inspect the pending changes

```sh
git diff --stat

git diff -- \
  apps/ecai/src/ecai_chunker.erl \
  apps/ecai/src/ecai_ingest_event.erl \
  apps/ecai/src/ecai_ingest_record.erl \
  apps/ecai/src/ecai_wal.erl \
  apps/ecai/src/ecai_ingest_writer.erl \
  apps/ecai/src/ecai_ingest_sup.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_sup.erl \
  apps/ecai/test
```

# Run the tests with Rebar3

Run every command from the DamageBDD repository root.

## 1. Re-run the previous atomic steps

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests

rebar3 eunit \
  --application=ecai \
  --module=ecai_ingest_event_tests
```

## 2. Test the bounded record codec

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_ingest_record_tests
```

This covers round trips, canonical tags, truncated records, trailing bytes,
identity tampering, malformed UTF-8, unsupported fields, and CID/source-version
binding.

## 3. Test the WAL and recovery rules

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_wal_tests
```

This covers:

- ordered recovery of committed batches;
- removal of incomplete first and later batches;
- repair of a short physical tail;
- fail-closed payload and header corruption;
- duplicate-event rejection at the WAL layer;
- byte and event admission limits;
- unexpected external file-size change detection.

## 4. Test writer replay and supervision

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_ingest_writer_tests
```

The crash test terminates the writer after WAL sync but before ETS installation.
The supervisor must restart it, replay the committed record, retain document ID
`1`, and turn the client retry into a no-op.

## 5. Test the IPFS record-building boundary

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_ipfs_ingest_step03_tests
```

This verifies deterministic source records, gap-free chunk offsets, empty and
invalid UTF-8 rejection, and bounded source chunk generation.

## 6. Compile and run broader suites

```sh
rebar3 as test compile
rebar3 eunit --application=ecai
rebar3 eunit
```

All commands must exit with status `0` in the supported DamageBDD build
environment.

## 7. Retain test evidence

```sh
mkdir -p artifacts/test
set -o pipefail

for module in \
  ecai_chunker_tests \
  ecai_ingest_event_tests \
  ecai_ingest_record_tests \
  ecai_wal_tests \
  ecai_ingest_writer_tests \
  ecai_ipfs_ingest_step03_tests
do
  rebar3 eunit \
    --application=ecai \
    --module="$module" \
    2>&1 | tee "artifacts/test/step03-${module}.log"
done
```

Because `pipefail` is enabled, a failing Rebar3 command makes the loop fail even
though its output is piped through `tee`.

# Manual smoke test without fetching IPFS

Start an Erlang shell through the project:

```sh
rebar3 shell
```

Then evaluate:

```erlang
BaseDir = "/tmp/ecai-step03-smoke".

{ok, Writer1} = ecai_ingest_writer:start_link(BaseDir).

{ok, Records} = ecai_ipfs_ingest:build_records(
    <<"org.damagebdd.smoke/document">>,
    <<"bafy-smoke-version-1">>,
    <<"Step 3 smoke test">>,
    <<"A deterministic ECAI record committed to the local WAL.">>
).

{ok, Ack1} = ecai_ingest_writer:submit_batch(Writer1, Records).
true = maps:get(durable, Ack1).
false = maps:get(index_searchable, Ack1).
1 = maps:get(durable_new, Ack1).

[Record] = Records.
EventId = maps:get(event_id, Record).

Status1 = ecai_ingest_writer:status(Writer1).
1 = maps:get(record_count, Status1).
local_wal = maps:get(durability_scope, Status1).
ledger_only = maps:get(publication_state, Status1).

ok = ecai_ingest_writer:stop(Writer1).

{ok, Writer2} = ecai_ingest_writer:start_link(BaseDir).
{ok, #{doc_id := 1, record := Record}} =
    ecai_ingest_writer:lookup_event(Writer2, EventId).

{ok, RetryAck} = ecai_ingest_writer:submit_batch(Writer2, Records).
0 = maps:get(durable_new, RetryAck).
1 = maps:get(duplicates, RetryAck).

ok = ecai_ingest_writer:stop(Writer2).
```

Remove the smoke directory only after the writer is stopped:

```sh
rm -rf /tmp/ecai-step03-smoke
```

# Production ingest API

With `ingest_wal_enabled` set to `true` and the ECAI application running, use
the long-lived supervised writer:

```erlang
ecai_ipfs_ingest:ingest_live_cid(
    <<"org.damagebdd.docs/manual/install">>,
    <<"bafy-current-content-version">>,
    <<"Install DamageBDD">>
).
```

The result is a detailed acknowledgment. Do not reduce this production result
to a bare `ok`; operators need the durability and publication fields.

The legacy `ingest_cid/3`, `ingest_cid/4`, and `ingest_manifest/2` wrappers
remain for compatibility and return `ok` after a durable ledger commit. They do
not mean the record is searchable. New production callers should use
`ingest_live_*` or `ingest_*_to` and inspect the acknowledgment.

A manifest document may include a stable logical source key:

```json
{
  "name": "DamageBDD documentation",
  "docs": [
    {
      "source_key": "org.damagebdd.docs/manual/install",
      "cid": "bafy-current-content-version",
      "title": "Install DamageBDD"
    }
  ]
}
```

Each manifest document is committed as its own atomic source-version batch.
The complete multi-document manifest is not one transaction in Step 3. If a
later document fails, retry the manifest; earlier documents are deduplicated.

# Operator status

From a release remote console or project shell:

```erlang
ecai_ingest_writer:status().
```

Important fields:

| Field | Meaning |
|---|---|
| `ready` | The writer opened and validated the WAL. |
| `path` | Active WAL file. |
| `wal_bytes` | Current physical WAL size. |
| `batch_count` | Complete physical batches recovered or appended. |
| `event_count` | Complete physical event frames. |
| `record_count` | Unique durable `event_id` values in the ledger. |
| `next_doc_id` | Next local document ID. |
| `message_queue_len` | Current writer mailbox depth. Sustained growth is an overload signal. |
| `repaired_bytes_at_startup` | Incomplete tail bytes removed during the latest startup. |
| `durability_scope` | `local_wal` in Step 3. |
| `publication_state` | `ledger_only` until Step 4. |
| `index_searchable` | Always `false` in Step 3. |

Inspect a bounded sample in local document-ID order:

```erlang
ecai_ingest_writer:list_records(10).
```

Do not expose this administrative output on the public query API because it can
contain indexed text and source metadata.

# WAL format v1

The file is:

```text
<ipfs_index_dir>/wal/ecai-ingest-v1.wal
```

All integers are unsigned big-endian.

## Frame header

Every frame has a 24-byte header:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 8 | ASCII magic `ECAIWAL1` |
| 8 | 1 | WAL format version, currently `1` |
| 9 | 1 | frame type: begin `1`, event `2`, commit `3` |
| 10 | 2 | reserved, must be zero |
| 12 | 4 | payload length |
| 16 | 4 | CRC32 of header bytes 0 through 15 |
| 20 | 4 | CRC32 of the payload |
| 24 | variable | payload |

CRC32 detects accidental damage and torn/corrupt frames. It is not a message
authentication code and does not protect against a malicious actor who can
rewrite the WAL and recompute checksums. Filesystem permissions and host
security remain required.

## Batch frames

A complete batch is:

```text
BATCH_BEGIN
EVENT × count
BATCH_COMMIT
```

Begin and commit payloads are:

```text
batch_id: 32 bytes
count:     4 bytes
```

An event payload is:

```text
batch_id:      32 bytes
event_id:      32 bytes
record_length:  4 bytes
record:         record_length bytes
```

`batch_id` is SHA-256 over a versioned domain, event count, and ordered event
IDs. Recovery verifies the begin ID, every event's batch ID and event ID, event
count, commit ID, and recomputed batch ID.

## Record codec v1

The event record starts with:

```text
ECAIREC1
version = 1
flags
reserved = 0
```

It then stores only the bounded Step 2 record schema. Variable fields are
length-prefixed. Identity fields are fixed 32-byte values. The decoder rejects
unknown versions, invalid flags, oversized values, truncated values, trailing
bytes, malformed UTF-8, identity mismatches, and an IPFS CID that differs from
`source_version`.

The WAL does not call `binary_to_term/1`, so untrusted or corrupted WAL bytes
cannot request arbitrary Erlang term construction.

The package includes `ecai_wal_v1_golden.json`. Its one-event vector fixes the
record size and SHA-256, batch ID, frame offsets, total WAL size, and complete
WAL SHA-256. EUnit checks the same constants so a format change cannot happen
silently under version `1`.

# Recovery behavior

At startup the writer scans from byte zero.

A physically incomplete tail is safe to repair only when it occurs after the
last valid committed boundary or inside the current uncommitted batch. Recovery
truncates to:

- the current valid offset when no batch is open; or
- the open batch's begin offset when a batch is incomplete.

The truncation itself is synced before the writer becomes ready.

A checksum, structure, record, event-ID, batch-ID, or commit error in complete
history returns:

```erlang
{error, {wal_corrupt, #{offset => Offset, reason => Reason}}}
```

The writer and supervised ECAI application must not advertise readiness in that
state.

# Runbooks

## Incomplete tail repaired at startup

Signal:

```erlang
maps:get(repaired_bytes_at_startup, ecai_ingest_writer:status()) > 0
```

Actions:

1. Record the host restart, VM crash, or storage incident that preceded it.
2. Confirm the focused WAL and writer tests pass in the deployed build.
3. Confirm recovered `record_count`, source samples, and expected caller retries.
4. Alert on repeated repairs without a known crash; this can indicate storage or
   shutdown problems.

An incomplete tail is not treated as committed data.

## `wal_corrupt` prevents startup

Actions:

1. Stop automatic restart loops and pause ingestion.
2. Copy the entire `ipfs_index_dir` and preserve file metadata before changing
   anything.
3. Record the corruption offset and reason from logs.
4. Do not delete the WAL or force an empty startup.
5. Restore a verified storage snapshot or investigate the damaged bytes against
   a known replica/export.
6. Re-run recovery and EUnit crash tests before returning the service to use.

Step 3 intentionally has no “ignore corruption” switch.

## Disk nearly full or append/sync errors

Actions:

1. Pause callers before the filesystem is exhausted.
2. Expand or replace storage; do not manually trim the WAL.
3. Inspect service and kernel filesystem errors.
4. Restart the writer only after storage is healthy.
5. Retry uncertain batches using their original records; `event_id` makes the
   retry idempotent.

The writer stops after a WAL append or sync error because storage may have
accepted an uncertain prefix or complete batch. Restart recovery must establish
the exact durable state before another write.

## Unexpected WAL size change

Signal:

```erlang
{error, {wal_size_changed, Expected, Actual}}
```

This usually means another process or operator modified the file. Stop all
writers, preserve the directory, identify the extra writer or mutation, and run
recovery verification. Never run two writer instances against one directory.

## Backup and restore

For a simple consistent backup:

1. Pause ingestion.
2. Stop the ECAI application or writer cleanly.
3. Snapshot or copy the complete `ipfs_index_dir`.
4. Preserve ownership, mode, and configuration.
5. Restart and check status.
6. Test the backup by restoring it to an isolated directory and opening it with
   the same application version.

A storage-level crash-consistent snapshot can be used while running when the
storage system provides the required guarantees. Step 3 does not split or
checkpoint the WAL, so the complete file must be retained.

# Efficiency characteristics

- The writer serializes only commit ownership; IPFS fetching and future parsing
  can remain concurrent outside it.
- One `file:write/2` and one `file:sync/1` are used per non-empty new batch.
- Duplicate-only retries perform no WAL write.
- ETS supplies constant-time event-ID lookup and ordered local document lookup.
- Source record building stops at the writer's configured event limit instead
  of constructing an unbounded record list.
- Batch byte and event limits are checked before a write.
- Recovery is currently linear in total WAL size and recreates the full ledger
  in memory.

The final point is why Step 4 must add immutable checkpoints and WAL prefix
reclamation before production data volume becomes large.

# Security boundaries

- The WAL is a local durability log, not a public transport format.
- The custom decoder uses fixed schema fields and explicit bounds.
- Full record identity is recomputed during decode and recovery.
- CRC32 is corruption detection, not cryptographic authentication.
- The service account should be the only writer to the index directory.
- Do not log full text, source records, signing material, or private source
  metadata.
- Do not expose `list_records/1` publicly.
- IPFS content authenticity still depends on CID verification in the IPFS
  retrieval layer; Step 3 does not replace it.

# Acceptance gate

Do not proceed to Step 4 until every condition is true:

1. `rebar3 as test compile` succeeds.
2. All six focused EUnit modules pass.
3. `rebar3 eunit --application=ecai` passes.
4. The complete DamageBDD EUnit suite passes.
5. The manual stop/restart smoke test recovers the same `event_id` at the same
   local document ID.
6. The simulated crash after sync but before ETS installation passes.
7. Retrying the same batch adds zero WAL bytes and zero new records.
8. A partial final batch is removed on restart and reported through
   `repaired_bytes_at_startup`.
9. Corruption in a complete event frame prevents startup.
10. Event and byte limits reject input before the WAL grows.
11. Only one service instance can access the configured directory in the
    deployment design.
12. Storage ownership, capacity alerts, backup, restore, and corruption runbooks
    have been exercised.
13. Operators understand that `durable=true` still means
    `index_searchable=false` in Step 3.

# Next minimum atomic step

Step 4 will make durable records searchable without losing the Step 3 commit
semantics:

```text
committed WAL
    → active ETS term memtable
    → frozen memtable
    → immutable segment.tmp
    → sync + checksum + rename
    → versioned manifest checkpoint
    → safe WAL prefix reclamation
```

The Step 4 manifest must record exactly which WAL boundary it covers. Only after
that manifest is durable may the covered WAL prefix be reclaimed.
