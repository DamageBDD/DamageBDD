# Feature-driven Verification workspace

## Delivery and scope

This change adds **Verify** to the existing DamageBDD dashboard, at
`/dashboard#verification-tab`. It is an implementation patch, not a claim that
any deployed AWS signer, credential boundary or Lightning node has passed.

The feature file and context are the only per-check inputs. There are no YAML
sidecars, per-feature JSON descriptors, frontend check registries or custom pages
for the three supplied checks. Existing administration pages remain available.

The operator flow is:

1. Open **Verify**, search the deployed features and select one.
2. Read its native Feature description and Scenario names. Gherkin is collapsed
   under **View the feature and execution steps**.
3. Review safe context values and fill any missing editable inputs.
4. Select **Review & estimate**. Static validation and the existing runner's
   dry-run compute the charge. This is not a verification pass.
5. Explicitly approve the exact feature/context/input estimate; select **Run
   verification**. The whole feature runs through the normal DamageBDD pipeline.
6. Inspect progress, the result, and the native report. A downloadable workspace
   receipt is a status export, not an independently signed attestation.

## Included features

| File | What it does | Important limit |
| --- | --- | --- |
| `nostr-bunker.feature` | Fresh AWS-bunker health/custody checks, then a serialized live relay/signature/denial/audit verification via the existing handoff controller. | No rotation, new client provisioning, restart, Bitcoin custody or complete effective-IAM proof. Existing approved diagnostic identity and relay policy must be configured. |
| `credential-containment.feature` | Calls the actual browser-session lookup/revoke callbacks against isolated synthetic session state. Verifies a positive control, rejection after revocation, a surviving unrelated session, wallet privilege-policy denials and rejection of a forged admin flag. | Does not publish a secret, scan Git history, revoke a real provider credential or prove GitHub/CI isolation. Release transfer is checked at the wallet-policy function boundary, not by a live HTTP request. |
| `lightning-payment-policy.feature` | Uses the configured CLN adapter's read-only `getinfo`, then exercises the same amount-policy evaluator called by the live NWC wallet, using synthetic amounts, balance and block height. | No invoice creation, wallet payment, settlement proof, concurrency/debit proof or inspection of all production NWC policies. |

All supplied step implementations require the existing `node_admin` role. Tags
are descriptive only: writing `@readonly`, `@security` or `@admin` does not confer
privilege or change what a step does. Normal authenticated managed accounts may
browse the catalog, but unavailable/unauthorised steps block their execution.
Wallet-only login cannot use this managed execution API.

For the Lightning feature, enter `100000` for `verification_single_msat` and
`500000` for `verification_total_msat` as an example. These are **millisatoshis
for the synthetic policy**, not payment amounts or a quote for runner charges.
Normal DamageBDD execution charges remain separate and are displayed at approval.

## Feature and context convention

By default, deploy approved feature files under:

```text
apps/damage/priv/features/verification/
```

`Feature:` supplies the title, its description supplies the explanation, tags
supply search/filter labels, and scenarios supply the human-readable checklist.
Input fields come from ordinary `{{variable_name}}` placeholders in executable
step text and arguments. Metadata remains native Gherkin; no YAML comment blocks
or extra descriptor syntax are introduced.

New browser-editable nonsecret variables use `input_...` or `verification_...`
names, for example:

```gherkin
@verification @lightning @synthetic
Feature: Rehearse a bounded payment policy
  Exercise the deployed policy evaluator without sending a payment.

  Scenario: Enforce the requested limits
    When I rehearse the Lightning policy with single limit "{{verification_single_msat}}" and total limit "{{verification_total_msat}}" millisatoshis
    Then the synthetic Lightning policy MUST enforce limits revocation expiry and balance
```

Values already available through the existing context are prefilled only when
safe. Sensitive values are neither returned nor editable. Locked and protected
values stay server-controlled. The browser never receives the complete context.
Names containing secret/password/passphrase/token/private/rune/macaroon/nsec are
not accepted as editable inputs. Browser input is bounded UTF-8 text, not nested
Mustache syntax or multiline/quoted step syntax. Put credentials into protected
context, **never into feature literals or these text fields**: deployed source is
readable by authenticated catalog users.

This first version executes whole features rather than arbitrary subsets. It
uses the existing static checker, which currently supports ordinary Feature,
Background and Scenario structures; Rule and Scenario Outline remain blocked by
that checker. Missing steps or parser dependencies do not become green checks.

To add another supported check, deploy its `.feature` file in the catalog
folder, ensure its steps are registered and authorised, provide its existing
context, and refresh the catalog. No frontend change is needed.

## Backend integration

- `damage_verification_catalog` discovers bounded, administrator-deployed feature
  files, parses them with the existing `egherkin` dependency, and projects UI data.
- `damage_verification_http` exposes authenticated, same-origin catalog,
  detail, preview, approval, job status and history routes.
- `damage_verification_service` supervises bounded asynchronous worker processes,
  tracks per-account previews and runs, and makes repeated approval idempotent.
- `damage_verification_runner` invokes the existing `damage_http:execute_bdd/4`
  orchestration, retaining frozen context, costing, balance checks, execution,
  settlement, report creation and native run history.
- `verification_formatter` emits only source-line/status progress. It never
  forwards bodies, context, credentials, signatures or exception strings.
- `steps_verification` and `damage_verification_checks` implement the supplied
  checks using existing production services and policy functions.

The router, supervisor, dashboard renderer, sidebar and page shell receive small
integration hunks. Existing dashboard routing and authentication events are used;
there is no replacement application shell.

The NWC amount/quota/expiry evaluation is extracted into
`damage_nwc_payment_policy`, which is called by **both** the live wallet and the
synthetic rehearsal. Valid-policy precedence, zero-as-unlimited semantics and
`Height > expires_height` are preserved. Malformed policies and nonpositive or
noninteger amounts now fail closed. Ledger lookup and payment settlement remain
in the existing wallet. This is security-sensitive production code: run its
EUnit tests and existing wallet regression tests before deploying.

## Approval and execution boundaries

Each estimate binds source SHA-256, safe submitted inputs, context proof
fingerprint and observed code/catalog revision. Immediately before execution,
preflight rechecks the feature, code, context and current step authorization.
The normal runner additionally checks the **actual frozen context** against the
approved fingerprint before its dry-run. The charge must not exceed the approved
estimate. No browser-provided identity, role, arbitrary source, filesystem path,
module name or callback is accepted.

Avoid hot code upgrades during active verification. The revision identifies code
observed at preflight; this implementation does not create a VM-wide immutable
code snapshot. The existing step-level authorization and settlement boundaries
still apply during execution.

The live bunker check requires new evidence generated after its request. A
previous passing report or a controller failure cannot count as the new pass.

Limits: one active job per account, four per node, 256 retained job records,
five-minute approval validity, 25-minute worker deadline and one-hour in-memory
workspace retention. The current implementation is **single-node**. Use sticky
routing to the owning node; a cluster-wide durable coordinator is not included.

There is no automatic POST retry, background scheduling, cancellation/rollback,
maintenance workflow, real provider revocation, or resumption of a partially
executed feature. Leaving a tab does not cancel an already accepted execution.
After restart, timeout, worker failure or a lost response, inspect the native run
history and any settlement transaction before submitting a new run. An unknown
outcome is not a failure-to-execute claim. An old approval cannot launch again
after restart because the in-memory preview no longer exists.

`pending` and `indeterminate` are deliberately separate from assertion failure.
A successful result without native report evidence is not exposed as a pass.

## HTTP API

All routes are under `/api/verification`. `GET` is observation-only.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/catalog` | Native feature projections; no execution |
| GET | `/features/:id` | Source, safe field projection and static authorization/step validation |
| POST | `/preview` | `{feature_id, sha256, inputs, request_id}` |
| POST | `/run` | `{preview_id, approved: true}` |
| GET | `/jobs/:id` | Requesting account's job only |
| GET | `/history` | Up to 20 recent jobs owned by the authenticated account |

Mutations require JSON and `X-Damage-Verification: 1`, exact same-origin
validation, and reject cross-site Fetch Metadata. A bearer-authenticated CLI may
omit Origin but still needs the custom header. Requests are capped at 16 KiB.
No CORS permission is added. Errors and job records use safe projections.

Behind TLS termination configure the trusted public origin in existing
application configuration (not in a feature or a new descriptor):

```erlang
{verification_origin, <<"https://your-damage-node.example">>}
```

An optional global `verification_feature_dir` selects a different approved
catalog root. Do not point it at an upload or tenant-writable directory. Files
must be deployed through the normal trusted release process. Symlinks are
ignored; depth, source size, file count and step count are bounded.

## Apply and validate

This patch was produced against the 14 October 2026 `latest-damage.tar.gz`
application snapshot, reconstructed with the available November 3 dashboard
network/UI overlays and prior bunker handoff implementation. It is **not** a
checkout of your current Git HEAD. Apply the patch, not a wholesale overlay copy,
to avoid replacing newer application code.

From your repository root:

```sh
git apply --check /path/to/damage-verification-workspace.patch
git apply /path/to/damage-verification-workspace.patch
rebar3 compile
rebar3 eunit --module=damage_verification_tests,damage_nwc_payment_policy_tests
node --test apps/damage/test/scripts/verification_model.test.mjs
python apps/damage/test/scripts/verification_browser_test.py
```

The browser test needs Python Playwright and Chromium. Set `CHROMIUM` to its
binary path where necessary. It renders the real template/CSS/JavaScript in
Chromium using a mocked fetch API. It neither talks to AWS/CLN nor runs Erlang.
Its test-fixture source reader is not the product Gherkin parser.

Builds that strip BEAM abstract code must refresh the existing trusted step
manifest for the new `steps_verification` module. Otherwise static validation
correctly reports unavailable signatures. Do not weaken that gate.

In staging, verify authenticated catalog/role denials and owner isolation, then
run the synthetic credential feature, read-only CLN/policy feature, and approved
live bunker feature. Confirm native report creation, actual billing/settlement,
expired approvals, changed-context rejection, duplicate-approval idempotency and
unknown-outcome recovery. Run the existing NWC wallet suite as well. The real
bunker feature requires the previously delivered handoff controller modules and
a fully configured signer/relay/AWS deployment.

## Validation in this delivery

Executed here: JavaScript syntax and model tests; Chromium UI tests for the full
estimate/approval/result flow, mobile width, text escaping, sensitive field
handling, stale account responses, duplicate clicks and stopped retries;
source integration checks; clean patch application against the reconstructed
baseline. Screenshots are explicitly marked as mocked UI fixtures.

Not executed here: Erlang compilation or EUnit, the complete umbrella build,
live HTTP/backend execution, real AWS/Nostr relay verification, real CLN access,
actual report publication, billing/settlement, or production deployment. The
available environment has no Erlang/OTP toolchain. The provided Erlang tests
include production-parser/signature checks, privacy/owner isolation, approval
boundaries, synthetic revocation and shared payment-policy parity tests.
