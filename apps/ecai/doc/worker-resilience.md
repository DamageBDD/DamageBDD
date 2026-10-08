# ECAI worker-failure resilience review and patch

Reviewed snapshot: `latest-ecai.tar.gz`, uploaded 8 October 2026.
Input archive SHA-256: `653e27b11f66576f4a28b206923dbebf2769d79e7cb6773492f80d4034ac1030`.

## Validation and scope

This is a source patch against the supplied `apps/ecai` tree, not a deployment to the running DamageBDD node. **Erlang compilation and EUnit execution were not performed:** this environment has no `erl`, `erlc`, or `rebar3`, and attempts to obtain a runtime failed. The enclosing DamageBDD build configuration and dependencies were not included in this archive. Compile and run the tests in an isolated checkout before production deployment.

Checks performed during packaging are recorded in the accompanying verification JSON: whitespace/diff checks, a limited token/delimiter/control-block balance check, clean patch application to a fresh extraction of the input archive, and byte-for-byte comparison of the resulting changed files. These checks are not a substitute for the Erlang compiler, EUnit, or load testing.

## What the reported warning establishes

The supplied health summary reports patch-manager errors and `worker_without_manager`, while also saying that no required processes are missing. It does not include the underlying manager exception, raw status map, or failing module-analysis stack trace. A missing manager is therefore not established by that summary alone.

Two independent defects in the uploaded code can explain the reported inconsistency. The manager performed scans, Git preflight and durable queue reads inside its gen_server request loop, while health status calls used a five-second timeout. Separately, `ecai_health:patch_queue_diagnostics/5` treated a failed manager call as an empty status map, allowing a timeout to become a zero-active-worker diagnosis. A worker observed alive in the next sample then produced `worker_without_manager`.

## Findings and implemented changes

### Responsive manager and contained scheduling failures

`ecai_patch_manager` now runs admission, scanning, recovery, dispatch and queue sampling in one linked, monitored helper at a time. The gen_server remains responsible for timers, worker monitors and cached status. Repeated scan/retry requests coalesce instead of creating concurrent dispatchers. Each periodic task has one reference-tagged timer; manual messages no longer multiply periodic timer chains.

A helper timeout kills that helper and retains its dispatch ownership until its `DOWN` arrives. A late result cannot clear a timeout or start an overlapping dispatcher. Manager termination also terminates its helper. A failed cycle is reported without terminating the manager. A successful subsequent cycle clears current `last_error`, while `last_failure` and `cycle_failures` preserve history. Individual malformed reports are isolated so they do not abort other applications' reports.

`status/0` no longer calls the store, supervisor or Git. Live activity is derived from monitored PIDs; durable counts are sampled and exposed with `snapshot_at`, `snapshot_ready` and `snapshot_error`. Counts are not presented as an atomic global view. Dependency read failures retain the previous snapshot and expose the failure rather than reporting an empty queue.

### Monitored workers, bounded recovery and restart adoption

The manager monitors worker PIDs, adopts live canonical children after restart, and requests recovery on `DOWN`. A worker that completed its durable result is not retried merely because its process exited normally. Both the manager and reconciler now use `ecai_patch_lifecycle:recover/3` for interrupted running jobs.

Recovery preserves the existing fingerprint/version, saved patch, attempt number, diagnostics and other job data, increments the automatic retry counter, and applies the existing exponential backoff. At the configured limit the job becomes terminal `failed`, not an indefinitely retried job. The worker's retry-limit comparison also now terminates at equality. Existing resume logic consumes the preserved state; this is not instruction-level resumption of interrupted computation.

The new `recovery_protocol` marker distinguishes real, bounded crash recovery from the older orphan-preflight migration, preventing that migration from erasing fresh crash backoff. Live worker and dispatcher PIDs prevent a reservation from being mistaken for an orphan. Worker ownership is node-local, consistent with the existing node-local durable store; this is not a distributed lease protocol.

Temporary patch workers remain temporary. The durable queue owns retries and backoff, rather than blindly restarting a failed inference worker through OTP and risking a rapid crash loop. Existing supervisor ordering is unchanged.

### Revision-fenced state transitions

`ecai_learning_store:compare_and_put_repair/4` adds an atomic compare-and-write operation inside the store process. Existing durable sequence numbers fence transitions; records predating those sequence fields are matched against their original map contents. New-job admission uses `not_found` as its expected state. Successful writes return the actual stored revision after the existing DETS persistence path.

The manager's admission, reservation, recovery, retry migration and terminalization writes use this operation. A worker claims its own durable PID before running and verifies its repair identity. Managed worker writes also require the current owner and expected revision. Preflight terminal writes are guarded and persistence failures are not returned as permission to begin inference.

This addresses the startup race in which a fast worker could save `validated` before `start_child` returned, only for the manager to overwrite it with an old `running` record when attaching the PID. Competing recovery passes operating on the same snapshot cannot both charge a retry, and stale recovery cannot overwrite a newer terminal result.

If DETS insertion succeeds but synchronization fails, the in-memory event sequence still advances; the failed synchronization is returned as an error. This avoids reusing a revision for another transition. It does not make failing disks reliable or provide multi-record database transactions.

Direct/manual supervisor proposals now use the same canonical `{ecai_patch_worker, Fingerprint, Version}` child identity as queued jobs. The supervisor rejects duplicate live children, and preflight is not rerun against an already active child.

### Early worker failures and log-learning helpers

`ecai_patch_worker:handle_continue/2` contains exceptions and inspects the durable record before exit. Early context errors, unexpected returns and exceptions that would otherwise leave a job `running` enter the same bounded failure transition, provided that this worker still owns that running record. Already completed or newer records are left alone.

Log-learning inference helpers are now linked as well as monitored, so a hard-killed log-learning owner does not leave its helper running. Existing log-learning retry/checkpoint semantics remain in place.

### Accurate health diagnostics

Health distinguishes an unavailable manager status from a genuine observed worker count. It exposes `manager_status_unavailable`, `manager_snapshot_unavailable`, `manager_initializing` and `scheduling` where appropriate. A responding manager reporting zero followed by a separate live-worker sample is transitional evidence, not proof that the manager process is missing. The guarded health-monitor input includes the new cycle and snapshot diagnostics.

Historical log-learning `last_terminal_error` is retained. This patch does not fabricate successful module analysis or clear evidence of unresolved source/backend failures. Backend outages, malformed analyses and verifier failures can still legitimately leave the service degraded.

## Configuration

One application environment setting is added, with this default:

```erlang
{code_patch_cycle_timeout_ms, 300000}
```

Place overrides inside the existing `ecai` application configuration. This timeout covers the manager's scheduling/scan/snapshot helper, not an entire repair's inference and verification lifetime. Existing backend and verifier timeouts remain relevant.

Existing retry defaults remain in `ecai_patch_retry`: `code_patch_retry_max_attempts = 12`, `code_patch_retry_base_ms = 30000`, and `code_patch_retry_max_ms = 900000`. Existing configured overrides remain effective. The retry limit is interpreted according to the existing counter convention: reaching the limit terminalizes the repair.

Do not copy the test fixture's `require_global_learning => false` or `preflight_source_snapshot => false` into production configuration. Those options isolate tests from external analysis and Git; the patch does not disable those production safeguards.

## Regression coverage supplied, not executed

`ecai_patch_resilience_tests.erl` adds 27 cases covering competing recovery, preserved work/backoff, retry exhaustion, live reservations, durable-store restart, manager responsiveness, coalesced scans, worker kills and exceptions, fast completion, manager restart adoption, linked-helper cleanup, timeout/late-result races, dependency failures, direct-proposal identity, malformed reports, reconciler recovery and preflight persistence failure.

Five additional health tests cover unavailable status, transitional sampling, scheduling, unavailable snapshots and historical log-learning errors. The five existing retry-exhaustion tests are updated for conditional persistence. The fixtures use real manager/supervisor/worker/store processes where applicable and mocks at analysis/report boundaries. They do not test real inference, Git side-effect idempotency, native code crashes or production performance.

Run them only in an isolated EUnit VM: the fixtures deliberately use registered ECAI process names and stop their fixture services during cleanup. Do not load/run these tests in the live `damage@threadripper0` shell.

## Apply, test and deploy

From the DamageBDD repository root, on a review branch based on the supplied snapshot:

```sh
git apply --check ~/Downloads/ecai-worker-resilience.patch
git apply ~/Downloads/ecai-worker-resilience.patch
rebar3 compile
rebar3 eunit --module=ecai_patch_resilience_tests,ecai_patch_manager_retry_exhaustion_tests,ecai_patch_reconciler_tests,ecai_patch_worker_recovery_tests,ecai_patch_worker_source_block_tests,ecai_patch_manager_preflight_tests,ecai_patch_manager_orphan_preflight_tests,ecai_patch_manager_source_identity_tests,ecai_repair_preflight_tests,ecai_patch_retry_tests,ecai_learning_store_tests,ecai_log_learning_tests,ecai_health_tests,ecai_health_monitor_tests
```

Use the repository's normal build wrapper instead where required for its OTP version, NIF build and dependencies. Also run the broader integration suite. Stop on a failed apply check; do not force a patch onto a newer, divergent tree. The updated archive is an alternative source snapshot, not an additional patch to apply.

After successful tests, make a consistent backup of the durable ECAI state with the service stopped, retain the prior release, rebuild the release, and perform a controlled service/security-stack restart through the existing deployment procedure. **Do not hot-load only `ecai_patch_manager` into a live old state:** its record layout changed and this patch does not implement a live old-record migration. Keep the DETS job store; do not delete it or reset all retry counts.

The full source archive retains unchanged pre-existing native/binary assets from the upload. They were not rebuilt here. Build the native components with the normal repository build; do not treat the archive as a newly built release.

After restart, inspect:

```erlang
ecai_patch_manager:status().
ecai_health:patch_queue().
ecai_patch_reconciler:status().
```

Normal timers will reconcile and dispatch. To request those operations explicitly:

```erlang
ecai_patch_reconciler:run_now().
ecai_patch_manager:scan_now().
```

A scan request is asynchronous and is not proof of completion. Inspect the timestamped status afterward. A failed worker should eventually leave `running` for `retry_wait` with preserved identity and a future retry time, or terminal `failed` when exhausted. Healthy existing workers should remain owned; already validated repairs should not revert to running.

For rollback, restore the prior built release and restart normally. Preserve durable job history; do not replace a live store with an older backup without explicitly accepting loss of intervening transitions. Older code will not understand all new recovery behavior even though repair maps remain maps, so verify queued/running state during any rollback.

## Boundaries

The patch is designed to contain process failures, not to make the system infallible. An unavailable or corrupt durable store must remain an explicit error. A VM/NIF crash still requires node supervision and recovery. An interrupted external inference or Git operation may have completed remotely and be repeated; revision fencing is not exactly-once execution of external side effects. Unadmitted casts are not a durable ingress queue. Full production performance and crash behavior remain to be verified on the target runtime.

Suggested commit subject:

```text
fix(ecai): contain failed workers and fence durable repair recovery
```
