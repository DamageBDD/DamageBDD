# ECAI EUnit failure repair

This repair addresses the three actual failures in the supplied EUnit run.

## Changes

### Search contexts

`ecai_search:new/0` now creates private unnamed ETS tables. Multiple contexts can
coexist in one VM, which is required by deterministic rebuild tests and avoids
`already_exists` failures.

Root publication is synchronous, so `add_record/3` does not return before the
matching Merkle root is visible. Local document-ID allocation now uses
`ets:update_counter/3`.

### Search test contract

`ecai_search:search/3` returns enriched maps. The test now reads each result's
`doc_id` field instead of matching the obsolete `{DocId, Score}` tuple shape.
The test always destroys both contexts in an `after` block.

### Maxwell synth demo

The 12-second WAV renderer is a manual demo, not a unit test. It is now named
`maxwell_demo/0`. A production-only `maxwell_test/0` compatibility alias is
retained, but Rebar3 EUnit builds omit it because the `TEST` macro is defined.

The Maxwell path no longer references the absent modules `ecai_curve`,
`ecai_pitch`, `ecai_amp`, `ecai_pan`, or `ecai_osc`. Prompt-derived curve point
coordinates are projected into deterministic local oscillator parameters.

### Duplicate EUnit execution

Add this to the top-level `rebar.config`:

```erlang
{eunit_opts, [exact_execution]}.
```

When `eunit_opts` already exists, merge `exact_execution` into the existing
list. This prevents a module such as `ecai_search_tests` from being executed
once as an application module and again as the related test module for
`ecai_search`.

The `simulated_crash_after_sync` reports in the supplied output are intentional
fault-injection evidence from the WAL recovery test. They are not failed test
cases. With exact execution enabled, that test and its expected crash report run
once rather than twice.

## Apply

From the DamageBDD repository root:

```sh
git apply --check /path/to/ecai_eunit_failures_fix.patch
git apply /path/to/ecai_eunit_failures_fix.patch
```

Merge `rebar.config.fragment` into the top-level `rebar.config`.

Remove stale beams and compile:

```sh
rm -f \
  _build/test/lib/ecai/ebin/ecai_search.beam \
  _build/test/lib/ecai/ebin/ecai_search_tests.beam \
  _build/test/lib/ecai/ebin/ecai_synth.beam \
  _build/test/lib/ecai/ebin/ecai_synth_tests.beam

rebar3 as test compile
```

Run focused tests:

```sh
rebar3 eunit --module=ecai_search_tests
rebar3 eunit --module=ecai_synth_tests
rebar3 eunit --application=ecai
```

Run the project gate:

```sh
rebar3 eunit
rebar3 xref
```

Confirm the missing synth references are gone:

```sh
rg -n 'ecai_(curve|pitch|amp|pan|osc):' apps/ecai/src/ecai_synth.erl
```

The command should print no matches.

## Commit

```sh
git add -- \
  apps/ecai/src/ecai_search.erl \
  apps/ecai/src/ecai_search.hrl \
  apps/ecai/src/ecai_synth.erl \
  apps/ecai/test/ecai_search_tests.erl \
  apps/ecai/test/ecai_synth_tests.erl \
  rebar.config

git commit \
  -m "fix(ecai): isolate search contexts and clean EUnit discovery" \
  -m "Use private ETS tables, align search tests with enriched results, publish roots synchronously, and keep the Maxwell renderer out of automatic EUnit discovery while removing unresolved synth module references."
```

## Validation status

The generated patch was applied to a clean copy of the uploaded source files and
its output was compared byte-for-byte with the packaged replacements. Static
checks also passed for delimiter balance, preprocessor balance, deprecated
`catch` expressions in the changed code, and the removed Maxwell module
references.

Erlang/OTP and Rebar3 were not available in the artifact environment, so the
commands above remain the required compiler and runtime acceptance gate in
DamageBDD.
