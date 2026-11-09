# Agent Payment Guard

## Status and routes

Implemented: browser-local synthetic demonstration under Applications, public
without authentication, and an independent command-line verifier. Routes:
`/dashboard#payment-guard`, `/#payment-guard`, and static standalone
`/static/payment-guard/index.html`. The dashboard uses its existing static route;
this change does not add a public mutation or execution endpoint.

Not implemented: native ECAI indexing/retrieval, model inference, real human
approval, real payments, distributed transaction coordination, server-side
payment enforcement or remote DamageBDD execution. Local acceptance checks are
explicitly labelled local. No Gherkin text is passed off as a registered or
executed DamageBDD feature.

## Architecture

`payment-guard-model.js` owns fixed versioned scenarios, strict controls, proposal
validation, the in-memory final gate, mock ledger and report generation.
`ecai-payment-guard.js` owns rendering and lifecycle only. It cannot authorize a
payment by displaying a green badge: the ledger transitions come from the gate.
However both run in the browser, so this is a demonstration of a boundary, not a
security boundary against a user who controls that browser.

`verify_payment_guard.py` is a separately implemented Python evaluator. It
regenerates the fixture and expected complete report, including the unguarded
comparison, checks and ledger. It does not import or run the JavaScript model.
This is independent implementation of the same specification, not an independent
source of physical or business truth.

### Decision sequence

1. Load an allowlisted scenario and bounded controls into a fresh isolated run.
2. Retrieve the known invoice, supplier, policy and approval fixture records.
3. Use a predetermined candidate; do not claim a live LLM made the mistake.
4. Check the current execution state, then synchronously debit the local ledger
   only if every required check passes.
5. Store the successful idempotency receipt and settled invoice. The same key and
   same payload return the original receipt. The same key with another payload
   conflicts. A new key cannot bypass the already-paid invoice constraint.
6. Display the actual ledger and export a full replayable report.

The guarded conventional and ECAI comparison paths use the same gate, separate
ledger instances, identical inputs and no hidden policy advantage. The
unguarded lane deliberately ignores the final checks; its outcomes are synthetic
comparisons, not an empirical evaluation of a model or existing vendor.

### Trusted versus untrusted, within the fixture

The agent proposal contains exact IDs, beneficiary, amount, currency, tool,
policy/supplier revisions and idempotency key. Extra fields—including
`approved=true`—are rejected. Strings are bounded and amounts are positive safe
integer AUD cents. The proposal cannot supply its own approval record.

The approval record binds invoice, supplier, beneficiary, amount, currency and
both revisions. The active beneficiary requires one allowed non-requester
approver. A pending beneficiary requires two distinct allowed non-requester
approvers plus a bound bank-change approval. These are fictional principals, not
cryptographically verified signatures or real role assignments.

Expiry is exclusive: `execution_clock < expires_at` is required. Missing supplier
evidence fails closed. A policy change after preview is checked again before the
debit; preview is never an execution authorization token.

### Ledger and concurrency limits

Each comparison resets all three ledgers to A$20,000. It does not persist payment
history across page loads, sessions or comparisons. Retries and queued requests
are within one scenario run. Transactions are synchronous and have no await
between final checks and debit. One hundred concurrently queued test promises
produce one debit against the same invoice in one JS instance.

This is **not** a distributed locking or exactly-once external settlement
claim. There is no database, crash recovery, durable outbox, provider callback,
network timeout reconciliation or coordination between browser tabs.

## Scenario guide

| Scenario ID | Reference behaviour |
|---|---|
| redirected | Unapproved beneficiary blocked; A$4,800 remains in protected ledger |
| legitimate | A$4,800 debit succeeds |
| injection | Scripted instruction-following candidate blocked by payment policy |
| duplicate | First debit succeeds, identical retry returns receipt, different key is blocked |
| expired | Approval rejected after expiry |
| approved-change | Bound two-person pending-account approval succeeds |
| stale-policy | Preview passes; execution rejects old policy revision |
| concurrent | Two local queued submissions yield one debit and one rejection |
| direct-tool | raw_transfer is not an authorised debit tool |
| missing-evidence | Absent supplier record prevents debit |

Controls are a per-payment limit from 50,000 to 1,000,000 cents and an execution
clock offset from zero to sixty whole minutes. The UI offers a useful subset of
clock values. Picking a scenario resets these controls to reference values;
changing controls invalidates prior outputs until Compare is pressed. At limits
below A$4,800 or at/after expiry, a nominally legitimate fixture is no longer
eligible. The UI reports Not eligible rather than a failed success rate.

## Evidence format and limitations

Schema: `ecai.payment-guard.evidence/v1`; engine: `payment-guard-v1`; scope:
`synthetic-local-sandbox`. The body includes controls, known fixture, all proposals,
three ledgers, per-request checks and acceptance checks. SHA-256 covers compact
UTF-8 JSON with recursively sorted object keys and preserved array order.
The `sha256` field itself is excluded.

The verifier requires the supported version/scope and exact independently
reconstructed body. Modifying a balance, approval, label, check or fixture and
recalculating the checksum does not make it valid. Input reads are capped at
1 MB. Duplicate JSON keys, floats, NaN and Infinity are refused.

This is consistency verification, not authenticated provenance: a fully replaced
valid fixture is still a valid fixture. To establish who produced an artifact,
when it was produced or what production service executed it would require
separate trusted signatures, timestamps and execution evidence.

## Public-access and lifecycle integration

The panel does not have `data-ecai-managed`. Its view registry, navigation,
breadcrumb, lifecycle cleanup and local refresh branch are integrated into the
existing console. It does not call the request wrapper or change its allowlist.
It never touches login state, sessions, provider settings or payment routes.
Existing account-dependent workspaces retain their restrictions.

Replay stops when hidden, navigated away, disposed or the tab is hidden. Reduced
motion uses manual step selection. The native tour dialog supports keyboard
focus and Escape. Presentation mode falls back to an in-page overlay when
fullscreen is denied. Mobile testing includes 320px and 390px viewports and
checks numeric-card clipping, not only document scroll width.

The standalone page uses the same UI and model. No CDN, remote fonts, analytics,
API key, wallet or external service is loaded. Evidence export needs Web Crypto
in an HTTPS or localhost secure context. Missing Web Crypto produces a clear
message rather than inventing a digest. Changing a scenario during an async
export prevents the old result from being exported.

## Verification commands

```sh
node --test apps/ecai/test/payment_guard/model.test.mjs
python3 apps/ecai/test/payment_guard/verifier_test.py
python3 apps/ecai/test/payment_guard/browser_test.py
python3 apps/ecai/test/payment_guard/console_browser_test.py
node apps/ecai/test/payment_guard/export_fixtures.mjs /tmp/payment-guard-evidence
python3 apps/ecai/tools/verify_payment_guard.py /tmp/payment-guard-evidence/duplicate.evidence.json
```

Playwright and Chromium are test-only dependencies. The offline browser test
uses a clearly identified test digest adapter; `PG_TEST_HTTP=1` enables a local
HTTP/native Web Crypto mode for a workstation that allows navigation. The build
environment's browser policy blocked localhost navigation, so HTTP mode was not
validated here. Do not interpret DOM tests as live Cowboy or authentication
service acceptance. Other dashboard modules are stubs in the console test;
EnergyFlex is real when it is present.

## Before any production payment integration

Keep authorization at a trusted downstream execution service, not in the model
or browser. Use authenticated tenant and actor context derived by the server;
versioned supplier/invoice/approval records; scoped approver identities;
transactional unique invoice and idempotency constraints; durable journals and
outboxes; provider reconciliation; bounded retry logic; and meaningful negative
acceptance tests against the installed deployment. No browser-supplied green
status, role, approval array or policy should be treated as authority.

Relevant primary guidance consulted for this design boundary:

- OWASP Transaction Authorization Cheat Sheet:
  https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html
- OWASP LLM06:2025 Excessive Agency:
  https://genai.owasp.org/llmrisk/llm062025-excessive-agency/
- OWASP Business Logic Security Cheat Sheet:
  https://cheatsheetseries.owasp.org/cheatsheets/Business_Logic_Security_Cheat_Sheet.html

No claim of regulatory compliance, complete fraud prevention, financial advice,
measured loss avoidance or immunity to adversarial attacks is made.
