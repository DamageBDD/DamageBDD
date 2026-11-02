# ECAI release memory and operator manuals

`ecai_release_memory` extends codebase learning with deterministic, durable release evidence. Every successful full learning cycle compares the previously learned Git head with the current committed head, persists new first-parent commit evidence in the existing learning DETS store, and refreshes an operator-facing release manual.

The release path does **not** ask an LLM whether a change is breaking. Git objects, Erlang export lists, parseable Erlang configuration terms, dependency/native paths and persisted deployment baselines are the source evidence. Narrative notes are projections of that evidence plus commit subjects.

## What is recorded

Per-commit records are keyed by commit SHA and contain:

- changed/added/deleted/renamed files;
- semantic changes in `sys.config`, `sys.config.sample`, `*.config`, `*.config.sample` and application `env` defaults in `*.app.src` when they parse as Erlang terms; non-Erlang config paths such as YAML/TOML/INI/env files are still surfaced as required operator-review actions;
- added/removed exported Erlang `Function/Arity` pairs for changed `apps/*/src/*.erl` modules;
- deterministic breaking-change findings for removed exports, removed config keys and removed source modules;
- operator actions for configuration, dependency, native/NIF, migration/schema, contract and packaging changes;
- commit subject/date and evidence SHA-256;
- redaction of config values whose key path contains secret/password/token/API-key/private-key/credential/mnemonic/seed indicators.

The learning snapshot contains a bounded release-memory summary (count, latest evidence identity and deployment baselines), not the full accumulated history.

## Automatic lifecycle

`ecai_codebase_learner` refreshes release memory after application/global knowledge and relation refresh succeed. Release-memory failure leaves the learning cycle `ready => false`, so release candidate workflows that require quiescent/ready learning cannot silently proceed with a missing manual.

On the first cycle, the current commit is learned relative to its first parent. On later cycles only new first-parent commits are added. If history was rewritten, ECAI finds the merge base and rebuilds the affected forward projection; SHA-keyed historical evidence remains inspectable.

The current manual is written to the Damage state tree:

```text
logs/release_manual.md
logs/release_manual.json
```

The default comparison base is:

1. the configured deployment baseline for `code_release_memory_default_environment` (default `production`);
2. otherwise the newest reachable stable SemVer tag (`vX.Y.Z` or `X.Y.Z`) before the current `HEAD`;
3. otherwise the previous commit;
4. for an initial repository commit, the initial tree state.

## Operator API

```erlang
%% Release-memory health/cursor/baselines.
ecai_codebase_learning:release_memory_status().

%% Default operator manual (production baseline -> HEAD when marked).
ecai_codebase_learning:release_manual().

%% A named deployed environment -> current HEAD.
ecai_codebase_learning:release_manual(production).

%% Arbitrary committed refs.
ecai_codebase_learning:release_manual(<<"v1.2.3">>, <<"HEAD">>).
ecai_codebase_learning:release_diff(<<"v1.2.3">>, <<"HEAD">>).

%% Focused views.
ecai_codebase_learning:breaking_changes().
ecai_codebase_learning:config_changes().
ecai_codebase_learning:release_changes().

%% Record what an environment actually runs. The ref is resolved to a commit.
ecai_codebase_learning:mark_deployed(production, <<"v1.2.3">>).
%% or pin the exact deployed commit
ecai_codebase_learning:mark_deployed(production, <<"53ff84e149388465363ed45bfc66b49f364fbae1">>).

%% Refresh files manually.
ecai_codebase_learning:write_release_manual().
ecai_codebase_learning:write_release_manual(production).
```

Deployment baselines are stored as resolved commit identities. Moving a tag later does not silently move a previously marked deployment baseline.

## Configuration

Defaults in `ecai.app.src`:

```erlang
{code_release_memory_enabled, true},
{code_release_memory_max_commits, 5000},
{code_release_memory_default_environment, production}
```

`code_release_memory_max_commits` is a safety fence for a single accumulation/manual range. It prevents an accidental ref or rewritten history from causing an unbounded repository walk.

## Breaking-change boundary

A reported `breaking` finding means ECAI observed a deterministic interface removal, currently an exported Erlang API removal. `potential_breaking` is used where operator context is required, such as a removed configuration key or removed module. This avoids claiming that every config/default change necessarily breaks a deployment.

Export comparison currently covers literal `-export([...]).` attributes in changed Erlang source. Macro-generated export declarations, parse-transform-created APIs and dynamically constructed interfaces are not expanded from historical Git blobs; those files still appear in the changed-component evidence and require review.

The direct manual projection compares the selected base with the final head. This matters when an interface was temporarily removed and restored in intermediate commits: commit evidence retains that history, but the final release manual does not falsely report a breaking removal that is absent from the shipped end state.

## Validation

Focused EUnit coverage is in `test/ecai_release_memory_tests.erl` and checks:

- semantic config changes and secret redaction;
- exported API add/remove classification;
- breaking-change/operator-action derivation;
- collapse of intermediate breakage that is restored by the final head;
- dependency/native rebuild actions;
- bounded release-memory summary in `ecai_learning_store` snapshots.

A full repository build should run the normal DamageBDD validation after applying the patch:

```sh
rebar3 compile
rebar3 eunit
```
