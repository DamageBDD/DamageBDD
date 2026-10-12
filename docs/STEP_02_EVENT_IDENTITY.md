# ECAI production step 02: deterministic ingest-event identity

This is the second minimum production step for the global ECAI IPFS index.

Step 1 made UTF-8 chunk boundaries deterministic. Step 2 gives every emitted
chunk event a deterministic identity that can later be written to a WAL,
replayed, verified, and deduplicated without guessing whether two deliveries
represent the same indexed state.

This step defines identity only. It does **not** yet make document ingestion
transactional or suppress duplicate writes.

## Resulting contract

The new event schema is:

```text
ecai-ingest-event/v1
```

The current term-pipeline identity is:

```text
ecai-terms/v1
```

Each chunk record now carries:

```text
source_key
source_version
chunker
chunk_ordinal
chunk_byte_start
chunk_byte_end
chunk_content_sha256
index_fields_sha256
chunk_id
event_id
event_schema
event_operation
event_pipeline
```

### Identity meanings

`source_key` is the stable logical identity of the source. It must be globally
scoped and must not change merely because the source receives a new IPFS CID.

Examples:

```text
did:key:z6Mk.../damagebdd/manual/install
org.damagebdd.docs/manual/install
ipfs://bafy...        # immutable-CID fallback only
```

`source_version` is the immutable version currently being indexed. In the
current IPFS ingestion path, it is the source CID.

`chunk_id` identifies one deterministic chunk within one source version. It is
bound to:

```text
source_key
source_version
chunker version
chunk ordinal
inclusive byte start
exclusive byte end
SHA-256 of chunk text
```

`event_id` additionally binds the index-relevant metadata and term-pipeline
version:

```text
event schema
operation
term-pipeline version
source_key
source_version
chunk_id
SHA-256 of canonical index fields
```

The canonical index fields in version 1 are:

```text
title
heading
type
tags
```

Tags are treated as set-like data. They are validated as UTF-8, sorted by their
binary value, and deduplicated before hashing and storage.

A local wall-clock timestamp is deliberately excluded from event identity. The
same clean source must generate the same IDs regardless of where or when an
indexer receives it.

## Canonical binary encoding

The identity implementation does not hash an Erlang map or JSON serialization.
It uses an explicit fixed-order binary encoding:

- SHA-256 for all hashes;
- a domain string followed by one `00` byte;
- binary values prefixed by an unsigned 32-bit big-endian byte length;
- ordinals and byte offsets encoded as unsigned 64-bit big-endian integers;
- tags encoded as a 32-bit count followed by canonical length-prefixed values;
- raw 32-byte hashes embedded directly in the parent identity.

This avoids dependence on map iteration order, JSON whitespace, Erlang external
term encoding, or implementation-specific serializers.

The supplied golden vector fixes the expected cross-language results:

```text
chunk content SHA-256
9f770d8fbf2f57711bb5b0c2c13f8a36b554f8d34f8fc9a62907d3fa909c0da9

index fields SHA-256
add57b4edb07335eb67420546c40235cc34e0334bdffd2dcc30be0577c8b66c3

chunk ID
28d1d7e349fcbcebd30bff835bedfc2ad06008d4451bc9d9f9c8252698a3ed0a

event ID
06ff09f9f6722334b4da5561cfc884ac094edbd7262b515eb27ccb2d046946d3
```

## Files in this step

Install these files in the DamageBDD umbrella project:

```text
apps/ecai/src/ecai_ingest_event.erl
apps/ecai/src/ecai_chunker.erl
apps/ecai/src/ecai_ipfs_ingest.erl
apps/ecai/src/ecai_disk_indexer.erl
apps/ecai/test/ecai_ingest_event_tests.erl
apps/ecai/test/ecai_chunker_tests.erl
apps/ecai/test/fixtures/ecai_ingest_event_v1_golden.json
```

Changes by file:

- `ecai_ingest_event.erl` defines, validates, hashes, flattens, and verifies the
  deterministic event envelope.
- `ecai_chunker.erl` now includes its version in each emitted chunk map, making
  the chunk self-describing.
- `ecai_ipfs_ingest.erl` creates an event identity before allocating a local
  document ID or adding the document to the current indexer.
- `ecai_ipfs_ingest.erl` adds `ingest_cid/4` for an explicit stable source key.
- `ecai_disk_indexer.erl` persists all identity fields.
- `ecai_disk_indexer.erl` preserves tag-list boundaries instead of converting
  a tag list into one binary.
- `ecai_ingest_event_tests.erl` covers determinism, metadata changes, content
  changes, source changes, canonical tags, tamper detection, validation, and
  the fixed golden vector.

## 1. Enter the DamageBDD project root

Run all commands from the directory containing the top-level `rebar.config` and
`apps/` directory:

```sh
cd /path/to/DamageBDD

test -f rebar.config
test -d apps/ecai/src
mkdir -p apps/ecai/test/fixtures
```

All three commands must succeed.

## 2. Back up the current Step 1 files

```sh
cp apps/ecai/src/ecai_chunker.erl \
  apps/ecai/src/ecai_chunker.erl.before_step02

cp apps/ecai/src/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl.before_step02

cp apps/ecai/src/ecai_disk_indexer.erl \
  apps/ecai/src/ecai_disk_indexer.erl.before_step02

cp apps/ecai/test/ecai_chunker_tests.erl \
  apps/ecai/test/ecai_chunker_tests.erl.before_step02
```

Commit or otherwise retain the current working tree before replacing files.

## 3. Copy the Step 2 files

Replace `/path/to/ecai_step_02` with the extracted Step 2 package directory:

```sh
cp /path/to/ecai_step_02/apps/ecai/src/ecai_ingest_event.erl \
  apps/ecai/src/ecai_ingest_event.erl

cp /path/to/ecai_step_02/apps/ecai/src/ecai_chunker.erl \
  apps/ecai/src/ecai_chunker.erl

cp /path/to/ecai_step_02/apps/ecai/src/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl

cp /path/to/ecai_step_02/apps/ecai/src/ecai_disk_indexer.erl \
  apps/ecai/src/ecai_disk_indexer.erl

cp /path/to/ecai_step_02/apps/ecai/test/ecai_ingest_event_tests.erl \
  apps/ecai/test/ecai_ingest_event_tests.erl

cp /path/to/ecai_step_02/apps/ecai/test/ecai_chunker_tests.erl \
  apps/ecai/test/ecai_chunker_tests.erl

cp /path/to/ecai_step_02/apps/ecai/test/fixtures/ecai_ingest_event_v1_golden.json \
  apps/ecai/test/fixtures/ecai_ingest_event_v1_golden.json
```

Inspect the exact change set:

```sh
git diff -- \
  apps/ecai/src/ecai_ingest_event.erl \
  apps/ecai/src/ecai_chunker.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_disk_indexer.erl \
  apps/ecai/test/ecai_ingest_event_tests.erl \
  apps/ecai/test/ecai_chunker_tests.erl \
  apps/ecai/test/fixtures/ecai_ingest_event_v1_golden.json
```

## 4. Ensure the OTP `crypto` application is declared

`ecai_ingest_event` uses `crypto:hash/2`. Check the ECAI application resource:

```sh
grep -n "applications" apps/ecai/src/ecai.app.src
```

The existing application list must include `crypto`, while preserving all
other dependencies. Conceptually, it should contain:

```erlang
{applications, [kernel, stdlib, crypto]}
```

Do not replace an existing larger list with only these three entries.

## 5. Run the Step 1 regression test

The chunk map now contains an additional `chunker` field, so install the updated
Step 1 test and run it first:

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests
```

Expected shell status:

```sh
echo $?
```

```text
0
```

## 6. Run the focused Step 2 test

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_ingest_event_tests
```

The golden-vector test must pass exactly. A changed expected hash is not a
routine test update: it means the identity protocol changed and requires an
explicit schema or pipeline-version decision.

## 7. Compile the full test profile

```sh
rebar3 as test compile
```

This validates integration compilation for `ecai_ipfs_ingest`,
`ecai_disk_indexer`, and the rest of the DamageBDD umbrella dependencies.

## 8. Run application and project tests

Run all ECAI EUnit tests:

```sh
rebar3 eunit --application=ecai
```

Then run the complete DamageBDD EUnit suite:

```sh
rebar3 eunit
```

All commands must return status `0` before this step is accepted.

## 9. Capture reviewable test evidence

```sh
mkdir -p artifacts/test
set -o pipefail

rebar3 eunit \
  --application=ecai \
  --module=ecai_ingest_event_tests \
  2>&1 | tee artifacts/test/step02-event-identity-eunit.log
```

Then capture the Step 1 regression separately:

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests \
  2>&1 | tee artifacts/test/step02-chunker-regression-eunit.log
```

A log file is not evidence of success unless the piped command returns status
`0` under `set -o pipefail`.

## 10. Update clean-source manifests

For a mutable logical document, add an explicit stable `source_key`:

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

When the content changes:

- retain the same `source_key`;
- publish a new immutable `cid`;
- that new CID becomes `source_version`;
- new chunks receive new `chunk_id` and `event_id` values.

When `source_key` is omitted, `ingest_cid/3` and manifest ingestion use:

```text
ipfs://<CID>
```

That fallback is globally unique for immutable content, but a new CID is treated
as a new logical source. It is not sufficient for future update/tombstone
semantics.

## Optional identity inspection in a Rebar3 shell

Start an ECAI test shell:

```sh
rebar3 as test shell --apps ecai
```

Then evaluate:

```erlang
Text = <<"ECAI retrieves a deterministic state.">>,
Chunk = #{
    chunker => <<"ecai-utf8-window/v1">>,
    ordinal => 7,
    byte_start => 100,
    byte_end => 100 + byte_size(Text),
    text => Text
},
Fields = #{
    title => <<"Operator guide">>,
    heading => <<"Atomic identity">>,
    type => <<"ipfs">>,
    tags => [<<"production">>, <<"ecai">>]
},
{ok, Event} = ecai_ingest_event:new_upsert_chunk(
    <<"org.damagebdd.docs/manual/install">>,
    <<"bafy-version-001">>,
    Chunk,
    Fields
),
ecai_ingest_event:id_hex(maps:get(event_id, Event)).
```

Expected result:

```erlang
<<"06ff09f9f6722334b4da5561cfc884ac094edbd7262b515eb27ccb2d046946d3">>
```

Exit the shell with `q().`.

## Operator rules introduced by Step 2

1. A `source_key` is a stable logical name, not a timestamp and not normally a
   current CID.
2. A `source_version` must identify immutable source state; the current IPFS
   adapter uses the fetched CID.
3. No local observation time, node name, document integer, or segment number may
   influence `chunk_id` or `event_id`.
4. Any change to `ecai_terms` that can alter generated terms requires a new
   `event_pipeline` value and new golden vectors.
5. Any change to canonical field order, integer encoding, framing, hash domains,
   or tag treatment requires a new event-schema version.
6. Store raw 32-byte IDs internally. Convert to lowercase hex only for logs,
   diagnostics, CLI output, or APIs that require text.
7. Log IDs and source keys, but do not log full chunk text by default.

## Acceptance gate

Do not begin WAL implementation until all of the following are true:

- the updated `ecai_chunker_tests` suite passes;
- `ecai_ingest_event_tests` passes, including the exact golden vector;
- `rebar3 as test compile` succeeds;
- `rebar3 eunit --application=ecai` succeeds;
- the complete DamageBDD EUnit suite succeeds in the supported build environment;
- the same source input produces byte-identical `chunk_id` and `event_id` values
  across repeated runs;
- changing chunk content changes both IDs;
- changing title, heading, type, tags, or pipeline changes `event_id`;
- merely reordering or duplicating identical tags does not change `event_id`;
- `ecai_ingest_event:verify_record/1` returns `ok` for stored test records and
  rejects modified records;
- mutable clean-source entries have explicit globally scoped `source_key` values;
- test evidence is retained for review or CI.

## Deliberately not solved by this step

Step 2 does not yet provide:

- a write-ahead log;
- an atomic all-chunks-or-no-chunks document commit;
- a single owner for document-ID allocation;
- durable event deduplication;
- crash replay;
- update tombstones;
- manifest/source checkpoint commits;
- globally signed publisher advertisements.

Re-ingesting the same event currently produces the same `event_id`, but the
prototype storage path can still allocate another local document ID and write a
duplicate posting. The identity needed to prevent that now exists; enforcement
belongs at the writer/WAL boundary.

## Next minimum atomic step

Step 3 should introduce one supervised writer process that owns local document
IDs and a framed, checksummed WAL batch protocol:

```text
batch_begin
event 1
event 2
...
batch_commit
explicit WAL sync
```

Only a complete, synced batch may be acknowledged or applied. Recovery will
ignore incomplete batches, replay committed batches, and use the Step 2
`event_id` as the idempotency key.
