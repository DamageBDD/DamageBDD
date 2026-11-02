# Schedule mutation timeouts and recovery

## What the reported log establishes

The HTTP request exited at 10:22:44 UTC on 21 October 2026 while waiting for
`gen_server:call(damage_schedule_v2, {create, Owner, Spec}, 120000)`.
A transaction observer logged a 180,000 ms timeout at 10:23:49 with
`Tx not mined`. The excerpt does not identify which schedule funding stage
submitted that transaction; correlate its decoded call with the draft and logs.

The archived implementation performed preview, contract creation, allowance and
funding synchronously in the scheduler callback. The caller could disappear
while server work and an already submitted transaction continued. Simply
raising the HTTP timeout neither removes scheduler blocking nor establishes
whether an uncertain write happened.

The AccountRegistry warning concerns a different account. The optional AE cost
conversion warning and relay connection failures are separate symptoms. This
patch does not replace missing keys, invent an AE exchange rate, alter node
fees/nonces, or make an unmined transaction confirm.

## Apply

This is incremental to `damagebdd-schedule-starters.patch` on the uploaded
`latest-damage.tar.gz`. It does not require the earlier L402 patch and does not
replace it. Apply from the full monorepo root:

```sh
PATCH="$HOME/Downloads/damagebdd-schedule-operation-recovery.patch"
git apply --check "$PATCH"
git apply "$PATCH"
rebar3 compile
rebar3 eunit --module=damage_schedule_v2_operation_tests
rebar3 eunit --module=damage_schedule_v2_async_tests
rebar3 eunit --module=damage_schedule_v2_async_http_tests
node --test apps/damage/test/scripts/schedule_operations.test.mjs \
  apps/damage/test/scripts/schedule_templates.test.mjs
```

The Erlang tests require the project's existing EUnit/meck/JSX dependencies.
They use temporary DETS storage and mocked chain calls. Run them in an isolated
test VM, not a live funded node.

Before deploying, quiesce new mutations, inspect any current outstanding write,
and take a consistent backup of the configured schedule data directory using
normal node backup procedures. Do not force-kill a funding call merely because
its browser request timed out. If interruption is unavoidable, preserve the
transaction hash and draft and treat its chain outcome as unknown.

After compilation, use the normal application restart/deployment process so
new HTTP routes and modules load together, and reload dashboard assets. Do not
replace a live DETS file with fixture data. Restart recovery surfaces old orphan
drafts but deliberately does not resubmit them.

## Operation protocol

Creation, signed-transaction submission, and pause/resume/cancel now return an
operation envelope promptly after durable admission; they do not wait for chain
confirmation inside their scheduler callback. Running envelopes use HTTP 202:

```json
{
  "operation_id": "sop_example",
  "kind": "create",
  "status": "running",
  "stage": "queued",
  "created_at": 1792578000,
  "updated_at": 1792578000
}
```

The authenticated owner can read:

```text
GET /api/schedules/v2/operations
GET /api/schedules/v2/operations/:operation_id
```

The first returns `{ "status": "ok", "data": [...] }`; the second returns the
operation envelope. Individual lookups return 404 for another owner's ID.
Responses are `no-store`.

`complete` contains `result`, the previous API's successful result or wallet
signing request. A 202 response is NOT proof of creation, funding or activation.
`failed` indicates failure before a possible write. `reconciliation_required`
means a write may have happened or a multi-stage operation stopped after a
possible write. `superseded` points to a subsequent signed-transaction operation;
clients follow `superseded_by` rather than sign obsolete prepared bytes.

Other API clients must handle this new asynchronous contract. The patched
production dashboard handles both operation envelopes and legacy immediate
successful responses.

### Idempotency and admission

Creation and submitted-transaction operation IDs are scoped to owner and kind.
Without a `request_id`, the normalized payload digest is the request key. Exact
retries return the existing operation and never start another schedule worker.
An optional nonempty binary/JSON string `request_id` of at most 128 bytes allows
an explicit intent identity. Keep it stable during retries. Reusing it with a
different payload returns 409 `idempotency_conflict`.

This is NOT a claim of distributed exactly-once settlement. It protects this
node's schedule admission boundary; existing chain and wallet implementation
semantics are unchanged. Changing signed bytes, payload or request ID represents
a different intent. A remaining owner draft or unresolved operation prevents a
replacement creation. Pause/resume/cancel invocations receive new intent IDs,
so repeated deliberate actions such as pause/resume/pause remain possible.

At most eight mutation workers run globally; active scheduled executions and
mutations are serialized for an owner. A running or reconciliation-required
operation conservatively blocks ALL scheduled execution and mutations for that
owner, not just the failed schedule. Other owners can proceed subject to the
worker limit and existing synchronous APIs. Read APIs remain available during
these mutation workers; existing preview, setup and migration callbacks were
not generally converted into asynchronous APIs by this patch.

### Persistence and timers

The operation record is synced to the existing `schedule_v2.dets` before a
worker starts. Stage checkpoints are synced before create/allowance/funding
calls. No new database or supervisor child is introduced. Worker monitors and
links associate work with the scheduler lifetime. Restarted or interrupted work
is never automatically replayed.

Operation metadata excludes raw feature text, signed transaction bytes, keys,
backend error bodies and exception stacks. Authenticated successful wallet
results can include prepared unsigned transactions, as before. Existing draft
and schedule records still contain their feature; this patch is not a rewrite
of feature/report privacy or storage.

Workers defer arm/cancel effects to the scheduler instead of returning a stale
copy of its state. Timer tokens ignore obsolete delivered messages. An owner's
due timer does not rewrite a schedule while a mutation owns it. Active schedule
records are synced before their recovery drafts are removed.

The journal retains historical operation records. This patch does not add
automatic pruning; preserve idempotency records during maintenance.

### Deadlines

The default whole-operation worker deadline is 15 minutes. Configure it as a
tuple inside the existing `damage` application settings if needed:

```erlang
{schedule_v2_operation_timeout_ms, 900000}
```

Valid values are integers from 1,000 to 3,600,000 ms; invalid values use the
default. Admission calls wait up to 10 seconds. An admission timeout returns an
unknown-outcome error rather than crashing Cowboy; it does not prove the request
was never admitted. The browser observes for up to ten minutes and can stop
observation earlier when its form closes or a GET fails. Refresh or Check /
continue observes the same durable operation later.

Killing a worker on deadline does NOT cancel a wallet request already running in
another process or a transaction already submitted to a node. After a possible
write, the operation remains `reconciliation_required`, including after restart.
There is no automatic refund, rebroadcast, or fresh allowance/funding attempt.

## Inspect the already reported transaction

These commands are read-only. Use the submitting node when known, or an
appropriate trusted observer. The example uses the public hostname seen in the
log; the log alone does not prove it was the submitting endpoint.

```sh
AE_NODE='https://mainnet.aeternity.io'
TX='th_N2BiyrJ5aKHpBY6vQt9MYY22iRv4FCNBqG8WUXoCWiFbL3xe3'
curl --fail-with-body --max-time 20 -sS "$AE_NODE/v3/transactions/$TX"
curl --fail-with-body --max-time 20 -sS "$AE_NODE/v3/transactions/$TX/info"
```

Correlate caller, contract, nonce, transaction call data and receipt with the
schedule draft before deciding whether creation, allowance or funding needs
repair. A missing receipt on one observer is not proof that the transaction
cannot later be included. The log does not establish a fee/nonce diagnosis, so
do not change those settings or resubmit on that basis alone.

After this patch is deployed, inspect only your own operator-authorized account
using the dashboard or the node shell:

```erlang
Owner = <<"ak_ag9FGrk8okPzGJZzWL7UuK21NYckM6Tsbtaapmv3iFM4Hn8dW">>,
damage_schedule_v2:operations(Owner).
damage_schedule_v2:list(Owner).
```

Before the new API is loaded, the existing draft table can be inspected read-only
without printing features or private context:

```erlang
Owner = <<"ak_ag9FGrk8okPzGJZzWL7UuK21NYckM6Tsbtaapmv3iFM4Hn8dW">>,
dets:foldl(
    fun
        ({{draft, O, _Id}, D}, Acc) when O =:= Owner ->
            [maps:with([id, owner, status, created_at, funded, feature_hash], D) | Acc];
        (_, Acc) -> Acc
    end,
    [], damage_schedule_v2_store).
```

Do not delete the draft/journal entry or click enable with a new request ID to
bypass an unresolved write. This patch does not implement automatic on-chain
reconciliation or a one-click operator resolution API. Resolution requires
checking the actual contract state and reconciling the local schedule/draft and
operation together. It does not retroactively recover a transaction hash that
was never stored; old orphan drafts are marked `legacy_create` with unknown
outcome rather than guessed.

## Verification limits

See `schedule-operation-validation.md` in the download. Node unit tests and real
Chromium fixture checks were run. Erlang/OTP and rebar3 are not installed in the
build environment, so compilation, EUnit and live backend integration remain
unverified. No actual invoices, signatures, transactions, schedules or payments
were created in validation.
