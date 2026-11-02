# Agents dashboard integration: validation record

## Executed in this environment

Python 3.13.5, Node v22.16.0 and Chromium/Playwright were available. No Erlang compiler or rebar3 executable was available.

| Check | Result |
| --- | --- |
| Existing agent UI helpers, BDD composer model, dashboard navigation Node tests | 27 passed |
| ECAI console source integration tests | 21 passed |
| New shared dashboard/routing/auth source checks | 11 passed |
| Shared agent component in actual Damage/ECAI host markup and navigation | 36 browser checks passed (18 per host) |
| Existing BDD composer real-browser fixture | 22 checks passed |
| Existing ECAI provider-settings browser scenario | Passed |
| ES-module syntax for seven changed/new browser modules | Passed |
| Diff whitespace check | Passed |

The agent browser tests cover review before execution, edit invalidation, stale-policy rejection, unchanged idempotent creation retry, exact-proposal approval, literal output rendering, accounting reconciliation controls, revision-checked routing, read-only routing for non-admins, 320/390/768/1440 px layouts, hidden polling, unsupported requirements, invalid signatures, cancellation, late replies, private-state clearing, and usable provider controls after identity reset.

Browser fixtures execute the actual component source and use the supplied dashboard markup, CSS and relevant navigation code. All identity, provider, task and accounting API replies are simulated. Unrelated ECAI controllers are stubbed in the navigation fixture. They do not run Cowboy or authenticate real accounts. Preview images are labelled as fixtures; model names, budgets, task states and account controls shown there are test data, not live activity.

No external model, secret vault, signing backend, wallet or blockchain was called. No agent task was created on a user's live node.

## Not executed

- Erlang compilation, xref/dialyzer and all Erlang/EUnit tests.
- Live Cowboy authentication, CSRF, dispatch, release startup or origin configuration.
- Live provider leasing, persistence/reconfiguration, actual cancellation/billing behaviour or remote-role denial.
- Agent execution, reservations, settlement, receipt inclusion or reconciliation on Aeternity.
- ECAI ingestion/training of an exported experience bundle.

New Erlang tests are supplied for draft schema/bounds/canonical feature/metadata/credential class. Existing tests are extended for reviewed-policy admission, wallet route permissions, route validation, revision conflicts, preservation by the older provider UI, and saved-route restart. They are **unexecuted source**, not passing evidence.

## Reproduce the executed checks

From the monorepo root:

```sh
node --test \
  apps/damage/test/agent_tasks_ui.test.mjs \
  apps/damage/test/scripts/bdd_composer_model.test.mjs \
  apps/damage/test/scripts/dashboard_navigation.test.mjs
python3 apps/ecai/test/test_console_contract.py
python3 apps/damage/test/scripts/agent_dashboard_contract_test.py
python3 apps/damage/test/scripts/agent_workspace_browser_test.py \
  --chromium /usr/bin/chromium --out /tmp/agent-workspace-ui
python3 apps/damage/test/scripts/bdd_composer_browser_test.py \
  --chromium /usr/bin/chromium --out /tmp/bdd-composer-ui
python3 apps/ecai/test/test_llm_settings_browser.py
```

Browser tests require Playwright and a Chromium executable. They run local, simulated fixtures rather than a deployed service.

## Required checks on the target branch before enabling

```sh
rebar3 compile
rebar3 eunit --module=damage_bdd_composer_tests
rebar3 eunit --module=damage_agent_draft_tests
rebar3 eunit --module=damage_agent_tests
rebar3 eunit --module=damage_agent_accounting_tests
rebar3 eunit --module=damage_wallet_policy_tests
rebar3 eunit --module=ecai_llm_settings_tests
rebar3 eunit --module=ecai_llm_pool_reload_tests
rebar3 eunit --module=ecai_ollama_client_tests
```

Then test both actual dashboard listeners with permitted managed accounts, wallet-only accounts, guests and an administrator. Confirm absent/invalid/L402 credentials do not create an invoice, account ownership is enforced, authoring does not start work, stale policy/revision changes fail, each intended provider is actually leased through the `bdd` role, and denied remote roles produce no outbound inference. Test configured ceilings and accounting on an isolated testnet setup; the earlier accounting adapter's limitations have not been removed by the UI.

## Optional older checker compatibility

The optional root-checker patch was generated against the previously delivered scope-fixed `scripts/check_agentic.py`, not the latest app-only archives. Its two changed DOM/authentication tests passed against the integrated app tree. Its unchanged broad delimiter/configuration tests were not run here; the required root `config/agentic.config.sample` was not supplied in the latest archives. The new in-app integration tests above do run against the available source tree.
