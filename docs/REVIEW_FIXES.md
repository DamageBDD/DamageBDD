# ECAI review fixes

This package resolves the blocking module-reference, compatibility, and
indexing-consistency findings from the reviewed Step 3 diff.

## Files changed

```text
apps/damage/src/damage_ipfs.erl
apps/ecai/src/ecai_search.hrl
apps/ecai/src/ecai_disk_docstore.erl
apps/ecai/src/ecai_disk_indexer.erl
apps/ecai/src/ecai_ingest_event.erl
apps/ecai/src/ecai_ipfs_ingest.erl
apps/ecai/src/ecai_search.erl
apps/ecai/src/ecai_terms.erl
apps/ecai/test/ecai_step03_source_coherence_tests.erl
apps/ecai/test/ecai_terms_tests.erl
```

## Corrections

### Canonical term pipeline

`ecai_terms` is now a complete module rather than a partial extraction of the
old `ecai_search` helpers. It preserves the existing Yelp term wire format and
adds deterministic fields for Wikipedia and IPFS records.

Supported record families include:

```text
Yelp:       name, category, city, tags, phone
Wikipedia:  name, category, tags, abstract, language, wikidata_id
IPFS:       title, heading, text, type, tags
```

Both `ecai_search` and `ecai_disk_indexer` use this module. Query maps may use
atom or UTF-8 binary keys.

`ecai_ingest_event:pipeline_version/0` delegates to
`ecai_terms:version/0`, and the exact returned value is used in event hashing
and persisted event metadata. The current value remains `ecai-terms/v1`, so
the existing event and WAL golden vectors remain unchanged.

### IPFS content retrieval

`damage_ipfs` now exports:

```erlang
damage_ipfs:cat_binary/1.
damage_ipfs:get/1.
```

`cat_binary/1` normalizes both response shapes already used by DamageBDD:

```erlang
{ok, Binary}
Binary
```

`get/1` is a compatibility alias for byte retrieval. Existing `get/2` retains
its file-download behavior.

`ecai_ipfs_ingest` uses `cat_binary/1`; it no longer calls an unresolved
`damage_ipfs:get/1` implementation or hides that failure under a broad catch.

### Searchable compatibility versus WAL durability

The APIs now have explicit behavior:

```text
ingest_cid/*, ingest_manifest/2
    Build deterministic records and publish searchable disk segments.

ingest_live_* and ingest_*_to
    Submit to the long-lived WAL writer and return its acknowledgement.
```

The BaseDir compatibility path no longer creates temporary WAL supervisors.
A per-BaseDir `global:trans/2` lock serializes legacy searchable writes across
connected Erlang nodes. It is not a substitute for an operating-system lock
when unrelated BEAM instances write the same directory.

The live path still requires the supervised writer owned by `ecai_ingest_sup`.

### Disk metadata and IDs

`ecai_disk_docstore:next_id/1` now uses `dets:update_counter/3`, avoiding the
old read-modify-write allocation race. DETS insert errors are no longer hidden.

`ecai_disk_indexer` adds `add_records/2`, preserves deterministic event
metadata, keeps tag boundaries, syncs document metadata before manifest
publication, and provides the searchable compatibility ingestion primitive.

### Search context correctness and bulk efficiency

`ecai_search` now:

- uses private unnamed ETS tables;
- reserves `DocId -> DocInt` mappings with integer values only;
- allocates document IDs atomically;
- updates document frequencies atomically;
- delegates record and query expansion to `ecai_terms`;
- supports IPFS and Wikipedia field weights;
- handles term tokens containing `:` when deriving score fields;
- preserves immediate root publication by default;
- supports `root_mode => deferred` for bulk indexing;
- rebuilds all roots in `finalize/1` and before snapshots are saved.

Bulk example:

```erlang
Ctx0 = ecai_search:new(),
Ctx = ecai_search:set_opts(Ctx0, #{root_mode => deferred}),

ok = ecai_search:add_record(Ctx, DocId1, Record1),
ok = ecai_search:add_record(Ctx, DocId2, Record2),

Ctx = ecai_search:finalize(Ctx).
```

Use the context returned by `set_opts/2`; the options are held in the context
record even though the underlying ETS tables are shared by that record copy.

## Install

From the DamageBDD repository root:

```sh
cd /home/steven/DamageInc/DamageBDD

git apply --check /path/to/ecai_review_fixes.patch
git apply /path/to/ecai_review_fixes.patch
```

Or copy the packaged application trees:

```sh
cp -a /path/to/ecai_review_fixes/apps/. apps/
```

Apply the two small test-source cleanups:

```sh
git apply --check /path/to/patches/test_source_cleanup.patch
git apply /path/to/patches/test_source_cleanup.patch
```

When a top-level `eunit_opts` entry does not already exist, add:

```erlang
{eunit_opts, [exact_execution]}.
```

When it exists, merge `exact_execution` into that list rather than adding a
second configuration entry.

## Test

Clear stale beams from the previous mixed source tree:

```sh
rm -f \
  _build/test/lib/ecai/ebin/ecai_terms.beam \
  _build/test/lib/ecai/ebin/ecai_search.beam \
  _build/test/lib/ecai/ebin/ecai_ingest_event.beam \
  _build/test/lib/ecai/ebin/ecai_ipfs_ingest.beam \
  _build/test/lib/ecai/ebin/ecai_disk_docstore.beam \
  _build/test/lib/ecai/ebin/ecai_disk_indexer.beam \
  _build/test/lib/damage/ebin/damage_ipfs.beam

rebar3 as test compile
```

Run focused tests with one selector at a time:

```sh
rebar3 eunit --module=ecai_terms_tests
rebar3 eunit --module=ecai_step03_source_coherence_tests
rebar3 eunit --module=ecai_ingest_event_tests
rebar3 eunit --module=ecai_ingest_record_tests
rebar3 eunit --module=ecai_ipfs_ingest_step03_tests
rebar3 eunit --module=ecai_search_tests
```

Then run the broader gates:

```sh
rebar3 eunit --application=ecai
rebar3 eunit
rebar3 xref
```

The `simulated_crash_after_sync` report in the WAL recovery test is expected
once: that test deliberately kills the writer after the WAL commit has been
synced and verifies supervisor recovery. Duplicate reports indicate duplicate
EUnit selection, which `exact_execution` is intended to prevent.

## Suggested commit

```text
fix(ecai): unify term indexing and harden IPFS ingestion

Complete the shared Yelp, Wikipedia, and IPFS term pipeline; bind ingest
identity to its canonical version; normalize IPFS byte retrieval; preserve
searchable BaseDir ingestion without temporary WAL writers; make disk and ETS
ID allocation atomic; and add runtime-coherence coverage.
```
