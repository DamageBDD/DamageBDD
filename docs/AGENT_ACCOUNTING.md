# Agent accounting merge and source review

Date: 2026-10-22

This merges the uploaded `damage_agent.erl` management/accounting facade with the
previous supervised agentic-task implementation. It does not replace, deploy, or
prove the security of the Sophia contracts. The four agent contract implementations
and their ACIs were not supplied or located in the available project materials.
Keep both `enabled` and `accounting_contracts_reviewed` false until the Erlang build,
contract ABI checks, economic invariants and testnet lifecycle tests pass.

## 1. Findings in the uploaded facade

References below are to the original 282-line uploaded `damage_agent.erl`, not the
replacement file in this bundle.

| Finding | Source | Consequence and merge treatment |
|---|---|---|
| Estimate defaults to zero; authorization/reservation precede estimation | Lines 18–28, 66–88, 116–176 | The original reserve receives zero. Its later `estimate_cost/1` always returns 1. Replace this with an operator-fixed task ceiling reserved before any planner/action/verifier invocation, and an explicit fixed tariff schedule. |
| Contract-call arguments do not match the available AE APIs | Lines 40–51 and the repeated `contract_call(damage, Ct, Function, Args)` pattern | The indexed newer `damage_ae:contract_call/4` expects address, source, function and args, with an implicit node signer; the older mounted snapshot exports only /5 and /6. Use /5 with an explicit requester keypair, contract address and source path. |
| Failure classification is permissive | Lines 249–254 | All values except two error tuples become `passed`; report_hash is a hash of an Erlang term rather than a genuine report reference. Task acceptance and accounting completion are separate, with deterministic private content hashes. |
| Settlement and receipt are independent, synchronous writes without recovery | Lines 179–246 | `ok = settle(...)` followed by `ok = write_receipt(...)` can crash between writes. Persist each intent/result separately, hold uncertain outcomes, and never blindly replay. |
| Execution can use a second spending path | Lines 163–170, combined with `damage.erl` lines 295–316 and 521–525 | The ordinary runner invokes `damage_ae:spend/2` and `confirm_spend/2`. The merged agent uses the private approved-template lane instead; it does not add a second ordinary-runner debit. |
| Existing and generated modules collide | Both define `-module(damage_agent)` | One facade now exports the management API and supervised task API. There is no second same-named module. |

These are source observations. They do not establish what any deployed treasury,
registry, policy or ledger actually enforces.

## 2. Authority and budget lifecycle

The authenticated account chooses an operator-configured template. The template
selects the agent identity, capability catalogue, verifier and monetary schedule.
The caller/model cannot supply a signer, source path, contract address, tariff or
larger ceiling. Per-account `agent_bindings` must permit that template's agent ID.

```
queued
  -> budget_preparing: resolve account contracts and pin source hashes
  -> budget_reserving: durable reservation intent; authorize ceiling; reserve
  -> reserved: mutation result must carry inclusion metadata
  -> budget_authorizing: dry-run the configured policy method for this invocation
  -> persist fixed invocation-admission charge
  -> planner / action / verifier worker
  -> repeat within local time/call/monetary limits
  -> settling: persist stable receipt draft and settlement intent; settle booked units
  -> receipting: persist ledger-write intent; write the same receipt
  -> execution terminal state, with accounting_complete=true
```

Policy authorization is a read/preflight, not a reservation. The actual reservation
uses a stateful contract call. A preflight and a later reservation are not atomic;
the treasury must enforce the current policy, available funds, uniqueness and
ownership atomically when accepting a reservation. Separate checks in Erlang do not
substitute for that contract requirement.

The local invariant is `0 <= spent_units <= max_cost_units`. Reservations are for
the entire configured task ceiling. Every admitted planner, action and verifier
invocation is checked against the remaining allowance before dispatch. Waits do not
have a separate tariff; the planner invocation proposing a wait still does.

**Pricing is fixed per admitted invocation, not measured LLM usage.** Charges record
durable dispatch intent. Failed/timed-out invocations have the same tariff as
successful ones. A crash after intent persistence but before the worker starts can
leave a booked admission without confirmed work; retain that evidence for operator
review. Provider token metadata is not trusted billing evidence. `llm_calls` and
`action_calls` count orchestration attempts and can precede admission; the budget's
`dispatch_count` counts booked admissions, not proof of upstream consumption.

All amounts in this integration are integer **DAMAGE base units**. This denomination
is an explicit integration choice that must match the deployed treasury ABI. Do not
pass whole-token floats, satoshis, millisatoshis or AE amounts into these fields.
The sample prices are illustrative. AE transaction fees/gas and an external model
provider's bill are separate and are NOT capped by this DAMAGE budget. There is no
FX conversion or cross-asset aggregate spending guarantee.

`allocate_budget` is retained as the original function name. Its name does not
establish that it deposits or escrows tokens. Similarly, `settle(JobId, Cost)` does
not by itself prove that unused reservation capacity is released or refunded. That
behaviour must be verified in the actual treasury; no invented refund call is made.

## 3. AE adapter and preserved interface

`damage_agent_chain` is the default trusted accounting backend. It uses
`damage_ae:contract_call(Keypair, ContractAddress, SourcePath, Function, Args)` for
mutations and `contract_call_dry/5` for policy authorization. It accepts binary,
charlist and atom response keys through a strict decoder, rejects duplicate aliases,
and distinguishes false, revert, error, submission and included execution.

The default mutation decoder expects a successful boolean `true` or Sophia unit
`{}` plus matching caller/contract, a positive caller nonce and positive inclusion
height. Confirm these return types and the inclusion metadata against the real
ABI/client. A transaction hash alone or dry-run success is insufficient. Inclusion
is not a finality-depth or reorganization guarantee; use a deployment-specific
backend to wait for the required depth and verify chain identity.

| AccountRegistry name | Methods referenced by the uploaded facade |
|---|---|
| `agent_registry` | `register_agent(AgentId, Controller, PolicyCt, TreasuryCt, MetadataHash, CapabilityHash)`, `pause_agent(AgentId)`, `revoke_agent(AgentId)` |
| `agent_policy` | `authorize_method(AgentId, Method, Cost)` |
| `agent_treasury` | `allocate_budget(AgentId, Amount)`, `reserve(JobId, AgentId, Ceiling)`, `settle(JobId, Cost)` |
| `agent_execution_ledger` | `write_receipt(ReceiptId, AgentId, JobId, Requester, Executor, FeatureHash, ReportHash, InputHash, OutputHash, Cost, Status, StartedAt, EndedAt)` |

Addresses resolve through the requester's existing AccountRegistry, using the
existing node-registry helper. Contract source paths and SHA-256 values are operator
configuration; they are copied into the task binding and rechecked before calls.
A local source hash is NOT verification that deployed bytecode matches that source.
The configured network ID is pinned, but the operator still must verify the node's
actual network and deployment.

The requester is the explicit signer. A missing requester key fails closed; the
adapter does not silently substitute the node key. The node public key identifies
the executor in receipts. Management calls must originate from a separately
authenticated control plane; the Erlang facade is not itself an authentication
protocol. No fund/register/pause-agent/revoke-agent method is exposed as an LLM skill.
Noncustodial wallet intents are not implemented here.

The adapter serializes its own writes per signer on one node. All other writers for
that signer need shared nonce coordination. This is not a distributed nonce service.

## 4. Interruption, reconciliation and receipt truth

Unknown reservation, settlement and receipt outcomes become `accounting_pending`.
The task does not mark itself complete, free a hold, or retry the mutation merely
because an RPC timed out. Local cancellation cannot roll back chain effects. During
an active accounting write, pause/cancel are refused; operation timeouts still bound
the worker. Uncertain execution remains distinct from accounting completion.

A recovered pending reservation is not a license to execute the old job. Once a
trusted read proves that the exact hold exists, the task cancels without execution
and calls settle with zero booked units. Whether this releases the hold is a
contract-level condition. An interrupted execution needs external effect review;
no generic replay/rollback is offered.

Successful execution is exposed separately as `execution_status`. The public
`accounting_complete` field becomes true only after both settlement and receipt
inclusion. The `receipt` field can be an off-chain draft while writes are pending;
check `receipt_state`, not merely the presence of a receipt object.

Receipt IDs are deterministic per chain-scoped job. The draft is persisted once and
reused unchanged across reconciliation. `feature_hash` is either the sole configured
BDD feature's SHA-256 or the task policy hash, as declared by `behaviour_identity`.
Report/output hashes identify private evidence bytes; they are not invented IPFS
CIDs. The receipt's coarse status is `passed` only after the configured verifier
passes; other terminal execution states use `error`. An artifact-integrity verifier
still does not establish semantic correctness of a review or documentation draft.

### Missing contract read ABI: an explicit deployment gate

The default `damage_agent_chain:reconcile/2` returns
`{error, contract_reconciliation_adapter_required}`. No `get_reservation`, refund,
receipt getter or middleware-event schema was supplied, so none was fabricated.
The dashboard exposes a reconciliation command, but **automatic live reconciliation
is not functional until a deployment-specific read adapter is installed**.

A trusted accounting backend exports:

```erlang
prepare(Budget) -> {ok, Binding} | {error, Reason}.
reserve(BoundBudget) -> {ok, InclusionProof} | {error, Reason}.
authorize(BoundBudget, MethodBinary, IntegerUnits) -> ok | {error, Reason}.
settle(BoundBudget, IntegerUnits) -> {ok, InclusionProof} | {error, Reason}.
write_receipt(BoundBudget, StableReceipt) -> {ok, InclusionProof} | {error, Reason}.
reconcile(BoundBudget, StableReceiptOrEmptyMap) -> {ok, Observation} | {error, Reason}.
```

`prepare` returns exactly `contracts`, `sources`, `source_hashes`, `executor` and
`network_id`; the first three contain the policy, treasury and execution-ledger keys.
`InclusionProof` includes `contract_id`, `caller_id`, `caller_nonce`, `height` and
`outcome=included`, with optional transaction hash and gas metadata. The adapter must
actually verify the chain result, not simply populate this map.

Read-only reconciliation observations are bound to `job_id` and the original proof:

```erlang
#{stage => reserved, job_id => JobId, reserved_units => Ceiling, proof => Proof}.
#{stage => settled, job_id => JobId, cost_units => BookedCost, proof => Proof}.
#{stage => receipted, job_id => JobId, receipt_hash => StableReceiptHash, proof => Proof}.
```

A verified settlement observation advances only to receipt writing, never a second
settlement. A verified receipt observation finalizes without another write. An
unrecognized or missing observation keeps the hold unresolved. The adapter must
check the owner/agent/network as well as the exact stored record and receipt fields;
request JSON and model output cannot supply these observations. Absence from a
partial middleware page is not proof that a mutation never occurred.

Management writes (`fund_agent` etc.) remain immediate calls, not a durable
idempotent workflow. Their shown ABI has no funding request ID. Do not automatically
retry an uncertain funding/registration result. The task idempotency guarantees do
not extend to those management operations.

## 5. API and migration changes

The original function names coexist with the supervised API, but several semantics
are intentionally different. Update callers rather than expecting drop-in results.

| Function | Merged behaviour |
|---|---|
| `create_agent/1`, `fund_agent/2`, `pause_agent/1`, `revoke_agent/1` | Explicit requester-signed management operations, reviewed source pins and owner/agent binding; return normalized inclusion proof or error. |
| `create_job/2` | Returns a map descriptor instead of the module-private record. Requires `template`; rejects nonempty arbitrary context. Optional `feature_data` must exactly match a configured BDD action. `estimated_cost` is now the reserved ceiling, not a prediction. |
| `execute_job/2` | Returns asynchronous task acceptance, not synchronous execution/result/settlement. Supply a stable `job_id` for retry idempotency; poll by the returned task `id`. |
| `write_receipt/2` | Returns `receipt_managed_by_task_lifecycle`. Arbitrary callers cannot supply a passed status or settlement amount through this facade. |
| `start/4`, `status/2`, `command/4`, `events/2`, `learning/2` | Existing supervised APIs, now carrying budget state; command adds `reconcile`. |

```erlang
{ok, Task} = damage_agent:execute_job(<<"maintenance-agent">>, #{
    requester => AuthenticatedAccount,
    template => <<"code-review">>,
    job_id => <<"stable-client-request-id">>,
    objective => <<"Review the configured snapshot and report concrete defects.">>
}),
TaskId = maps:get(id, Task),
damage_agent:status(AuthenticatedAccount, TaskId).
```

Quiesce the existing agent service before upgrading. Do not hot-replace the facade
under active workers. Drain or explicitly reconcile old work, back up the private
store, and use a separate state directory for testnet. Older unaccounted task records
are not retroactively billed. Code/config hash changes can intentionally prevent
old tasks from resuming.

## 6. Dashboard, BDD and ECAI evidence

The existing `/automated-tasks` page now displays accounting phase, integer ceiling,
booked units and remaining allowance. It exposes `reconcile` only for unresolved
accounting and does not offer a user-editable cap, tariffs or arbitrary fund action.
Existing dashboard navigation still needs the supplied link or component mounted.

```gherkin
Then the agent task "review" should have settled accounting
And the agent task "review" should stay within its monetary budget
```

These are new implemented `steps_agentic` assertions, not claims that they already
existed in the runner. Starting a task does not wait for settlement; run assertions
after refreshing/joining a completed task. Dry-run steps do not reserve or mutate.

Candidate ECAI exports include the checkpoint, accounting intents, booked units,
receipt draft/proofs and execution evidence. They remain
`candidate_evidence_not_training_truth`, with `training_eligible=false`. A settled
receipt proves neither that generated prose is correct nor that ECAI imported it.
No native ECAI importer or automatic training is added.

## 7. Installation and deployment gates

Apply exactly one source patch: the merge patch against the uploaded legacy facade,
or the upgrade patch against the preceding generated agentic package. They produce
the same source tree. The existing separate supervisor/router wiring patch is needed
only when those two additions have not already been made.

Merge `config/agentic.config.sample` into the existing damage configuration; do not
replace unrelated settings or `ae_network_id`. Set exact owners, per-owner agent
bindings, origin, private state path, provider and immutable inputs. Set the four
source paths and their real SHA-256 values. Keep reviewed/enabled flags false until:

1. The monorepo compiles and all supplied EUnit suites and live parser/authentication
   fixtures pass. The authoring environment did NOT compile Erlang or execute EUnit.
2. Actual Sophia source/ACI/deployment bytes establish signer/agent ownership,
   registry pause/revocation checks, atomic available-balance reservation, unique job
   IDs, integer units, settlement bounded by the reservation, unused-capacity release,
   and immutable/idempotent receipts. A flag or local source hash is not an audit.
3. Testnet checks cover concurrent reservations, duplicate jobs, lost write responses,
   retries/restarts at every intent/result boundary, policy changes, expiry, failed
   tasks, gas exhaustion, zero-cost cancellation and stale/reorganized chain reads.
4. A read-only reconciliation adapter and the required confirmation-depth policy are
   implemented from those actual contracts, and signer nonce coordination covers all
   competing writers. Configure an independent AE fee limit/operational safeguard.

The test backend is an in-memory model that releases unused capacity. It is not a
Sophia implementation, proof of a deployed treasury's economics, or a live backend.
The store is node-local DETS. No shared-store/multi-node task fencing, distributed
exactly-once execution, externally immutable audit log, universal refund mechanism
or production security certification is claimed.
