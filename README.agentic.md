# DamageBDD supervised agents with Aeternity accounting

Merged source for the uploaded `damage_agent.erl` and the preceding agentic-task
package. One facade now exposes both management and asynchronous task APIs. The
model proposes actions; operator-owned templates and policy decide what can run;
independent acceptance evidence and accounting completion remain separate.

**Integration/review build, disabled by default.** The four Sophia agent contract
sources/ACIs were not available. This package integrates their shown entrypoints;
it does not supply replacement contracts, deploy them, or establish their economic
safety. Erlang compilation and EUnit execution were not possible in the authoring
environment. Read `VALIDATION.agentic.md` before enabling anything.

## Main files

- `docs/AGENT_ACCOUNTING.md`: source review, budget lifecycle, ABI expectations,
  API migration, recovery adapter contract, limitations and deployment gates.
- `docs/AGENTIC_TASKS.md`: underlying capabilities, provider, dashboard, private BDD
  lane and ECAI candidate-evidence format.
- `config/agentic.config.sample`: tuple-based settings, owner/agent bindings, source
  pins and explicit sample integer tariffs. Both enable/review gates default false.

## Accounting behaviour

An entire task ceiling is reserved before any LLM/action/verifier invocation. Each
invocation has an operator-fixed admission tariff; the next tariff is checked and
persisted before dispatch. This is not token-based or measured provider billing.
Failed attempts consume the same tariff. DAMAGE base units and AE gas/provider
costs are separate; this integration does not cap every external expense.

Reservation, settlement and receipt writes have separate persisted states. Unknown
outcomes stop at `accounting_pending`, without blind mutation retries. A default
read-only reconciliation implementation cannot be supplied without the actual
contract getter ABI; `damage_agent_chain:reconcile/2` intentionally fails closed
until a deployment-specific backend is installed.

Budget status is shown in `/automated-tasks` and private candidate ECAI exports.
The BDD module adds settled-accounting and monetary-ceiling assertions. Existing
management methods are not LLM capabilities. The legacy `execute_job/2` now returns
asynchronous acceptance and requires a reviewed template; update callers.

## Install

Choose the merge patch against the uploaded legacy facade OR the upgrade patch
against the earlier generated package, never both. The ZIP contains their common
result. Back up/quiesce existing workers before replacing modules.

The supervisor/router additions remain:

```erlang
%% damage_sup child list
damage_agent_sup:child_spec(),

%% damage_app:get_trails/0 handler list
damage_agent_http,
```

Use the separate wiring patch only if these additions are absent. Add the supplied
navigation link to your current dashboard or mount its browser component. Verify
step discovery in the actual release. Existing dashboard navigation is not replaced.

Run in an isolated monorepo test environment:

```sh
rebar3 compile
rebar3 eunit --module=damage_agent_tests
rebar3 eunit --module=damage_agent_accounting_tests
node --test apps/damage/test/agent_tasks_ui.test.mjs
python3 scripts/check_agentic.py
python3 scripts/check_agent_accounting.py
```

There are 13 original and 17 new EUnit cases; these were authored but not executed.
The 15 Python static checks and 11 JavaScript tests were executed successfully.
Static checks are not Erlang compilation or a treasury simulation.

The underlying agent still does not provide unrestricted shell/eval, arbitrary
model-authored executable Gherkin, live-checkout edits, automatic merge/deployment,
native ECAI training/import, distributed leases or universal external-effect rollback.
Compile/parser/dependency compatibility and the contract-level invariants remain
explicit deployment gates, not assumptions inferred from method names.
