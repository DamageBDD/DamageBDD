# Validation record — accounting merge

Date: 2026-10-22

This record distinguishes executed checks from authored tests and unverified
integration requirements. This is not a production security or financial audit.

## Executed in this environment

| Check | Result | Scope |
|---|---|---|
| `python3 scripts/check_agentic.py` | 7 passed | Lexical delimiter balance and selected static contracts; NOT Erlang parsing, compilation or execution. |
| `python3 scripts/check_agent_accounting.py` | 8 passed | Source-level checks of API coexistence, explicit signing, staged intents, cap checks, receipt classification and no invented getter/refund ABI. |
| `node --test apps/damage/test/agent_tasks_ui.test.mjs` | 11 passed | Pure UI control-state tests and selected source contracts; NOT a live browser/API integration test. |
| `node --check` for both `agent-tasks.js` and `agent-tasks-page.js` | Passed | JavaScript syntax. |
| `git apply --check` and apply of the merge patch | Passed against the exact uploaded legacy facade in a scratch tree | Patch applicability only to that stated baseline. |
| `git apply --check` and apply of the upgrade patch | Passed against the extracted preceding agentic ZIP | Patch applicability only to that generated baseline. |
| File-by-file comparison after both patch applications | Passed | Both patches reproduce the packaged merged source tree byte-for-byte. |
| Existing separate wiring patch check/apply | Passed against the retrieved app/supervisor snapshots | The unchanged router/supervisor additions match those snapshots, not necessarily the user's current branch. |

Raw static and JavaScript logs are in `validation/`. Patch verification details are
supplied as the separate `damagebdd-agent-accounting-patch-validation.txt` artifact.
Python 3.13.5, Node.js 22.16.0 and Git 2.47.3 were used.

## Authored but NOT executed

**No Erlang compilation or EUnit execution was performed.** No Erlang runtime/compiler
was available, and the complete current monorepo/dependency build was not present.
The code may still contain compile, runtime, parser or dependency integration defects.

The original suite contains 13 lifecycle/security cases. The new accounting suite
contains 15 fixture-based lifecycle cases plus 2 pure decoder/inclusion cases, for
30 authored EUnit cases in total. The new cases cover reservation before work,
request idempotency, rejected/zero/exhausted budgets, policy denial, failed-plan
receipts, lost reservation/settlement/receipt responses, identity-bound reconciliation,
restart without repeat settlement, concurrent reservations in the fake treasury,
side-effect-free dry steps, template-required legacy execution, response-key variants
and rejection of dry-run/submission-only evidence.

The fake treasury is an in-memory model. Its release of unused capacity, serial
reservation and receipt behaviour do NOT establish deployed contract behaviour.
Neither suite is a substitute for actual Sophia contract tests.

Also not executed: Sophia compilation/ACI validation; source-to-deployed-bytecode
verification; any AE/testnet/mainnet transaction; confirmation-depth/reorganization
handling; live account-registry resolution/signing/nonce races; real failed-settlement
recovery; real Ollama requests; Cowboy/authentication/CSRF/browser end-to-end tests;
live egherkin/steps_http execution; disk-full/power-loss recovery; native ECAI import;
or any repository mutation/merge/deployment.

## Incomplete integration gates that remain explicit

The four agent Sophia implementations and their read APIs were not available. Their
referenced entrypoints are integrated on the Erlang side, but automatic live
reconciliation intentionally returns `contract_reconciliation_adapter_required`.
A deployment-specific backend must verify and expose the actual read ABI, finality
policy and nonce coordination. Integer units, owner/policy checks, atomic budget
reservation, unused-capacity release and receipt uniqueness need contract-level
verification before real funds are used.

The management API is retained but some semantics change: `create_job/2` returns a
map and requires a template; `execute_job/2` is asynchronous; arbitrary
`write_receipt/2` is disabled. See `docs/AGENT_ACCOUNTING.md` for migration details.
The ordinary paid/public runner is deliberately not invoked by the agent's private
BDD lane. This prevents that path from adding an independent ordinary-runner debit;
it is not blanket support for every existing step or payment integration.

The dashboard is a standalone route plus mountable component/navigation partial.
Current dashboard navigation and step discovery still require integration. ECAI
exports are candidate evidence, not a native importer or training-truth assertion.

Keep `enabled=false` and `accounting_contracts_reviewed=false` until the compile,
EUnit, ABI, economics and isolated testnet checks in `docs/AGENT_ACCOUNTING.md` pass.
The review flag is only an operator acknowledgement, not an automated audit.
