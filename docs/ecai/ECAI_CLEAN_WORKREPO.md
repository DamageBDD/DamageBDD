# ECAI clean workrepo integration

`ecai_patch_integration` validates the accumulated set of individually validated
repair patches against a clean detached Git worktree. The main DamageBDD checkout
is never modified by this process.

## Flow

1. Read `validated` repair records from `ecai_learning_store`.
2. Resolve the integration base to a concrete Git commit (default `HEAD`).
3. Sort repairs deterministically by `{created_at, fingerprint, finding_version}`.
4. Compute `patchset_sha256` from the ordered repair identities and patch hashes.
5. Persist the integration job before execution.
6. Create a detached worktree below the Damage state tree.
7. For each patch in order:
   - validate patch paths;
   - run `git apply --check`;
   - if that fails, run `git apply --reverse --check` and skip the patch when it
     is already present in the selected base;
   - otherwise apply the patch.
8. Run `git diff --check`.
9. Run `rebar3 compile`.
10. Run EUnit by default and Common Test when configured.
11. Persist the full integration result.
12. On failure, normalize the first failing stage into an integration finding
    containing the exact base commit, patchset SHA, diagnostics, patch excerpts,
    and captured failing source.
13. Submit that finding through `ecai_patch_sup`.
14. The corrective patch is verified with the original patchset pre-applied to
    the same base commit.
15. Once that corrective repair becomes `validated`, it becomes part of the next
    ordered integration patchset and the cycle runs again.

## State layout

```text
/var/lib/damage
├── dets
│   └── code_integration_jobs.dets
├── git
│   └── security
│       ├── patches
│       ├── worktrees
│       └── integration
│           └── worktrees
└── logs
    └── integration
        └── <job-id>.json
```

The normal XDG fallback remains available when `/var/lib/damage` is not usable.

## Configuration

```erlang
{code_integration_interval_ms, 60000},
{code_integration_base_commit, "HEAD"},
{code_integration_run_eunit, true},
{code_integration_run_ct, false},
{code_integration_command_timeout_ms, 600000}
```

`code_integration_base_commit` may be a branch, tag, or commit-ish, but each job
stores the resolved immutable commit SHA.

## Operator API

```erlang
%% Queue an integration pass immediately.
ecai_code_repair:integrate().

%% Force the current base+patchset to be re-run even if a prior result exists.
ecai_code_repair:integrate(#{force => true}).

%% Inspect the live integration worker.
ecai_code_repair:integration_status().

%% Inspect durable jobs.
ecai_code_repair:integration_jobs().
ecai_code_repair:integration_job(JobId).

%% Integration state is also included in the normal codebase status.
ecai_codebase_learning:status().
```

## Failure feedback

A compile/test/apply failure is converted to a normal repair finding with an
`integration_context` field. That field carries the exact reproduction state:

```erlang
#{
    <<"job_id">> => JobId,
    <<"base_commit">> => CommitSha,
    <<"patchset_sha256">> => PatchsetSha,
    <<"failed_phase">> => <<"compile">>,
    <<"diagnostic">> => CompilerOutput,
    <<"target_source_path">> => <<"apps/ecai/src/example.erl">>,
    <<"target_source">> => PatchedSource,
    <<"patches">> => [...]
}
```

`ecai_code_context` prefers this captured patched source over stale source from
the learning store when constructing the corrective-patch prompt.

The corrective patch worker receives verifier options equivalent to:

```erlang
#{
    base_commit => CommitSha,
    preapply_patch_files => OriginalPatchset
}
```

Therefore a corrective patch cannot be declared valid merely because it compiles
against bare `HEAD`; the exact failing patchset is reconstructed first.

## Restart behavior

The integration DETS store is authoritative. A job left in `running` state is
returned to `queued` at process start. Feedback dispatch is also resumable.
Execution is at-least-once; job IDs and patch-worker fingerprint/version identity
make commits idempotent.
