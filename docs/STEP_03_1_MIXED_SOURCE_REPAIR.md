# ECAI Step 3.1 — repair a mixed Step 1/2/3 source tree

The reported failures are caused by loading incompatible cumulative revisions:

- `ecai_ingest_record` and the WAL/writer are Step 3;
- `ecai_ingest_event` is an older revision that hashes arbitrary text bytes
  instead of rejecting malformed UTF-8;
- `ecai_ipfs_ingest` is an older revision that does not export
  `build_records/4` or `build_records/5`;
- the corresponding older `ecai_chunker` does not place its version in each
  emitted chunk map.

This repair does not change the Step 3 WAL or record binary formats. It makes
all modules use the cumulative Step 3 contracts and adds a source-coherence
regression test.

## Install from the DamageBDD root

Back up the affected files first:

```sh
cd /home/steven/DamageInc/DamageBDD
mkdir -p /tmp/ecai-step03-before-repair
cp apps/ecai/src/ecai_chunker.erl /tmp/ecai-step03-before-repair/
cp apps/ecai/src/ecai_ingest_event.erl /tmp/ecai-step03-before-repair/
cp apps/ecai/src/ecai_ipfs_ingest.erl /tmp/ecai-step03-before-repair/
cp apps/ecai/src/ecai_disk_indexer.erl /tmp/ecai-step03-before-repair/
```

Extract the repair package and replace the cumulative runtime files:

```sh
rm -rf /tmp/ecai-step03-repair
unzip /path/to/ecai_step_03_1_mixed_source_fix.zip \
  -d /tmp/ecai-step03-repair

FIX=/tmp/ecai-step03-repair/ecai_step_03_1_mixed_source_fix

cp "$FIX/apps/ecai/src/ecai_chunker.erl" \
  apps/ecai/src/ecai_chunker.erl
cp "$FIX/apps/ecai/src/ecai_ingest_event.erl" \
  apps/ecai/src/ecai_ingest_event.erl
cp "$FIX/apps/ecai/src/ecai_ipfs_ingest.erl" \
  apps/ecai/src/ecai_ipfs_ingest.erl
cp "$FIX/apps/ecai/src/ecai_disk_indexer.erl" \
  apps/ecai/src/ecai_disk_indexer.erl

cp "$FIX/apps/ecai/test/ecai_ingest_event_tests.erl" \
  apps/ecai/test/ecai_ingest_event_tests.erl
cp "$FIX/apps/ecai/test/ecai_step03_source_coherence_tests.erl" \
  apps/ecai/test/ecai_step03_source_coherence_tests.erl
```

Verify the three contract markers before compiling:

```sh
grep -n 'checked_utf8_binary(text' \
  apps/ecai/src/ecai_ingest_event.erl

grep -n 'build_records/4' \
  apps/ecai/src/ecai_ipfs_ingest.erl

grep -n 'chunker => version()' \
  apps/ecai/src/ecai_chunker.erl
```

All three commands must print a matching line.

## Remove stale ECAI beams and compile

A source replacement does not help when an older test-profile beam remains on
the code path. Remove only the affected ECAI beams, then compile again:

```sh
rm -f \
  _build/test/lib/ecai/ebin/ecai_chunker.beam \
  _build/test/lib/ecai/ebin/ecai_ingest_event.beam \
  _build/test/lib/ecai/ebin/ecai_ipfs_ingest.beam \
  _build/test/lib/ecai/ebin/ecai_disk_indexer.beam

rebar3 as test compile
```

When the project still loads an old module, perform the broader clean rebuild:

```sh
rebar3 as test clean
rebar3 as test compile
```

## Check the loaded Step 3 API

```sh
erl -noshell \
  -pa _build/test/lib/*/ebin \
  -eval '
    io:format("ecai_ipfs_ingest beam: ~p~n", [code:which(ecai_ipfs_ingest)]),
    io:format("exports: ~p~n", [ecai_ipfs_ingest:module_info(exports)]),
    true = erlang:function_exported(ecai_ipfs_ingest, build_records, 4),
    true = erlang:function_exported(ecai_ipfs_ingest, build_records, 5),
    {ok, [Chunk]} = ecai_chunker:chunk_utf8(<<"abc">>, 4, 1),
    true = maps:is_key(chunker, Chunk),
    halt(0).
  '
```

The printed beam path must be under `_build/test/lib/ecai/ebin`, and both
`build_records` arities must be present.

## Run the repaired tests

Use one selector for the focused runs:

```sh
rebar3 eunit --module=ecai_step03_source_coherence_tests
rebar3 eunit --module=ecai_chunker_tests
rebar3 eunit --module=ecai_ingest_event_tests
rebar3 eunit --module=ecai_ingest_record_tests
rebar3 eunit --module=ecai_ipfs_ingest_step03_tests
```

Then run the application and umbrella gates:

```sh
rebar3 eunit --application=ecai
rebar3 eunit
```

## Expected resolution

- `invalid_utf8_text_rejected_test/0` returns
  `{error,{invalid_utf8,text,0}}` rather than an identity mismatch.
- `ecai_ipfs_ingest:build_records/4` and `/5` are callable.
- deterministic chunk records contain `chunker` metadata.
- the Step 3 record and WAL golden vectors remain unchanged.
