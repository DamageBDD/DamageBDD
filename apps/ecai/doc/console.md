# ECAI console — dashboard integration

The main ECAI dashboard (`GET /`, unless `default_page` is overridden) now renders
`priv/templates/ui/dashboard/ecai_console.mustache`. The console is always
available at **`GET /dashboard`** even if the default home page is changed.
The previous search screen remains at `/search`; `/chat`, `/indexer`, and
`/indexer/advanced` remain available; the indexer and chat pages are linked from the sidebar.

The console uses plain HTML, CSS, and JavaScript. All requests use existing
same-origin Cowboy routes and DamageBDD account authentication. No build step,
CDN, or JavaScript framework is required.

## Dashboard map

| Area | APIs and controls |
| --- | --- |
| Overview | `/ecai/chat` health, `/ecai/index-jobs/status`, `/yelp/status`, active jobs |
| Knowledge search | `POST /ecai/search`, record and proof inspection |
| Conversation | `GET/POST /ecai/chat`, separate per-tab chat session |
| Index jobs | `/ecai/index-jobs` collection, status, presets, job details, pause/resume/cancel/retry, artifacts, authenticated SSE events |
| Wikimedia | `/ecai/wikimedia/{sources,plan,search,doctor}` |
| Knowledge & privacy | `POST /ecai/ekef`, owner-scoped `/ecai/private/:corpus/{index,search,fetch,ask}` |
| Marketplace (experimental) | `/ecai/market/jobs` plus publish/get/claim/submit/pay, **disabled by default** |
| Code learning & repair (node admin) | `/ecai/admin/code/{status,repairs,learn,scan,propose,integrate,reviews}`, `/ecai/admin/code/reviews/:id/{approve,reject,publish}` with immutable approval and origin review-branch gate |
| Operations | `/yelp/{status,chunk_job,chunk,chunk_async,chunk_cancel,assign,ipfs,headers,manifest}`, `/ecai/ws/` |
| API explorer | Form-based, path/query/body-aware HTTP runner, idempotency keys, SSE/WebSocket links |

Endpoint entries document their request shape; optional routes return an error
when not enabled or when their dependent service is down. HTTP failures and
structured error responses are shown rather than silently suppressed.

## Expandable job progress & event tracking

The index-job list uses native `<details>`/`<summary>` accordion entries. Every
collapsed entry shows its last persisted state, count, percentage and available
ETA. Opening an entry loads full job details and automatically opens the
**authenticated** `/ecai/index-jobs/:id/events?after_seq=N` stream. The first
subscription replays up to 16 recent persisted events, then follows live
checkpoints. The UI labels the stream as connected, interrupted, reconnecting,
or completed rather than pretending every state is live.

Only one row is open and tracked at a time. Closing it, leaving the Index jobs
view, signing out, switching to another job, or hiding the browser tab aborts
the fetch and its pending retry timer. Unexpected stream drops reconnect with
bounded exponential backoff using the last observed event sequence; HTTP
401/402/403/404 failures are displayed and not automatically retried. Terminal
jobs show their saved event history without attempting to monitor finished work.

The 12-second queue refresh **reconciles rows by job ID** instead of rebuilding
the list, keeping an open panel and its event log intact. Event sequence
numbers prevent a stale list poll or older replayed events from rewinding
progress. Existing pause, resume, cancel, retry, artifact and raw-JSON
inspection remain available inside each expanded job. No frontend framework
or chart library is required.

### Resume canceled jobs from a durable checkpoint

`POST /ecai/index-jobs/:id/retry` **requeues a canceled job** with its original
job ID and persisted checkpoint. The next worker reads that checkpoint and
replays only the current adapter work unit when required for correctness.
If no checkpoint has been written, the UI says **Restart job** rather than
claiming progress can be resumed. Cancellation does not use up the configured
`max_retries` failure budget; `failed` jobs still honor that budget. A retry
is rejected while the job is already pending/running or when queue capacity is
exhausted (`429`). Successful retry responds `202` with the queued job.

The resumed job's state transition is durably logged before scheduling. Old
throughput and ETA are discarded; completed/total counters remain visible
until the adapter publishes updated progress. Historical `canceled` and
`failed` events remain auditable but do not prematurely end a new live SSE
stream after requeueing the same job ID. The expanded UI resumes SSE tracking
at the accepted transition without replaying the old terminal event.

### Runtime telemetry and ETA quality

The queue status response includes `runtime_schema = ecai-index-jobs-telemetry/v2`
and `canceled_checkpoint_retry = true`. If these fields are missing on the
production node, it is serving an older `ecai_index_jobs_srv` BEAM. Check the
loaded location with `code:which(ecai_index_jobs_srv).` and restart the ECAI
job supervision/application after deploying (a hot module reload does not
migrate an already running gen_server record safely).

Every job snapshot exposes `runtime`: wall time since the job was created
(including queue and pauses), accumulated active worker time across attempts,
current-attempt time, first start, and time since the last progress event. The
expanded job detail also exposes `resources`, sampled from Erlang
`process_info/2`: BEAM worker memory bytes, heap/stack words, mailbox depth,
GC counts and scheduler reductions (including the change in reductions per
second between successive detail polls). **Reductions are not CPU utilization
percentages**, and these counters do not cover external decompressor/OS
processes. They are not included in events or historic completed jobs.

The dashboard polls the *open, active* job detail every seven seconds to
obtain process counters. The three duration clocks advance locally between
samples without another network request; stopping or closing the job disables
that polling. The full list continues to use the existing 12-second queue
poll. No privileged node-wide diagnostic endpoints or third-party libraries
are required.

ETA is now a **provisional** phase-rate extrapolation rather than a guaranteed
finish time. It is withheld until a single phase has produced at least three
additional completed-work observations, four net units and 15 seconds of
measurement. It resets on phase or worker-attempt changes, disappears after
120 seconds without an update, and is always cleared for stopped jobs. The
`progress.eta_status` field describes `warming_up`, `provisional`, `stale`,
`unavailable`, or `complete`. Wikimedia workload units have uneven costs
across phases; operators should treat even a provisional ETA as approximate.

For old durable job records, active time may be derived from the legacy start
and finish timestamps and carries `runtime.active_time_estimated = true`.
New worker attempts accumulate precise per-attempt BEAM wall-clock duration
at durable transitions and preserve it through pause, retry and restart.

## Authentication and privacy

The Sign in dialog posts to `/accounts/auth/` on the *ECAI listener*. The
ECAI router now mounts only the existing `damage_accounts` login and logout
handlers at `/accounts/auth/` and `/accounts/logout`. The ECAI application
already depends on the `damage` application; no second password database,
OAuth service, or cross-origin credential POST is introduced. This avoids a
404 when `ecai.damagebdd.com` is routed to the ECAI port (default 9003)
instead of the DamageBDD HTTP port.

`GET /ecai/auth/session` is a read-only, no-store probe using
`damage_auth:authenticate/2`. It returns only `authenticated`, `public_key`,
and `node_admin`, never secrets or tokens, and **does not generate an L402
invoice**. The UI probes it before reading protected `/ecai/index-jobs/*`
endpoints. A 402 on the protected endpoint is displayed as an access/payment
challenge, not silently treated as a network failure. No payments are made
automatically.

Authenticated REST requests pass the Bearer token and include same-origin
cookies. When available, the existing `sidekick.js` `TokenManager` is also
notified; no alternative account authority or anonymous fallback is added.
The client never stores private-corpus responses in persistent storage. The
`/ecai/private/...` service derives the corpus owner from server-side
`damage_auth` state, and the console rejects user-supplied key/owner/provider
fields.

**Important security boundaries**:

- Browser login checks and confirmation dialogs are *not server-side access
  controls*. The existing `/yelp/*` Cowboy handler does not independently
  authenticate mutating requests. **Keep Yelp admin routes private behind an
  authenticated reverse proxy or loopback-only binding** until server-side
  authorization and admin roles are implemented. Never expose them publicly
  merely because the console requires a login.
- `/ecai/chat` is currently public and takes a caller-supplied `user_id`;
  avoid sensitive conversation data until chat ownership is verified server-side.
- `/ecai/ekef` performs an actual on-chain NFT minting operation, **not** just
  deterministic local encoding. It requires a trusted, server-side `ae_account`
  keypair in the authenticated state; the handler returns
  `server_signer_unavailable` otherwise. Do not send signing keys through the UI.
- The `/v1/chat/completions` adapter accepts OpenAI-style `messages` (or legacy
  `message`), isolates ECAI chat memory by the authenticated account, and
  returns a basic nonstreaming `chat.completion` response. It is not a full
  OpenAI API implementation. `/ecai/chat` is the interactive console route.

## Code learning & repair: node administrator review queue

The **Code learning & repair** navigation item is visible to an authenticated
DamageBDD node administrator even if the privileged ECAI API is unavailable.
The panel then shows actionable 404/403/402/503 diagnostics rather than hiding
the navigation. Actual learning, scan, review and publication actions are still
disabled until `GET /ecai/admin/code/status` succeeds. A visible menu **does
not grant any privileged server permission**. Routes and the durable review
queue worker are disabled by default and require an ECAI restart on enablement.

DamageBDD authentication and `damage.node_admins` in `sys.config` own the
administrator role. The `ecai.code_admin_accounts = []` default admits all
DamageBDD node administrators *when* `code_admin_enabled=true`; a nonempty
list further restricts access to the intersection of the lists. An account
listed only in the ECAI allowlist is **never** elevated to node admin.
The ID must match `damage_auth:authenticated_account/1`, not a client-supplied
`owner` or an email address. Two **different** node-admin accounts are needed
to complete an approve + publish cycle: the publisher cannot be an approving
reviewer.

`GET /ecai/auth/session` returns `node_admin`, `code_admin` and
`code_admin_enabled` flags from the server without an L402 challenge. The
browser uses the node role for menu visibility, not for security decisions.

To enable access, add `{code_admin_enabled, true}` and
`{code_admin_accounts, []}` under the **ecai** application section of your
`sys.config` and restart the node. Keep `{code_review_push_enabled, false}`
until publishing is deliberately authorized. Restarting is required because
the Cowboy admin routes and DETS review queue worker are only created during
ECAI startup. Verify from the Erlang shell:

```erlang
application:get_env(ecai, code_admin_enabled).
application:get_env(damage, node_admins).
whereis(ecai_code_review_queue).
ecai_app:reload_router(). %% only after enabled and worker exists
```
For stronger segregation configure `code_review_required_approvals = 2` and
provision at least three node admins.

```erlang
{ecai, [
    {code_security_enabled, true},
    {code_admin_enabled, true},
    {code_admin_accounts, [<<"ak_REVIEWER_ACCOUNT">>, <<"ak_PUBLISHER_ACCOUNT">>]},
    {code_review_repo_root, "/home/damage/DamageInc/DamageBDD"},
    {code_review_required_approvals, 1},
    {code_review_push_enabled, false},
    {code_review_run_eunit, true},
    {code_review_run_ct, false},
    {code_review_verify_timeout_ms, 600000}
]}.
```

Keep `code_review_push_enabled = false` until repository validation, server
identity, remote access, and the approval process are verified. Explicitly
switch it to `true` to enable the final publish action and restart the node
(or ensure configuration is reloaded). Configure the Git `origin` remote with
a **least-privilege deploy key** that can create `ecai/reviews/*` branches but
cannot rewrite protected default branches. Publication never force-pushes or
merges `main`/`master`.

### Workflow

1. Trigger code learning, the repair scan, a targeted `propose` for an
   existing `(application,module,fingerprint)` finding, or integration validation. These
   are requests to the existing asynchronous ECAI worker processes, not a
   second repair engine.
2. `GET /ecai/admin/code/repairs` summarizes the persisted repair history;
   `GET /ecai/admin/code/reviews` imports only **validated** repair records.
   Each review is pinned to patch bytes, SHA-256, finding version, and Git
   base commit. Import and decisions are journalled to DETS.
3. Review the exact unified diff and verification metadata. Approve with
   written findings, or reject. Approval count and distinct approvers are
   enforced server-side. Regenerating a repair never silently modifies an
   already reviewed patch. Rejected reviews cannot be published.
4. A **different** authenticated administrator explicitly submits a publish
   request including the pinned SHA, review revision, and the exact phrase
   `push to origin`. The server also checks the reviewed repair is still the
   current validated repair and that HEAD matches the pinned base commit.
5. Publication runs isolated Git patch verification (compile + EUnit by
   default), commits the patch using a service identity in a throwaway detached
   worktree, and pushes to `origin` as `refs/heads/ecai/reviews/<review-id>`.
   The commit includes the pinned patch hash, base commit and review branch
   as provenance trailers. Review the branch in your Git hosting provider
   and merge through your normal protected-branch process. The live working
   tree is not modified.
6. Results are journalled as `published`, `publish_failed`, or
   `reconcile_required`. An interrupted or uncertain push is **never**
   automatically retried. Inspect the remote branch before manual remediation.

State file: `<state_root>/dets/code_review_queue.dets`. Frozen patch files:
`<state_root>/git/security/reviews/<review-id>.patch`. Restarted processes
recover interrupted publish state, but no automatic remote side effects occur.

**Deployment security:** All routes require DamageBDD authentication and
explicit node-admin membership. Mutations additionally require a Bearer
Authorization header, not merely an ambient cookie. Do not expose these routes
through an unauthenticated reverse proxy. Run the verifier in a restricted
build environment because compiler scripts and tests from a proposed patch
may execute arbitrary code. A verified patch is not a proof of correctness;
continue human review and protected-branch CI after publication.

**Limitations:** The interface uses a configured account-ID allowlist rather
than assuming undocumented DamageBDD RBAC APIs; align it with your node role
provisioning. The queue publishes a separate review branch, not directly to
production; it does not open a remote pull request. The node needs an
interactive-free Git credential for `origin`. If the base commit has moved,
regenerate the patch or rebase/reverify it through the existing repair pipeline
instead of overriding the safeguard.

## Experimental marketplace

The supplied `ecai_jobs_http` endpoints were **not routed** and the
`ecai_jobs_srv` process was **not supervised**. To enable these endpoints now,
add the following ECAI configuration and restart the node:

```erlang
{ecai, [
    {marketplace_enabled, true}
]}.
```

`ecai_app` conditionally registers its routes and `ecai_sup` starts its worker.
The default is **`false`** (including `ecai.app.src`). **Do not use this for
real payments or trusted economic state**: the current marketplace ledger is
in-memory and is lost on node restart; its `pay` action only updates a local
status and performs **no actual chain transfer**. There are no verified role
checks tying `admin_ak` / `miner_ak` to the authenticated signer yet. Production
activation requires durable, audited state and actor authorization.

This experimental marketplace is separate from the **durable** operational
indexing queue under `/ecai/index-jobs`.

## Testing

From the DamageBDD umbrella repository:

```bash
node --check apps/ecai/priv/static/js/ecai-console.js
python3 apps/ecai/test/test_console_contract.py
# Optional Chromium smoke test (Playwright and Chromium required):
python3 apps/ecai/test/test_code_admin_browser.py
# In an environment with Erlang/rebar3 installed:
rebar3 compile
rebar3 eunit --app ecai
```

For end-to-end validation, start a configured ECAI node, visit `/dashboard`,
log in using a DamageBDD account, run a search, inspect jobs and preset cards,
and test authenticated SSE under an existing job. The HTML UI has also been
smoke-tested with mocked route responses in Chromium, including a 390 px
mobile viewport; this is not a replacement for full live-node verification.

### Repair search and collapsible, file-by-file patch reviews

The node-admin Code learning & repair page shows recent repair records with
**Validated only** selected initially. Search by module, fingerprint, summary,
security property or patch hash; filter by application and validation outcome;
and optionally select **With reviewable diff**. A **View diff** action is only
shown when the repair can be matched to an imported review by all three of
fingerprint, SHA-256 patch hash and base commit. The API currently returns the
latest 200 repairs and latest 200 review entries, so browser-side filters cover
that retrieved window rather than an unbounded history.

Patch reviews use a one-open-at-a-time `<details>` list with independent
search, application, review-status and verifier-status filters. Collapsed rows
show target, review state, verification status, approval counts and timestamp.
Opening a row fetches the immutable review (including the full unified diff and
audit trail) from `/ecai/admin/code/reviews/:id`; patches are **not** fetched in
bulk. File tabs allow inspecting a single changed file or all changes, with
coloured additions, removals and hunk headers. The display limits a very large
diff to 4,500 lines per selection; **Copy full diff** retains the complete
server-returned text. Source and log content is placed in the DOM using
`textContent`, never interpreted as HTML.

The approval, rejection and origin-publication controls move into the currently
expanded review card without cloning the form. Opening another card closes the
previous review; stale asynchronous detail responses are ignored. The existing
server-side hash, revision, role, verification, separate-publisher and
no-force-push checks are unchanged.

A restored cookie session may authenticate read-only requests but not carry an
explicit bearer token. The server **requires `Authorization: Bearer ...` for
all patch mutations** and returns `403 bearer_required` without it. The
console therefore disables approval/rejection/publication for cookie-only
sessions and offers **Sign in for review actions**. It never accepts cookie-only
patch mutations or sends credentials from a stored patch record. Approval is
still not publication; `code_review_push_enabled` defaults to `false`.

### Operator metrics and publication-gate diagnostics

The Code Learning & Repair workspace renders existing `GET /ecai/admin/code/status`
fields as a compact, no-dependency operations view: current-cycle learner
completed/total and phase, active repair workers, live repair backlog, queue
approvals, approved/published reviews, worker/integration health, and timestamp
of the most recent status poll. Backlog uses `patch_manager.pending` rather than
its cumulative `queued_total` metric; integration failures use
`integration.job_counts.broken`. No synthetic data or CPU percentages are
shown. The original complete status response is available under **Detailed node
status · raw JSON**. While the admin view is visible, lightweight status-only
refreshes occur about every 24 seconds; repair-list/diff loading remains on
user-initiated refresh or review selection.

When a review card opens, `GET /ecai/admin/code/reviews/:id` now includes
`review.publication_gate`: a **read-only** evaluation for the principal returned
by `damage_auth:authenticated_account/1`. Example (when the current signed-in
account is an approver):

```json
{
  "eligible": false,
  "blockers": ["publisher_is_reviewer"],
  "approvals": 1,
  "required_approvals": 1,
  "publisher_is_reviewer": true,
  "publish_enabled": true,
  "git_preflight": "not_checked"
}
```

`1 of 1 approvals` means the patch is **approved**, not that the current
operator can publish it. The approver must sign out, and a **different,
authorized DamageBDD node admin** must sign in with an explicit bearer token,
open the same review, inspect the diff, type `push to origin`, and submit.
The UI does not enable publication for the approving identity or if server gate
diagnostics are unavailable (e.g. the old module is still loaded). The server
rechecks every condition in its serialized queue before spawning a Git worker.

A refused POST now returns a specific HTTP 409 error such as
`publisher_is_reviewer`, `approvals_missing`, `push_disabled`,
`review_not_approved`, `repair_superseded`, `patch_hash_mismatch`, or
`stale_review_revision`, instead of only `publication_gate_not_satisfied`.
The UI reloads a review on conflict and explains the specific condition.
The read-only gate does **not** contact or validate the remote Git `origin`;
remote existence, current HEAD, detached worktree and verifier checks still
occur at publication time. A rejected push never bypasses the independent
reviewer gate or causes a force push.

Optional isolated browser regression:

```bash
python3 apps/ecai/test/test_code_metrics_browser.py
```


### Wikimedia source picker and job queue builder

The `/dashboard#wikimedia` view now has two supported workflows:

1. **Pick projects:** the UI calls authenticated `GET /ecai/index-jobs/presets`,
   presents a searchable checkbox list, and submits each checked preset to
   `POST /ecai/index-jobs/presets/:preset`. The server, not the client, decides
   the source, pageview window, namespace, path and indexing policy. The UI
   retains an independent idempotency key for each preset until its request
   succeeds. Partial failures remain selected with visible errors; a retry does
   not enqueue the same accepted request twice.
2. **Custom project/release/month:** choose a configured project, then press
   **Discover sources** to call `GET /ecai/wikimedia/sources`. Returned release
   identifiers are actual listed Cirrus releases, while pageview months are
   suggestions, **not availability guarantees**. Select month checkboxes and a
   record limit, then press **Preview validated plan**. The server resolves the
   content and pageview file catalog, normalizes the job, and returns a
   `plan.spec` from `GET /ecai/wikimedia/plan`. The UI verifies its immutable
   release, source and month coordinates and enables Queue only for that exact
   validated input. `POST /ecai/index-jobs` submits the server-generated spec
   with an idempotency key; the authenticated account is bound server-side.

The custom-plan default output path, index ID and namespace are now isolated
by Wikimedia project, retaining legacy English genesis defaults. The picker
never sends a client-chosen filesystem path. Operators should still avoid
running concurrent jobs that target the same project/index; a confirmation
warns when the current job list reports active work for a selected project.

Queued jobs are visible under **Index jobs**; no new permission or background
JavaScript library is needed. The queue and source-planning endpoints retain
all server-side validation. Running a plan may fetch Wikimedia catalog
listings and can take time; it does not enqueue work until confirmed.

Optional browser regression (mock API, no real enqueue):

```bash
python3 apps/ecai/test/test_wikimedia_picker_browser.py
```
