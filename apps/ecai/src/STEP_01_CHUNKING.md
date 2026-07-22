# ECAI production step 01: deterministic UTF-8 chunking

This is the first deliberately small production change.

Its purpose is to make chunk generation deterministic before replay protection,
WAL durability, manifest commits, replication, or global IPFS indexing are added.

## Contract

`ecai_chunker:fold_utf8/5` provides these guarantees:

1. `Size` and `Overlap` are measured in Unicode code points.
2. Every emitted chunk starts and ends on a valid UTF-8 boundary.
3. Consecutive full chunks overlap by exactly `Overlap` code points.
4. No source content is skipped.
5. Malformed UTF-8 is rejected before the callback is invoked.
6. Each chunk carries a stable ordinal plus inclusive/exclusive byte offsets.
7. The fold API lets ingestion process chunks incrementally instead of first building a complete chunk list.

The current production identifier for this behavior is:

```text
ecai-utf8-window/v1
```

Changing any canonical chunking behavior requires a new identifier and new test
vectors. Existing indexed data must retain the identifier that produced it.

## DamageBDD file locations

DamageBDD is a Rebar3 umbrella project. Install the Step 1 files in the ECAI
application at these paths:

```text
apps/ecai/src/ecai_chunker.erl
apps/ecai/test/ecai_chunker_tests.erl
apps/ecai/src/ecai_ipfs_ingest.erl
apps/ecai/src/ecai_disk_indexer.erl
```

The files have these responsibilities:

- `ecai_chunker.erl`: pure deterministic UTF-8 chunking module.
- `ecai_chunker_tests.erl`: focused EUnit examples and reconstruction coverage.
- `ecai_ipfs_ingest.erl`: streams chunk records through the new module.
- `ecai_disk_indexer.erl`: preserves chunk ordinal, byte range, and chunker version in document metadata.

## 1. Enter the DamageBDD project root

Run all Rebar3 commands from the repository root: the directory containing the
top-level `rebar.config` and `apps/` directory.

```sh
cd /path/to/DamageBDD

test -f rebar.config
test -d apps/ecai/src
mkdir -p apps/ecai/test
```

The repository and ECAI source-directory checks must exit successfully before continuing.

## 2. Copy the Step 1 files into the ECAI application

Replace `/path/to/ecai_step_01` with the directory containing the Step 1 files:

```sh
cp /path/to/ecai_step_01/ecai_chunker.erl \
  apps/ecai/src/ecai_chunker.erl

cp /path/to/ecai_step_01/ecai_chunker_tests.erl \
  apps/ecai/test/ecai_chunker_tests.erl

cp /path/to/ecai_step_01/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl

cp /path/to/ecai_step_01/ecai_disk_indexer.erl \
  apps/ecai/src/ecai_disk_indexer.erl
```

When the files are already present in those locations, skip the copy and inspect
the pending changes instead:

```sh
git diff -- \
  apps/ecai/src/ecai_chunker.erl \
  apps/ecai/test/ecai_chunker_tests.erl \
  apps/ecai/src/ecai_ipfs_ingest.erl \
  apps/ecai/src/ecai_disk_indexer.erl
```

## 3. Run the focused Step 1 EUnit test

Use Rebar3 to compile the DamageBDD test profile and run only the ECAI chunker
test module:

```sh
rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests
```

No separate `erlc` command is required. Rebar3 compiles application test files
under `apps/ecai/test` as part of the EUnit run.

The command must exit with status `0`. The final output should report that all
chunker tests passed and show no failed tests.

Check the shell status immediately after the command when needed:

```sh
echo $?
```

Expected value:

```text
0
```

## 4. Run all EUnit tests for the ECAI application

After the focused test passes, run the complete EUnit set for `ecai`:

```sh
rebar3 eunit --application=ecai
```

This catches integration problems between the new chunker and other ECAI
modules without running every application in the DamageBDD umbrella.

## 5. Run the full DamageBDD EUnit suite

Before merging or deploying the change, run the project-wide suite from the
same repository root:

```sh
rebar3 eunit
```

A failure while compiling another DamageBDD application or native component is
not a successful Step 1 result. The project must compile in the operator's
supported build environment before this change is accepted.

## 6. Capture test evidence

For a reviewable local or CI artifact, run the focused test with Bash pipe
failure propagation enabled:

```sh
mkdir -p artifacts/test
set -o pipefail

rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests \
  2>&1 | tee artifacts/test/step01-ecai-chunker-eunit.log
```

The command must still return status `0`; the log file alone is not evidence of
success if Rebar3 failed.

## Optional clean rebuild

Use this only when stale `_build` output is suspected:

```sh
rebar3 clean
rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests
```

A clean rebuild can be substantially slower because DamageBDD is an umbrella
project with multiple applications and dependencies.

## Troubleshooting

### `rebar3: command not found`

Install Rebar3 in the build environment or use the project's local executable,
when one is provided:

```sh
./rebar3 eunit \
  --application=ecai \
  --module=ecai_chunker_tests
```

### `Module ecai_chunker_tests not found`

Verify all three conditions:

```sh
test -f apps/ecai/test/ecai_chunker_tests.erl
grep -n '^-module(ecai_chunker_tests).' \
  apps/ecai/test/ecai_chunker_tests.erl
test -f apps/ecai/src/ecai_chunker.erl
```

Then run the optional clean rebuild.

### EUnit include errors

The test module uses:

```erlang
-include_lib("eunit/include/eunit.hrl").
```

Ensure the installed Erlang/OTP distribution includes the EUnit application
and development headers.

### Failure before any chunker test runs

Rebar3 compiles the required project applications before executing EUnit. A
missing compiler, native library, dependency, generated file, or project hook
can therefore stop the command before `ecai_chunker_tests` begins. Resolve the
reported DamageBDD build prerequisite, then rerun the exact focused command.

## Acceptance gate

Do not proceed to the stable event identity or WAL/manifest step until all of
the following are true:

- `rebar3 eunit --application=ecai --module=ecai_chunker_tests` passes;
- `rebar3 eunit --application=ecai` passes in the supported DamageBDD environment;
- a representative IPFS corpus produces no unexpected UTF-8 errors;
- re-running the same corpus produces byte-identical chunk text, ordinals, byte ranges, and chunker version;
- any intended non-UTF-8 sources have an explicit decoding or transcoding policy before this chunker;
- the focused test output has been retained as review or CI evidence.

## Deliberately not solved by this step

This change does not make a document ingest transaction atomic. A failure after
some callback invocations can still leave partial metadata because the current
docstore and indexer write path lacks a WAL-backed batch commit.

The next minimum atomic production step is to introduce a stable document event
envelope containing at least:

```text
source_key
source_version
event_id
chunk identity
```

That identity must be deterministic before WAL-backed replay and deduplication
are introduced.
