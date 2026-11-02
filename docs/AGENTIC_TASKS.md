> **Accounting merge (2026-10-22):** Read [AGENT_ACCOUNTING.md](AGENT_ACCOUNTING.md)
> for the updated monetary lifecycle, API migration and missing-contract deployment
> gates. The Aeternity backend is disabled until reviewed and configured. The
> underlying capabilities below are unchanged unless noted there.

# Agentic tasks: integration and security contract

## 1. What this implements

A parent BDD feature can start a separate long-running task and return immediately.
The task survives the parent feature process and browser session. It asks a configured
LLM for one bounded proposal at a time. A server-owned template fixes available
capabilities, their argument schemas, prerequisites, approval requirements, limits
and the final verifier.

A task progresses through:

```text
queued -> planning -> policy validation
                      |-> waiting -> planning
                      |-> awaiting_approval -> executing
                      |-> executing -> evidence -> planning
                      `-> verifying -> completed
```

Side paths include `paused`, `interrupted`, `failed`, `exhausted`, `cancelled` and
`cancelled_unreconciled`. A `finish` proposal is only a request to invoke the configured
acceptance verifier. Failed read-only actions and failed acceptance gates can feed a
bounded failure observation back to the planner. There is no unbounded repair loop.

The built-in review and documentation templates verify artifact existence/integrity,
NOT the truth of every sentence. Their completion evidence explicitly says
`artifact_presence_and_integrity_only` and `semantic_correctness: not_established`.
The HTTP monitoring template checks concrete configured HTTP assertions.

## 2. Installation and routing

Apply the new-files patch first. The separate `damagebdd-agentic-wiring.patch` adds
only these two integration points against the available app/supervisor snapshots:

```erlang
%% damage_sup:init/1, in the Core child list:
damage_agent_sup:child_spec(),

%% damage_app:get_trails/0, in Handlers:
damage_agent_http,
```

If that wiring patch does not apply to the working branch, make those two additions
at the equivalent locations; do not replace the full application or supervisor files.
The top-level agent supervisor uses `one_for_all` across its checkpoint store, dynamic
job supervisor and coordinator. A service restart fences local task processes together. When no `agentic` configuration
exists, the child returns `ignore` and creates no state directory. Add configuration
before restarting the application to start the service. Once configured, the store
remains available when `enabled=false`, so existing records can still be inspected.

The existing `/static/[...]` route serves the added UI files. `/automated-tasks` is
an application-owned page; all task data endpoints require the existing DamageBDD
authentication plus the agent-owner allowlist. The HTML itself contains no task data.

Add a link to the real dashboard navigation:

```html
<a href="/automated-tasks">Automated tasks</a>
```

A link partial is supplied at
`apps/damage/priv/templates/ui/dashboard/agentic_link.mustache`. The current dashboard
shell/tab renderer was not available as an exact source snapshot, so no guessed
replacement of those files is included.

For an embedded panel, use the markup from `agent-tasks.html` and:

```javascript
import {mountAgentTasks} from '/static/js/agent-tasks.js';
const dispose = mountAgentTasks(panelElement, {
  authHeaders: () => existingAuthenticatedHeaders()
});
// Invoke dispose() on dashboard-tab teardown.
```

`existingAuthenticatedHeaders()` is your dashboard integration callback, not a new
provided API. The standalone page uses same-origin session cookies. The component
does not read or persist a bearer token in local storage. Polling is bounded and
non-overlapping within its refresh loop; the component aborts requests on teardown.

Ensure `steps_agentic` is included by the release's step discovery mechanism. The
available runner calls `damage_utils:loaded_steps()`, but its current implementation
was not supplied. A release that explicitly enumerates steps must add this module.
The new documentation snippet is in `priv/agentic/steps.yaml`; merge/regenerate the
site-wide step catalogue using the repository's existing mechanism.

## 3. Configuration and identity

Merge `config/agentic.config.sample` into the existing `damage` application settings.
Configuration uses tuple/proplist entries, not maps. The service is disabled until
`enabled` is explicitly true. Configure the exact external browser origin, including
scheme and non-default port. Cookie-authenticated writes require that origin and the
custom `X-Damage-Agent: 1` header. Non-browser clients must send a Bearer token plus
the custom header when Origin is absent. No permissive CORS policy is added.

`owners` is an explicit account allowlist. The model cannot select a different
owner, endpoint, provider, Erlang module, capability implementation, filesystem root,
verification suite, approval policy, or execution budget.

The Gherkin module reads the authenticated account from `Config`'s `public_key` and
requires it to agree with the context. It does not trust a mutable BDD variable as a
principal. All HTTP operations use the identity resolved by `damage_http:is_authorized/2`.
Ordinary in-VM Erlang callers remain trusted; BEAM processes are not a tenant sandbox.

A task pins the template/provider configuration hash and loaded implementation
identities. Configuration drift or a normal hot-code upgrade changes that identity
and is checked before dispatch under old approval. Quiesce tasks for code upgrades:
this is not an atomic code-loader lock across the check and the subsequent call. The loaded-code MD5 is an OTP identity
check, not a cryptographic attestation against a hostile node operator. The enclosing
policy hash uses SHA-256. A compromised host or VM is outside this boundary.

Disabling new task execution does not remove allowlisted owners' ability to inspect
or cancel existing tasks. It does not magically retract an operation already sent
to an external system.

## 4. Running a task

```gherkin
Feature: Supervised review
  Scenario: Launch a bounded review
    Given I use agent template "code-review"
    When I start an agent task named "review" with objective
      """
      Review the configured source snapshot for correctness and failure handling.
      Produce review.md with file references, evidence, uncertainty and recommended
      checks. Do not apply changes or claim that unrun tests passed.
      """
    Then the agent task "review" should be accepted
    And the agent task "review" should have learning evidence
```

The last two steps prove acceptance and an audit trail, not task completion. Use the
API/dashboard for asynchronous progress. An optional join is bounded to 60 seconds:

```gherkin
When I await agent task "review" for "30" seconds
Then the agent task "review" should be "completed"
```

No Gherkin step grants approval. A task cannot approve its own request through the
provided step module or the private BDD verification lane. Do not expose a management
API credential through a custom action, since that would defeat the separation.

The step context stores only handles, state summaries and an evidence-head hash. It
does not copy private source, plans or artifacts into the parent run's potentially
public reports. The goal docstring itself is still ordinary parent feature input:
do not put credentials in it.

## 5. Proposal format

The provider returns a map or JSON object of exactly this shape:

```json
{
  "op": "act",
  "skill": "write_review",
  "args": {"content": "# Review\n..."},
  "seconds": 0,
  "summary": "Produce the review from the observed source snapshot."
}
```

`op` is `act`, `wait`, or `finish`. For `wait` and `finish`, `skill` must be empty and
`args` must be `{}`. A wait must have a positive bounded `seconds`; other proposals
must use zero. Unknown fields, skills, argument names, invalid types, oversized text
or missing prerequisites are rejected. There is no markdown-fence recovery or
free-text-to-executable-code fallback.

Ollama JSON schema output is a convenience, not an authorization mechanism. The
server independently validates every proposal. Another provider can implement:

```erlang
next(RequestMap, ProviderOptions) ->
    {ok, ProposalMap, #{<<"model">> => ModelId,
                       <<"prompt_tokens">> => InputTokens,
                       <<"output_tokens">> => OutputTokens}}
    | {error, ReasonAtom}.
```

Provider/module configuration is operator-only. Only declared source observations,
prior bounded results, the objective, capability descriptions and required actions
enter the prompt. Account secrets and the complete BDD context are not copied in.
The provider does not request or retain hidden model reasoning; it records a short
proposal summary and observable inputs/outputs.

## 6. Capability boundary

### Source and artifact capabilities

The source capability reads only explicitly configured relative files from a trusted
snapshot root. It rejects traversal, absolute paths and symlink ancestors, limits
file counts and total bytes, and records file SHA-256 values. It does not run Git,
shell commands, repository hooks, test code, or model-provided filenames.

**Use immutable, operator-prepared, read-only snapshots.** The file checks are not an
`openat2`/filesystem sandbox and do not protect against another process with authority
to replace the snapshot concurrently. File hashes identify observed bytes, not an
assertion that an entire repository was reviewed or that a commit is unchanged.
Secrets in an allowlisted source file are still secrets: review inputs before enabling
an external provider. Redaction cannot guarantee discovery of every embedded secret.

An artifact action stores model-authored content in the private task record, using
an operator-fixed artifact name. It does not edit the repository. Review.md,
explanation.md and documentation.md are generated artifacts, not committed changes.

### Private HTTP BDD verification lane

`damage_agent_bdd` supports the existing egherkin feature/scenario/background AST,
`damage_context:render_body_args/2`, and `steps_http:step/6`. It gives each scenario a
fresh context. It accepts only configured feature text; model arguments cannot alter
that feature. Unsupported ASTs and unknown step clauses fail closed. At least one
literal Then is required in each scenario, and supported Then assertions are explicit
status, response-text, JSON-path and JSON-equality checks. Printing a response is not
an acceptance assertion. TLS-certificate verification cannot be disabled here.

Read capabilities reject the current HTTP mutation request step forms. Native HTTP
verification runs in a separate bounded BEAM worker on the Damage node; it is NOT an
OS sandbox. GET requests can still have unintended server effects on a badly designed
endpoint, so configured targets remain operator responsibilities.

This intentionally does not call the ordinary `damage:execute_data/3` paid/public
pipeline. It does not expand the account context, invoke the ordinary per-step DAMAGE
debit, or upload private reports to IPFS. The surrounding agent task now accounts
for these invocations using its reserved ceiling and fixed admission tariffs. It is a restricted private verification lane, not a drop-in
replacement for every existing feature, browser step or full run-report pipeline.
Actual parser/step compatibility must be checked against the deployed monorepo.

### Trusted extension adapters

No repository-mutation adapter is shipped. A reviewed, node-installed adapter can
implement the following contract and be selected by a template:

```erlang
execute(ArgsMap, Ticket, OperatorOptions) ->
    {ok, #{<<"observation">> => PublicObservation,
           <<"evidence">> => PublicEvidence}}
    | {error, ReasonAtom}.

verify(#{artifacts := Artifacts, evidence := Observations,
         source_hashes := Sources}, Ticket, OperatorOptions) ->
    {ok, #{<<"observation">> => VerificationSummary,
           <<"evidence">> => VerificationEvidence}}
    | {error, ReasonAtom}.
```

Result maps must contain bounded JSON values with binary keys. An optional `artifact`
map contains binary `name` and `content`; optional `sources` contains source identity
records. `ok` means the adapter observed its actual success condition; it must never
convert unknown or failed external status into success. Verifiers must be read-only.
Do not return credentials or unfiltered provider error bodies. Adapters are trusted
code and can defeat the policy if implemented incorrectly.

The ticket includes task ID, authenticated owner, policy hash, deadline and a durable
idempotency key. For isolated-write operations, `approval=false` can be explicitly
configured after review. `external_write` always requires exact-proposal approval.
The argument schema is operator-owned, with text limits, enumerations, integer ranges
and booleans; all keys are required and extra keys are rejected.

For code/document evolution, implement the write adapter on a separate least-privilege
executor. Use an immutable base revision and isolated worktree/container; no host
checkout, SSH agent, wallet secrets, Docker socket, privileged mode, or broad egress.
Validate changed paths and sizes, forbid changes to the verifier/policy/protected
checks, and bind approval and results to the exact candidate digest and base revision.
Run fixed compile/tests/BDD/regression checks outside the model's control. Never treat
an LLM's test summary as execution evidence. A worktree alone is not a sandbox.

Publishing a branch/PR or deploying is a separate external-write capability. Do not
let a passing format check grant merge/deploy rights. Integrate billing/reservations
and deployment-specific rollback/reconciliation before granting those capabilities.

## 7. Persistence, cancellation and approvals

The store writes and `dets:sync`s a single record containing the latest checkpoint
and hash-linked history before dispatching an effect. Task submission is idempotent
per `{owner, request_id}`: identical input returns the task; different input conflicts.

The store is node-local and single-writer. Do not share its DETS file across nodes.
Back up the private directory with restrictive permissions. History is bounded by
configured task/call limits but there is no automatic retention/deletion API in this
version. At `max_saved_tasks`, new admission stops rather than discarding evidence.
Plan an operator-controlled archival/retention process before increasing quotas.

Learning exports read the checkpoint and event history atomically from the same
store record, including while the task is running.

The event hash chain checks internal consistency. It is not an immutable ledger,
cryptographic signer, or protection from someone who can rewrite the entire store.
Externally sign/anchor selected heads using a separately authorised publishing path
for independent tamper evidence. The canonical encoding is project-specific, not a
claim of RFC 8785 compliance.

On restart, unfinished active tasks generally become interrupted rather than silently repeating
action dispatch. Clean paused tasks stay paused. Durably confirmed accounting results can advance
only to a not-yet-intended receipt write or terminal checkpoint; uncertain writes
require read-only reconciliation, as specified in AGENT_ACCOUNTING.md. Interrupted planning can be explicitly
resumed under unchanged policy and remaining budgets. Interrupted executing/verifying
tasks require external reconciliation; generic resume is refused. This version does
not include a universal reconciliation/mark-resolved endpoint. Preserve the old record
and create a new bounded task after the operator/adapter establishes external state.

Pause is cooperative at operation boundaries. Cancel kills the local operation worker
and stops orchestration, but cannot retract an HTTP request, undo a Git push or recover
money already spent. Cancellation during execution/verifying is recorded as
`cancelled_unreconciled`; it is not a claim of successful rollback. Late results cannot
resume the cancelled task. A downstream effect needs its own idempotency enforcement
and reconciliation protocol. Exactly-once external execution is NOT promised.

Approval binds the authenticated owner, task, iteration, policy/code identity and exact
proposal hash. It expires and is consumed by dispatch. Repeated or stale approval is
rejected. A task's model cannot grant itself more iterations, time or privileges.

Limits cover task count, persisted record count, iterations, model calls, wall time,
operation time, wait duration and data sizes. Provider-reported tokens are provenance,
not measured billing evidence. The surrounding task now reserves an integer DAMAGE
ceiling and books fixed admission tariffs; see AGENT_ACCOUNTING.md. AE gas and
external provider bills remain separate, and upstream billing can continue after
local cancellation. The actual treasury must enforce concurrent reservations.

## 8. HTTP API

All paths below require existing DamageBDD authentication and an allowlisted owner.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/agents/templates` | Available server-approved templates |
| POST | `/api/agents/tasks` | Create a task; body has exactly `template`, `goal` |
| GET | `/api/agents/tasks` | Account-scoped summaries |
| GET | `/api/agents/tasks/:id` | Task status and exact pending proposal |
| GET | `/api/agents/tasks/:id/events` | Private audit events |
| POST | `/api/agents/tasks/:id/command` | pause, resume, cancel, approve, reject or accounting reconcile |
| GET | `/api/agents/tasks/:id/learning` | Private candidate-evidence JSON export |

Creation requires `Idempotency-Key`. All writes require `X-Damage-Agent: 1` and the
appropriate Origin/Bearer protection described above. Ownership mismatch returns
not-found. Responses use no-store and model text is rendered with textContent, not
interpreted as HTML/Markdown.

```sh
curl --fail-with-body "$DAMAGE_URL/api/agents/tasks" \
  -H "Authorization: Bearer $DAMAGE_TOKEN" \
  -H 'X-Damage-Agent: 1' \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $REQUEST_ID" \
  --data '{"template":"code-review","goal":"Review the configured source snapshot and produce review.md without applying changes."}'
```

Use a fresh random request ID for a new logical task and preserve it across transport
retries. An accepted response is not a completion result.

## 9. ECAI-facing evidence

The export schema is `damage.agent.experience.v1`. It includes objective, policy/code
identity, model metadata, exact proposals, action outputs, source byte hashes,
acceptance results, artifact content and an auditable event sequence. It also includes
the final checkpoint so the final snapshot checksum can be checked with
`damage_agent_store:verify/1` after appropriate key normalization.

Every export is explicitly marked `training_eligible=false`. It is a candidate
evidence bundle, NOT a claim of compatibility with the current native ECAI bundle
importer. No ECAI ingestion, index refresh or training call is made automatically.
The supplied ECAI material shows existing learning/repair services, but an exact
current native import schema/API was not available to implement against safely.

A deployment-specific ECAI promotion adapter should check the chain, source/candidate
identity, license/consent, secret policy, verifier identity and actual acceptance
scope; deduplicate by source/candidate/check hashes; and preserve failed attempts
as failures. Split evaluation by source/repository lineage rather than nearly
identical patches. Do not label model-authored reviews as correct merely because a
file exists. A passing test suite is evidence about those tests, not universal
correctness. Failed tests are useful repair evidence, not positive training examples.

No public IPFS publication is automatic. Source, reviews, goals and artifact contents
may be confidential. Export and promotion need the account's explicit authority.

## 10. Verification and deployment gate

Run the commands in README.agentic.md. The EUnit suite uses deterministic fake
providers/adapters and no LLM credentials. It exercises ownership, submission
idempotency, evidence consistency, unknown-skill rejection, early-finish rejection,
exact/one-shot approval, uncertain cancellation, provider timeout, dry-run behaviour,
policy changes, type-preserving policy hashes, idempotent pause, bounded waiting
and non-replaying restart recovery.

The Node tests cover pure control-state logic and selected source contracts, not a
real browser or complete accessibility test. The Python checks cover lexical delimiter
balance and static integration properties, not Erlang compilation or security proof.

Before production, additionally run authenticated Cowboy integration tests, the real
egherkin/steps_http feature fixture, a local provider request, disk-full and abrupt
node-death tests, cross-account probes, body/quota exhaustion tests, snapshot-race
probes, and any isolated executor's own adversarial test suite. Load test and establish
retention. Keep external-write capabilities disabled until their idempotency,
reconciliation, financial limits and independent acceptance gates are demonstrated.
