# ECAI durable learning and repair jobs

The code-security subsystem uses durable checkpoints so source learning, vulnerability scans, and repair jobs survive BEAM/application/host restarts without losing completed work.

## Persistence model

### Code learning

`/var/lib/damage/dets/codebase_learning.dets` (or the configured XDG fallback) stores:

- deterministic source analyses and source hashes;
- module/application/global knowledge cards;
- the current `codebase_learner` checkpoint;
- the current `patch_manager` checkpoint;
- current repair state and a compact repair transition journal.

The learner checkpoint contains the cycle, completed count, pending queue, in-flight entries, changed applications, finalization state, next scheduled run, and readiness state.

An in-flight learning entry is never considered completed after a restart. It is returned to the queue. If its analysis/card was already committed before the crash, the existing source/model identity checks make the replay a no-op.

### Vulnerability scans

Each existing application vulnerability DETS file stores a `scan_checkpoint` alongside module reports:

```text
/var/lib/damage/dets/damage_vulnerabilities.dets
/var/lib/damage/dets/ecai_vulnerabilities.dets
/var/lib/damage/dets/erm_vulnerabilities.dets
```

The checkpoint records the module list, remaining queue, current module, cycle timestamps, errors, and next run. If the VM stops while a module is being audited, that module is placed back at the head of the queue on startup.

### Repair jobs

Repair records are state machines keyed by `{fingerprint, finding_version}`:

```text
queued
  -> running/generating
  -> running/generated
  -> running/verifying
  -> validated | proposed | failed
```

Every transition is synchronously committed to DETS. Generated patch bytes and the patch file path are persisted before verification starts. A restart during verification therefore resumes by re-verifying the already-generated patch rather than discarding it.

Patch workers use stable supervisor child IDs based on fingerprint and finding version. They are transient children: an abnormal worker failure is restarted by the supervisor, while a whole-node restart is recovered from DETS by `ecai_patch_manager`.

### Inference workers

Ollama/OpenAI leases are deliberately not durable. They are transport/compute leases, not job ownership. On restart, a durable learning/audit/patch job reacquires any healthy role-compatible backend from `ecai_ollama_pool`.

Provider credentials are not written into checkpoints, snapshots, repair records, or transition events.

## Git verifier recovery

Patch verification uses detached worktrees below:

```text
/var/lib/damage/git/security/worktrees
```

At patch-manager startup, stale `repair-*` Git worktrees are removed through `git worktree remove --force`, then `git worktree prune` is run. New worktree names include wall-clock microseconds plus a unique integer so stale unregistered directories cannot collide with a resumed job.

## Operator inspection

Live and durable state can be compared independently:

```erlang
ecai_codebase_learning:status().
ecai_codebase_learning:durability().
```

A repair transition history can be inspected with:

```erlang
ecai_codebase_learning:events(repair, {Fingerprint, FindingVersion}, 50).
```

An explicit learning snapshot includes lightweight runtime checkpoint summaries:

```erlang
ecai_codebase_learning:snapshot().
```

The full learner queue is kept in DETS but intentionally omitted from the JSON snapshot and `durability/0` response.

## Recovery semantics

The subsystem provides at-least-once execution with idempotent commits:

- completed source/card work is identified by source/model identity and reused;
- a possibly interrupted inference is replayed;
- the current vulnerability module is replayed;
- a generated repair is reused and verification is replayed;
- terminal repair states are never automatically restarted for the same finding version.

This favors not losing work over assuming an interrupted operation succeeded.

## Restart test

A useful operational test is:

1. Start a first learning pass and confirm `phase => learning`.
2. Stop/restart the `ecai` application or BEAM while entries are in flight.
3. Confirm `resume_count` increments and the previous pending work continues.
4. Kill the VM while a patch record has `stage => generated` or `stage => verifying`.
5. Restart and confirm the same `{fingerprint, finding_version}` proceeds to verification/terminal state without generating a new logical job.
6. Restart during an application vulnerability scan and confirm the previous `current_module` is audited again, followed by the remaining queue.

The authoritative durable state is DETS; JSON snapshots are inspectable projections of that state.
