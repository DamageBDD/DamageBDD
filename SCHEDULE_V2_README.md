# DamageBDD Schedule V2 — initial end-to-end implementation

This bundle is a clean-cut replacement for the legacy scheduler. It does **not** import, load, render, or execute existing schedules. Historical reports remain historical reports, but Schedule V2 only knows about schedules created through the V2 API after deployment.

## What is included

Schedule V2 adds a dedicated Aeternity escrow contract, a new OTP scheduler, a V2 HTTP API, local run/analytics indexing, dry-run budget estimation, wallet/custodial funding flows, exact scheduled-run settlement, cancel/refund behaviour, token-upgrade hooks, and a replacement dashboard experience mounted into the existing Schedules tab.

The runtime flow is:

```text
feature + recurrence + range
        |
        v
DamageBDD dry-run ----> cost/run + occurrence count + recommended lock
        |
        v
create schedule on ScheduleV2 contract
        |
        v
approve DAMAGE V1 allowance --> fund vault --> local timer armed
        |
        v
scheduled occurrence
        |
        +--> fresh dry-run --> hard max/run check
        |
        +--> reserve_run on-chain
        |
        +--> real DamageBDD execution with settlement=schedule_v2
        |
        +--> collect exact run-scoped step cost
        |
        +--> settle_run(node, actual cost, feature hash, report hash)
        |
        v
local analytics/read model updated
```

`cancel_schedule` is owner-authorized on chain and returns every unspent, unreserved token to the schedule owner. The browser shows locked/spent/reserved/available budget and makes cancellation an explicit **Cancel & unlock** action.

## Clean cut from the legacy scheduler

`damage_app` routes schedule traffic to `damage_schedule_v2_http` and startup loads `damage_schedule_v2`; `damage_sup` no longer starts `damage_schedule` or `damage_schedule_index`. The old modules can remain in the source tree during the transition, but they are dormant and the V2 dashboard does not query or display their records.

The V2 read model is stored in its own DETS file under `schedule_v2_data_dir` and has no legacy import path.

## Current DAMAGE V1 compatibility

No change to the deployed V1 token is required for this initial scheduler.

The uploaded V1 DAMAGE token uses allowance-based transfer correctly, while its direct `transfer/2` and DamageBDD `spend/4` paths debit `Call.origin`. Schedule V2 therefore never uses those direct V1 paths for escrow exits.

Funding:

```text
user allowance -> ScheduleV2
ScheduleV2: token.transfer_allowance(user, Contract.address, amount)
```

V1 payout/refund compatibility:

```text
ScheduleV2 creates a self-allowance on its own V1 token balance
ScheduleV2: token.transfer_allowance(Contract.address, node/owner, amount)
```

The runtime patch to `damage.erl` adds `settlement=schedule_v2`. In that mode, `step_spend/2` meters each step directly into the current run context and does **not** mutate the legacy per-account spend accumulator or invoke the legacy DAMAGE `spend` settlement. The resulting run record carries the exact measured cost for Schedule V2 escrow settlement.

Initial Schedule V2 deliberately fixes scheduled execution concurrency at **1 per run** and serializes scheduled work per account. Accounting is now run-scoped, but the first release keeps this conservative execution model so reservation, execution, settlement, cancellation and restart reconciliation stay deterministic while the new path is proven. Different accounts can still run concurrently.

## Deploy and configure

1. Apply the patch or overlay the ZIP onto the matching DamageBDD tree.
2. Compile `apps/damage/contracts/schedule_v2.aes` with the project's normal Sophia compiler and run the Erlang tests.
3. Deploy the contract once after the node secret store is unlocked:

```erlang
damage_schedule_v2_contract:deploy().
```

The deployer/node account becomes the Schedule V2 contract owner and executor; the current DAMAGE contract address is passed to the initializer. The deployed `ct_...` is stored in the encrypted secret `schedule_v2_contract` when possible.

4. In production, pin the deployed contract explicitly in configuration (see `config/schedule_v2.sys.config.example`) and leave `schedule_v2_auto_deploy` false.
5. Restart DamageBDD. `damage_schedule_v2:load_all_schedules/0` arms only active V2 schedules.

A development node can set `{schedule_v2_auto_deploy, true}` to deploy when no V2 contract address is configured, but explicit deployment/pinning is preferable for production.

## Dashboard

`main.js` now imports `/static/js/schedules-v2.js`. When the existing Schedules tab opens, the V2 module replaces the legacy table in-place, so the first implementation does not require a risky rewrite of the surrounding dashboard shell/template.

The V2 dashboard provides:

- 24h / 7d / 30d / 90d / custom analytics ranges.
- Active schedule, run count, success rate, spend and available-lock stats.
- Runs/spend timeline bars.
- Last run and next run.
- Human schedule labels plus exact cron/details.
- Dry-run budget preview before creation.
- 7/30/90-day validity presets and date/time pickers.
- Recommended locked DAMAGE and a hard max-cost-per-run guard.
- Custodial account execution or staged Superhero/Sidekick signing for browser-wallet accounts.
- Pause, resume, run-now and cancel/unlock actions.

The browser records the user's IANA timezone as metadata, but the initial contract/runtime cron is canonical UTC. The UI converts selected local daily/weekday times to UTC when the schedule is created. This first version does not dynamically shift a pinned cron expression when daylight-saving rules later change.

## HTTP surface

```text
GET  /api/schedules/v2
POST /api/schedules/v2
GET  /api/schedules/v2/status
POST /api/schedules/v2/preview
GET  /api/schedules/v2/analytics?from=<unix>&to=<unix>
GET  /api/schedules/v2/:schedule_id
GET  /api/schedules/v2/:schedule_id/runs?limit=20
POST /api/schedules/v2/:schedule_id/pause
POST /api/schedules/v2/:schedule_id/resume
POST /api/schedules/v2/:schedule_id/cancel
POST /api/schedules/v2/:schedule_id/run
POST /api/schedules/v2/tx/submit
```

The V2 API reuses `damage_http:is_authorized/2`; it never trusts an owner/account supplied in the JSON body.

## Token V2 migration path

Schedule V2 contains migration state now, while the next DAMAGE token can implement the standards fixes later.

The future token V2 contract should at minimum:

- use `Call.caller` for standards-correct direct transfers;
- preserve 8 decimals and a 1:1 V1-to-V2 migration unit;
- expose `claim_v1() : int`;
- have `claim_v1()` read V1 `check_swap(Call.caller)`, enforce one claim per address, mint that exact amount, and return the amount claimed.

Once token V2 exists, quiesce and migrate the Schedule V2 vault with:

```erlang
%% Refuses to start while Schedule V2 has local running/queued work.
%% The contract also requires total_reserved == 0.
damage_schedule_v2:prepare_token_upgrade(<<"ct_NEW_DAMAGE_TOKEN">>).

%% V1 vault balance has now been swap-burned and recorded under the
%% ScheduleV2 contract address; claim that exact amount into token V2.
damage_schedule_v2:claim_token_upgrade().

%% Verifies the V2 vault balance equals the recorded migration amount,
%% switches the contract's token address/mode, and re-arms schedules.
damage_schedule_v2:finish_token_upgrade().
```

If `prepare_token_upgrade` fails, local timers are re-armed. After preparation succeeds, schedules remain quiesced until `finish_token_upgrade` succeeds.

## Failure and reconciliation behaviour

Reservations prevent concurrent/double settlement of the same deterministic run ID. A settled run ID is permanently recorded on chain, so it cannot be settled twice.

If execution never becomes billable, the runtime releases the reservation. If actual measured cost exceeds the hard cap, the reservation is released and the run is recorded as blocked. Chain transport/time-out ambiguity around a settlement should be treated as reconciliation work rather than blindly repeating payment; this initial bundle keeps the contract's run/settlement records as the authoritative anti-replay boundary.

## Validation status

In this ChatGPT environment:

- `node --check` passes for the modified `main.js` and new `schedules-v2.js`.
- The generated patch is checked with `git apply --check` against the materialized baseline used to construct it.
- This environment does **not** contain `erl`, `erlc`, `rebar3`, or a Sophia compiler, so Erlang/Sophia compilation and EUnit execution could not be performed here.

Before merge/deployment run, at minimum:

```sh
rebar3 compile
rebar3 eunit --module=damage_schedule_v2_cron_tests
# plus the repository's normal Sophia compile/deploy checks for schedule_v2.aes
node --check apps/damage/priv/static/js/main.js
node --check apps/damage/priv/static/js/schedules-v2.js
```

The escrow contract is an initial implementation and has **not** been security audited. Do not fund it with production-value tokens before contract compilation, contract-level tests, testnet execution, cancellation/refund tests, restart recovery tests, and an independent security review.
