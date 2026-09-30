# ECAI canonical source repository

ECAI code intelligence uses committed Git state as its authoritative source
substrate. The developer checkout is a source of commits, not a source of
mutable bytes.

## Layout

The repository service materializes immutable generations under the Damage
state tree:

```text
/var/lib/damage/git/security/
├── repository.git
└── bases/
    ├── <commit-a>/
    └── <commit-b>/
```

`repository.git` is a local mirror of `code_repo_root`. Each directory under
`bases/` is a detached Git worktree pinned to exactly one commit. Existing
generations are not reset when a newer commit appears, so running verification
jobs remain reproducible.

## Generation boundary

A full `ecai_codebase_learner` cycle calls
`ecai_source_repository:refresh/0`. That advances the canonical generation to
the current committed `HEAD` of `code_repo_root`.

Vulnerability scans and targeted module refreshes consume the already-pinned
generation. A vulnerability-scan cycle stores its `canonical_commit` in the
durable checkpoint and resumes against that same commit after restart. It does
not independently advance to dirty or newer developer bytes mid-cycle.

The intended identity chain is:

```text
canonical commit
  = learned analysis base_commit
  = vulnerability source bytes
  = repair snapshot base_commit
  = verifier base commit
  = integration patchset base commit
```

## Development mode

The default mode is committed source:

```erlang
{code_source_mode, committed},
{code_dev_overlay, inspect_only},
{code_source_allow_runtime_fallback, false}.
```

`inspect_only` allows operators to inspect a dirty developer module with:

```erlang
ecai_source_repository:inspect_module(ecai, ecai_patch_worker).
```

That result is marked `authoritative => false` and is never used by canonical
learning, vulnerability persistence, repair generation, or integration.

To completely hide dirty developer source from ECAI inspection:

```erlang
{code_dev_overlay, ignore_dirty}.
```

Runtime/BEAM source fallback is disabled by default. It can be enabled for
legacy deployments:

```erlang
{code_source_allow_runtime_fallback, true}.
```

Such fallback should not be used when deterministic repair provenance is
required.

## Operator API

```erlang
%% Advance the canonical generation to the latest committed developer HEAD.
ecai_source_repository:refresh().

%% Inspect canonical repository identity and developer dirty state.
ecai_source_repository:status().

%% Current immutable canonical generation.
ecai_source_repository:current().

%% Read one authoritative committed module.
ecai_source_repository:module_source(ecai, ecai_health).

%% Observe the mutable developer copy without making it authoritative.
ecai_source_repository:inspect_module(ecai, ecai_health).
```

After committing development changes, force a new generation with:

```erlang
ecai_codebase_learning:refresh().
```

Once learning completes, vulnerability scans and repairs operate against that
same committed generation.
