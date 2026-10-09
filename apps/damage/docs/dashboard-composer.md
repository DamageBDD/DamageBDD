# DamageBDD workspace and ECAI feature composer

## Delivery and verification status

This patch was rebased onto the latest uploaded `latest-damage.tar.gz`, SHA-256:

```text
d1b507eff0673f1cfdae60346b159754a99d0b1201a2e0db968d316f309012ed
```

The upload contains `apps/damage`, not a complete compiled umbrella. The implementation uses the ECAI interfaces in the saved September 27 code-learning patch: `ecai_codebase_learning:module/2` and `ecai_ollama_client:generate_json/2`. It does not vendor or replace ECAI.

Verified here: five JavaScript files (including the retained billing controller) pass `node --check`; nine Node unit tests pass; twenty-two checks pass in the Chromium fixture suite (including static integration wiring assertions). These exercise the actual composer controller, actual templates/local CSS, the actual execution-in-flight wrapper with a stub execution body, and the line-number script. The preview includes six fixture signatures, not a count of deployed signatures or a live inference result. Full dashboard bootstrap, wallet signing, payment flows, report streaming and the Cowboy endpoints have NOT been exercised end-to-end here.

**Erlang compilation, the included EUnit tests, and live ECAI inference have not been run.** No Erlang runtime/compiler or running Damage/ECAI node was available in the build environment. Compile and run the backend tests in the full repository before deploying.

## Rebase integration notes

The latest upload adds enterprise invoicing in the same dashboard shell and OTP
supervisor touched by the composer. The rebase retains `billing.css`, `billing.js`,
`billing_tab`, the initially hidden `billing-nav` navigation item, the
`damage_invoice_http` route registration, and the supervised
`damage_enterprise_invoices` worker. Workspace CSS remains last in stylesheet order.
The invoice implementation and dashboard billing renderer are not replaced.

The original patch had conflicts in `page_shell.mustache` and `damage_sup.erl`;
both sides' additions are preserved. The browser fixture now derives placeholder
panels from the retained navigation links rather than maintaining a fixed list.
New assertions check combined shell/route/supervisor wiring, resolved tab targets,
and invoice navigation visibility and switching. The fixture does not execute
invoice authentication, issuance, email, PDF generation or payment workflows.

Use `damagebdd-dashboard-ecai-rebased.patch` instead of the previous patch. It is a
complete replacement patch against the uploaded snapshot, not a follow-up patch
for a working tree that already contains the previous composer changes. The
upload contains no Git history; no real branch rebase or remote fetch was performed.

## UX review of the uploaded baseline

| Finding | Source in the upload | Change |
| --- | --- | --- |
| The starting task was a blank feature editor; no prompt-to-feature workflow was present in the workspace. | `priv/templates/ui/dashboard/execution_tab.mustache` | Put an expectation prompt above the feature editor; retain manual authoring. |
| The header and wallet occupied disproportionate space, while execution controls lacked a clear authoring/review hierarchy. | `topbar.mustache`, `main.css`, `topbar.css` | Compact header and wallet summary; visibly separate Feature and Evidence cards. No invented metrics or balances. |
| Some primary actions used clickable `div` elements. | `topbar.mustache` | Make Install Node and Logout native buttons, keeping their IDs and modal triggers. |
| Multiple input paths could reach execution without a shared in-flight guard. Two primary tab toggles used incomplete IDs. | `priv/static/js/main.js` | Centralise submission guarding; keep the button disabled while awaited execution finishes; use `execution-tab` and `activity-tab`. |
| Old global rules forced 300-pixel minimum form widths, full-width buttons, column-oriented editors, and contradictory tab styling. | `auth.css`, `main.css`, `slick-tabs.css` | Scoped final stylesheet neutralises these conflicts for the new workspace; browser checks cover 320, 390, 768 and 1440 pixels. |
| The legacy BDD model call discarded the request's actual use case. | `src/damage_ai.erl`, baseline lines 155–167 | New composer endpoints use ECAI and include the actual intent. `/ai/generate` remains unchanged for compatibility; this patch does not fix all legacy AI consumers. |
| Treating a model response or an executable “dry run” as a safe validation authority is insufficient. | `damage.erl`, `steps_utils.erl`, deployed step modules | Parse Gherkin and compare signatures without invoking step bodies or the execution engine. |

The scope is the workspace plus shared dashboard header/navigation. Existing Run history, Analytics, Schedules, Swaps, NFTs, Settings, node administration and wallet internals remain. Their IDs, routes and modal triggers are preserved, but they still need full-application regression testing with the stylesheet applied.

## User workflow

**Describe → Generate draft → Review → Use draft in editor → Validate → Explicitly Run feature.**

Generation checks its candidate automatically. Validate separately checks a manually edited feature. Neither operation calls the feature execution endpoint. No generated feature is automatically run, scheduled or published. Existing explicit execution paths still handle account context, IPFS-selected sources and wallet/custodial modes.

The prompt provides three starter examples, UTF-8 byte counting, keyboard submission, elapsed time, cancellation, and errors that leave editor text intact. Model output is rendered as text, not inserted as HTML. A draft is displayed separately. Replacing existing editor text or an IPFS selection requires confirmation; Undo restores the previous editor text. An IPFS selection itself must be reselected separately after undo.

Only drafts whose static check succeeds and whose model response reports no unsupported requirements can be accepted directly. The `complete` field records that model report; it is **not** an independent proof that every user requirement was understood or covered. The user must review assumptions, targets, inputs and assertions.

Manual editing remains available when ECAI is absent. The step library searches available signatures and inserts a template with selected `<Parameter>` markers. Replace these before validation. Export writes the current editor text as a `.feature` file. The editor uses non-wrapping lines and a matching logical-line gutter so diagnostic line numbers remain meaningful on small screens.

A run is labelled “Running” and then “Request complete”, not automatically “Passed”: the existing execution report is the outcome authority. The output card starts empty, not with simulated success data or a fabricated cost estimate.

## How ECAI and the deployed code are used

1. `damage_bdd_catalog:snapshot/1` obtains step modules through `damage_utils:loaded_steps/0` and filters them using the same `steps_utils:step_module_allowed/2` boundary as the runner. HTTP callers cannot supply a role, a module list, or an account override; only the authenticated `public_key` reaches the composer.
2. The catalog reads expanded `step/6` clause patterns from BEAM abstract code. It keeps representable literal/parameter lists, exact keyword constraints, repeated variable equality, and module/source-line provenance. Broad catch-all patterns and signatures that do not round-trip through the real Damage tokenizer are excluded. It does **not** invoke `step/6`, `step_dry/6`, the runner or an execution “dry run”.
3. Relevant signatures are selected by deterministic lexical ranking, with a small set of available HTTP setup signatures. This is not claimed to be semantic or model-learned retrieval. Up to eight corresponding ECAI module knowledge cards provide advisory context about prerequisites, state and failure modes.
4. The generation prompt includes the actual user intent, the selected signatures and bounded advisory cards. It instructs ECAI to produce one JSON object with `feature`, `assumptions`, and `missing_steps`. It preserves exact step wording, avoids fabricated steps and literal secrets, keeps TLS verification enabled, and identifies unsupported requirements.
5. `ecai_ollama_client:generate_json/2` uses the node's existing ECAI model configuration. The returned JSON schema and sizes are checked. A candidate is validated against a newly read deployed catalog after inference; at most one repair attempt is made within the overall deadline.

Knowledge cards are explicitly labelled advisory and **not verified against the deployed BEAM**. Their source hash is not falsely treated as the runtime BEAM fingerprint. The new code does not refresh/train the learner in response to user prompts, ship source files to the browser, or retrieve account-context values. It uses existing cards when available and reports the number used.

The node's model service still sees the user's prompt and the selected advisory material. No privacy claim is made about logging inside an independently configured model backend. Do not paste credentials into the prompt. The new handlers do not log prompts, model replies, or credential values. Prompt/draft state is not added to localStorage by the composer.

## What “validated” means

The returned scope is `gherkin_syntax_and_step_signatures`.

It checks parsing, ordinary Feature/Background/Scenario structure, nonempty step content, quoted step arguments, unresolved `<Parameter>` markers in step text, step-count and byte limits, and membership in the current authorised module-signature catalog. It reports `{{variable}}` names in step text and docstrings without reading their values. Variables can change the rendered token structure at runtime; their eventual expansions have not been checked.

It does **not** prove argument types or values, request body schemas, context-variable availability, ordering/preconditions, guard satisfaction, permission checks inside step bodies, expected response values, target reachability, operational safety, a complete match to the user's intent, or successful execution. It does not estimate or charge execution cost. Syntax/signature validation is not a sandbox or a replacement for existing runtime authorization.

Scenario Outlines, Scenario Templates and Rules are conservatively rejected by this first static checker. Expand them to ordinary scenarios. Some custom pattern forms are intentionally omitted rather than accepting unknown syntax. Known signatures whose bodies are unimplemented or always fail are not made functional by being listed. Missing/stale debug information excludes that module's signatures; it never enables “accept everything” fallback.

## Backend modules and endpoints

| Module | Responsibility |
| --- | --- |
| `damage_bdd_catalog` | Deployed BEAM signature extraction, exact-token matching and version-bound manifest support. |
| `damage_bdd_validator` | Gherkin parsing and static signature diagnostics without execution. |
| `damage_bdd_generator` | ECAI advisory cards, bounded JSON inference and one repair attempt. |
| `damage_bdd_service` | Supervised, monitored inference workers; one active request per principal and a node-wide cap. |
| `damage_bdd_http` | Authenticated JSON transport, input bounds and no-store responses. |

| Request | Input / result |
| --- | --- |
| `GET /ai/bdd/catalog` | Authorised signatures, revision, excluded modules and availability of ECAI interfaces. |
| `POST /ai/bdd/generate` | `{ "request_id": "unique-id", "user_prompt": "..." }` → separate feature draft, assumptions, missing capabilities and static diagnostics. |
| `POST /ai/bdd/validate` | `{ "feature": "Feature: ..." }` → validation result; HTTP 200 can contain `valid: false`. |
| `POST /ai/bdd/cancel` | `{ "request_id": "unique-id" }` → whether a matching active job was cancelled. |

Requests reuse existing Bearer/cookie authorization. POST requires `Content-Type: application/json` and `X-Damage-BDD: 1`. Cross-site Fetch Metadata is rejected; this handler does not enable CORS. Keep any upstream CORS middleware restricted to trusted dashboard origins. All responses are `private, no-store`. The HTTP decoder uses binary keys, not unbounded client-created atoms.

Limits: prompt 8000 UTF-8 bytes; feature 64 KiB; JSON body 128 KiB; 512 statically checked steps; 16 assumption/missing-capability strings of at most 1000 bytes each; default inference deadline 120 seconds; default node concurrency two. Active workers are monitored and linked, killed on cancellation/deadline, and removed if the request handler dies. Cancelling the UI does not falsely confirm server cancellation when no matching active job was found. A cancel-before-admission race is reported as “stopped waiting”; late jobs remain deadline-bounded.

The catalog's `generator_available` means the ECAI interface exists, not that a model has been successfully reached. Model/network errors are surfaced during generation. A missing ECAI application does not prevent the Damage service from starting or the static checker from working.

## Configuration and deployment

Apply from the full DamageBDD repository root:

```sh
git apply --check /path/to/damagebdd-dashboard-ecai-rebased.patch
git apply /path/to/damagebdd-dashboard-ecai-rebased.patch
rebar3 compile
rebar3 eunit --module=damage_bdd_composer_tests
```

Merge tuple entries into the existing application sections; do not duplicate or replace the rest of `sys.config`:

```erlang
{damage, [
    {bdd_generation_timeout_ms, 120000},
    {bdd_generation_concurrency, 2}
]},
{ecai, [
    {code_ollama_host, "localhost"},
    {code_ollama_port, 11434},
    %% Use the model already provisioned for your ECAI code-learning service.
    {code_ollama_model, "YOUR_INSTALLED_CODE_MODEL"},
    {code_ollama_timeout_ms, 120000}
]}
```

The ECAI code-learning subsystem needs to be installed and running to supply cards. In the existing node shell, inspect/refresh its state:

```erlang
ecai_codebase_learning:status().
ecai_codebase_learning:refresh().
ecai_codebase_learning:module(damage, steps_http).
```

A learning refresh is operator work and can take time. It is deliberately not triggered by a browser request. Generation can use the ECAI JSON client with zero cards, with the returned count making that limitation visible. The prompt remains constrained by deployed signatures.

### Stripped production releases

BEAM abstract code is available through debug information; stripping can remove it. Keeping `debug_info` is convenient in development but can allow source reconstruction. Do not disable stripping merely for this feature when your deployment policy requires stripped code. Build the compact signature manifest before stripping instead.

```sh
rebar3 as prod compile
escript apps/damage/scripts/build_bdd_catalog.escript prod
rebar3 as prod release
```

The build helper writes `apps/damage/priv/bdd_step_catalog.term`; ensure that `priv` file is copied into the release and that the step modules are not rebuilt differently afterward. Re-run the helper for each release after changes to compiled steps. It does not start the Damage application or execute tests. It reads trusted compiler/module data.

By default the runtime reads `bdd_step_catalog.term` under `code:priv_dir(damage)`. An explicit location can be configured with a tuple:

```erlang
{bdd_catalog_manifest, "/trusted/release/path/bdd_step_catalog.term"}
```

The manifest must remain operator-controlled. Its executable-code MD5 is a version-consistency check, not a digital signature or protection against a malicious node operator. Both disk and loaded module versions must agree before signatures are used. Custom modules added after packaging require their own debug information or a freshly generated matching manifest.

Erlang primary reference: `beam_lib` documents abstract code, stripping and the executable-code redundancy check: https://www.erlang.org/doc/apps/stdlib/beam_lib.html

## Tests and release checklist

Run the shipped JavaScript tests:

```sh
node --test apps/damage/test/scripts/bdd_composer_model.test.mjs
node --check apps/damage/priv/static/js/bdd-composer-model.js
node --check apps/damage/priv/static/js/bdd-composer.js
node --check apps/damage/priv/static/js/main.js
node --check apps/damage/priv/static/js/lineNumbers.js
node --check apps/damage/priv/static/js/billing.js
```

Run the Chromium fixture tests with Python Playwright and a Chromium installation:

```sh
python3 apps/damage/test/scripts/bdd_composer_browser_test.py \
  --chromium /usr/bin/chromium \
  --out /tmp/damage-bdd-preview
```

The browser suite uses `page.set_content` and a simulated fetch implementation. It does not connect to a node. It tests prompt limits/controls, duplicate keyboard submission, no automatic editor replacement/execution, replace confirmation, undo, invalid/incomplete drafts, cancellation, stale validation, 503/401 recovery, text-only rendering of HTML-shaped output, step insertion, duplicate execution guarding, missing-ECAI fallback, responsive overflow, logical gutter alignment, and browser exceptions. Open the generated HTML for an interactive preview. Its simulated Run button never contacts a target.

The EUnit module contains 22 test functions covering extraction from compiler forms, exact matching, keyword restrictions, repeated variables, catch-all exclusion, round-trip filtering, docstrings, context placeholders, diagnostics, feature bounds, JSON schema, prompt intent preservation and a real egherkin parser integration test. These tests are supplied but not executed in this delivery.

Before production, run the full compile/EUnit and existing dashboard regression suite; then verify authenticated catalog responses, 401/403 handling, real ECAI output, cancellation/concurrency under load, post-reload catalog changes, stripped-release manifest matching, streaming output, IPFS selection, custodial and noncustodial execution, wallet/modals, navigation and logout/account changes. New stylesheet rules are scoped but shared shell/button styling can affect those preserved screens. No accessibility conformance certification is claimed; keyboard/focus/label improvements still need assistive-technology review.

## Example prompt

```text
Check that GET https://api.example.com/health returns HTTP 200 and JSON status is ok.
Use only available DamageBDD HTTP steps. Do not print the response body or add payments.
```

A corresponding feature using the uploaded HTTP step vocabulary is:

```gherkin
Feature: API health

  Scenario: Service reports healthy
    Given I am using server "https://api.example.com"
    When I make a GET request to "/health"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
```

This is an illustrative feature, not evidence that the example endpoint exists or has passed. Review generated behaviour before executing against an authorised target.
