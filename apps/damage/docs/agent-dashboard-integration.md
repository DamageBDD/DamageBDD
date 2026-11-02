# Integrated Agents workspace and BDD authoring routing

## Scope and source basis

This change is based on the supplied `latest-damage.tar.gz` and `latest-ecai.tar.gz` snapshots, not a fetched upstream revision. Archive SHA-256 values:

- Damage: `f53c7f7e4b1e59cc92076894734b2d74fed1f8fae80c46634ed159fe1132f7fd`
- ECAI: `26b3e51ac9c9a8eef9968cb5a42a955a686f56cfca5da68afa19afd3c38b19b8`

The temporary review repository baseline is `41f5eb2a704a70e428db054e36757d9a6ef97fee`. That is a local snapshot identifier, not a project release SHA.

The standalone `/automated-tasks` handler and its HTML/bootstrap/CSS assets are removed. DamageBDD gets an authenticated Agents navigation item (`#agents-tab`); the ECAI console gets an Agents view (`#agents`). Both render the same Damage-owned component and use the same account-scoped agent service. They do not create separate queues or stores.

The change manages **tasks under existing operator-approved agent templates**. It does not add an on-chain agent-registration, funding, contract deployment, arbitrary-tool creation, auto-merge or deployment wizard. Existing agent identity provisioning and treasury prerequisites remain operator tasks.

## Focused workflow

### 1. Describe

Enter an objective or choose Review code, Explain a review, Draft documentation, or Monitor behaviour. Choose an approved template, or let the model suggest one from the server-provided list. The examples are prompts, not grants of capability: unsupported requests must be revised or handled by another operator-approved template.

`Draft agent BDD` requests an advisory draft. `Review without AI` uses the selected template directly and incurs no drafting-model call. The shared authoring service permits one active request per principal, within its existing node-wide concurrency and generation deadline. Both composers share this limit. Cancel stops waiting and requests cancellation; it does not guarantee that a remote provider will not charge for a request already sent.

### 2. Review

The review includes the editable objective, canonical launch Gherkin, allowed actions, approval requirements, runtime limits, verification scope, fixed task ceiling, and static signature diagnostics. The model returns only a template ID, objective, assumptions and unsupported requirements. The server constructs the launch feature; the model cannot submit a shell command, Erlang module, arbitrary executable feature, credential, budget or permission change through this draft schema.

Edits invalidate the start consent and feature export until checked again. Rechecking an unchanged model draft preserves its unsupported-requirement warnings rather than clearing them. Static signature validity does not establish semantic correctness or guarantee that the future task will succeed.

`Start reviewed task` requires explicit consent and sends the current objective, template ID, reviewed policy hash and an idempotency key. The service rechecks the hash before admission. A changed policy requires another review. An uncertain HTTP response retains the same key for an unchanged retry; it is not treated as confirmed acceptance.

Exported `.feature` text is a reusable launch description, not a signed approval or frozen policy. Running that file later re-resolves the then-current template through the existing BDD steps. The hash check applies to dashboard task admission; the export does not add a new policy-pinning step.

### 3. Follow

The task list has All, Needs attention, Active and Finished filters. A selected task shows execution and accounting state separately, booked/remaining base units, receipt state, latest artifacts, activity and raw evidence. Pending approvals display the exact proposal and bind commands to its hash. Uncertain accounting exposes reconciliation rather than a misleading resume/retry button.

Cancellation is not rollback. The existing accounting adapter's reconciliation limitations remain unchanged. An exported ECAI experience is private candidate evidence; this UI never automatically imports, indexes, trains on, publishes or promotes it into accepted knowledge.

Only a visible, authorised workspace polls tasks. Account changes abort outstanding local requests and clear private objectives, approvals, artifacts and evidence. Late responses cannot repopulate the previous account's state. Provider-control event listeners last until component disposal; cancelling requests or changing accounts does not remove the controls themselves.

## Review of the existing BDD composer

The uploaded `damage_bdd_generator.erl` called `ecai_ollama_client:generate_json/2` directly. That client path did not obtain a lease through `ecai_ollama_pool` and did not apply its provider/role/model selection. Changing the ECAI provider registry therefore was not the same thing as changing this composer route.

The uploaded composer already had useful boundaries: a deployed-step catalog, server-side signature validation, advisory code-learning cards, bounded generation and a limited repair attempt, cancellation, and separate manual editing/validation/execution controls. These are retained. The frontend also retains the existing editor/source-load behaviour and run controls.

Now both ordinary BDD generation and agent drafting call `damage_bdd_inference`, which obtains an authoring preference from `ecai_llm_settings` and calls:

```erlang
ecai_ollama_pool:generate_json(bdd, Prompt, Options)
```

There is no direct-client fallback. The ordinary composer still has at most one validation-guided repair, inside its original deadline. A repair is a second inference request, not free computation. Its provider/model preference is kept for that generation; active connection eligibility is enforced by the pool at each lease. This is not a claim that a complete provider registry snapshot is atomically frozen across multiple requests.

## LLM policy and routing

### Configure the authoring provider

Open **Drafting model** in the DamageBDD verification composer or either Agents panel. ECAI also shows this control under **AI providers & roles**.

An authorised node administrator can save a node-wide provider filter (Automatic, Ollama, OpenAI or Claude/Anthropic) and optional model ID. These are the provider adapters already present in the supplied ECAI source. Model IDs are entered explicitly; no presumed current commercial model names are baked in.

Automatic uses the existing pool's eligible `bdd` connections. A blank model uses the connection's default. An explicit provider/model is a filter, not a fallback list. If nothing eligible is available, generation fails instead of silently using a different provider. The control lists configured enabled BDD connections, not a guarantee of current health, capacity or model availability.

Create connections, set credentials, assign the `bdd` role, and grant remote-role consent in the existing **ECAI → AI providers & roles** UI first. A remote provider must satisfy that existing registry policy. Choosing it here cannot add an endpoint, grant remote access, set a key or enable a connection.

Saving uses the registry revision, persistence and pool-reconfiguration path. Stale saves return 409 and require refresh. Full saves from the existing provider UI preserve `bdd_route` when they omit it. Settings changes apply to future leases; existing operations are not silently replaced.

### Boundaries retained

| Boundary | Effect in this change |
| --- | --- |
| Registry destination/credential rules | Existing `ecai_llm_settings` validation and server-side credential resolution are retained. |
| Role/health/model/capacity | Pool selection still decides whether a connection is eligible for `bdd`. |
| Remote processing | Existing explicit remote-role consent remains required. Prompt and advisory code knowledge can leave the node when permitted. |
| Limits | Authoring requests tighten timeout/connect/output/response limits; they cannot raise configured node caps. |
| Retry/billing uncertainty | Authoring sets one pool attempt. Existing inference receipts and uncertainty handling apply; a repair or a new user submission is a distinct request. |
| Incomplete output | Incomplete OpenAI output and known truncation outcomes are rejected; schema/signature checks remain independent. |
| Metadata | The UI receives filtered provider/model/node/receipt/revision metadata, not endpoint URLs, credentials or private headers. |

**Authoring route is not runtime planner configuration.** `damage_agent_llm_ollama` and the existing operator-selected agent provider remain unchanged. Changing the drafting route does not rewrite an agent template, alter a running task, or enable its tools. Other Damage AI profiles continue to use their existing routing options. ECAI Model Internals remains scoped to its existing code roles (`patch`, `learning`, `audit`, `synthesis`); this change does not extend it to `bdd`.

Draft-provider charges, runtime-provider charges and AE gas are not all capped by the existing DAMAGE task ceiling. The task's configured fixed admission tariffs remain separate from external provider invoices. The UI makes this distinction explicit. Drafting is not represented as free merely because no task has started.

## Authentication review

The supplied `damage_http:is_authorized/2` can fall back to the execution endpoint's L402 challenge. Reusing it for authoring/agent control risks generating payment challenges during UI login failures and treating a paid shared L402 identity as an agent account.

The new `damage_bdd_access` helper requires the existing browser/cookie/bearer `access_token` credential class and delegates validation to `damage_auth:require_auth`, retaining wallet policy enforcement. Missing/invalid credentials receive normal unauthorised responses; no L402 invoice is created by these endpoints. L402 and Nostr credential classes do not gain authoring or agent-management access through this helper. This is an intentional compatibility change for those API callers, not a modification of the paid execution endpoint.

Agent access still requires the operator owner allowlist and permitted template. An authenticated account outside the agent allowlist receives 403, not a 401 that would make the ECAI request helper log out a valid session. Wallet-only sessions can use the existing ordinary BDD authoring APIs and read redacted routing; they cannot change routing or manage custodial agent tasks.

Authoring-route changes require the existing ECAI code-admin policy, a node-admin authenticated session, matching explicit bearer identity, JSON and a custom header. Cookie-only route mutation is denied. Ordinary users can see only the redacted route/configured BDD connection summary. The change does not introduce public CORS.

## Deployment

Apply this patch directly to a repository matching the two latest uploaded snapshots. It already includes agent supervisor/router wiring missing from those snapshots. Do not also apply the older standalone-page wiring patches.

The agent child spec is appended after existing core services. Its existing `start_link/0` returns `ignore` when no nonempty `damage.agentic` configuration exists, so merely adding the wiring does not create a state directory in an unconfigured release. Once configured, storage remains available for inspection even with new execution disabled.

ECAI's supplied application dependency list includes Damage. Both dashboards must use the same node/services for a shared queue. The ECAI listener registers the shared APIs and only the specific shared static assets; relative requests remain on their own listener. This is not a proxy between separately deployed nodes.

Merge the browser origins into your existing **tuple-based** agent configuration; do not replace the rest of the owner, template, storage and accounting configuration:

```erlang
%% Inside the existing {damage, [... {agentic, [...]} ...]}:
{origin, <<"https://damage.example">>},
{origins, [<<"https://damage.example">>, <<"https://ecai.example">>]}
```

Include the actual scheme and port where applicable; do not include a trailing path. These placeholder domains are examples, not recommended deployment destinations. They allow same-origin requests presented on either configured dashboard listener; they do not turn on cross-origin browser access.

For route administration, retain the existing `damage.node_admins`, ECAI `code_admin_enabled`, and optional intersecting `code_admin_accounts` configuration. The separate agent `owners` allowlist still applies. Configure the execution planner and verified accounting contracts separately.

Build both applications and restart the release so new routes/supervisor children are installed. Retain deployed BEAM debug info or regenerate the matching authoritative BDD manifest before stripping releases. Hot-loading a new handler module alone does not rebuild Cowboy dispatch or add a supervisor child.

Agent policies include implementation fingerprints. Updating `damage_agent_policy` can invalidate a previously captured task policy. Drain or explicitly inspect active tasks before upgrading; do not bypass policy checks or blindly resume unknown accounting operations. Budget/settlement/Sophia code is not changed by this patch.

Remove the deleted standalone assets from installed releases, not just from source. `/automated-tasks` is no longer a supported UI route. Preserve the existing private task store. Back up persisted provider settings before deployment; older binaries may not understand the new optional `bdd_route` field, so a binary-only downgrade is not a safe rollback plan.

## Verification

See `agent-dashboard-validation.md` for executed tests, fixture limitations and the required local Erlang checks. Passing browser/static tests does not establish live authentication, provider billing, contract validity or production readiness.

### Older root-level static checker

The earlier supplied `scripts/check_agentic.py` still expected the standalone HTML and the old authentication delegation. That root-level script was not included in the latest app archives. An optional companion patch, `damagebdd-agents-dashboard-legacy-checker.patch`, updates those two checks against the previously supplied scope-fixed script. Apply it only where that earlier script is installed; the main dashboard patch does not invent a new baseline for an absent root file. Its other tests and the separate accounting checker remain unchanged. The two changed checks passed against this integrated source tree; the entire legacy script was not rerun because its root configuration file was not present in these app-only snapshots.
