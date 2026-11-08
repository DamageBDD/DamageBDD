# ECAI Supply Chain Recovery Lab

Integrated against the `latest-ecai.tar.gz` supplied for this request. This is a
synthetic **pre-dispatch planning application** with saved account workspaces
and isolated temporary public demos, not a live
transport-management system. It does not dispatch vehicles, spend compute
credits, call an LLM, mint assets, or change external inventory.

## Open the application

After applying, compiling and restarting the existing DamageBDD umbrella, open:

**ECAI Dashboard → Applications → Supply chain · Recovery Lab**

Direct fragment: `/dashboard#supply-chain`.

No sign-in is required. Guests and wallet-only sessions use temporary, cookie-isolated
workspaces; managed accounts keep their existing saved workspaces. Signing in does
not import guest cases. Both this lab and Orbital verification are under Applications.
The orbital view remains a local browser simulation at `/dashboard#orbital`.

Guest memory expires after 30 minutes of inactivity or a service restart. Tabs in
the same browser share a demo cookie. Separate browsers/cookie jars are isolated.
There is no shared global guest workspace and no anonymous access to account DETS.

## Install

This follow-up patch targets the previously supplied Recovery Lab version,
`latest-ecai-with-recovery-lab.tar.gz`. Apply from the **DamageBDD repository root**:

```sh
PATCH="$HOME/Downloads/ecai-public-applications.patch"
git apply --check "$PATCH" && git apply "$PATCH"
rebar3 compile
apps/ecai/test/run_supply_chain_tests.sh
```

Restart the application/release using your normal deployment procedure. The new
supervised service and HTTP trails must both be loaded; refreshing a browser or
reloading only the router is insufficient. The console asset URL is versioned.

The companion `latest-ecai-public-applications.tar.gz` is the full uploaded ECAI
application with these changes applied. It is an **alternative** to applying the
patch, not a complete DamageBDD release. Extract it into a review directory
first and compare `apps/ecai` with your checkout. Do not blindly overwrite newer
local edits. The original upload did not contain `apps/damage` or root build
configuration, so no Damage files or umbrella dependency files were changed.

Defaults are in `apps/ecai/src/ecai.app.src`: the lab and public demos are enabled,
and optional curve addressing is disabled. Existing `sys.config` does not need a new entry.
An optional configuration fragment is in
`apps/ecai/priv/config/supply_chain.example.config`; merge its entries into the
existing `ecai` section rather than replacing the entire configuration.

### Reverse proxies and public-demo controls

For a TLS-terminating reverse proxy, set the exact externally visible browser origin,
with scheme, optional nondefault port, and **no trailing slash**, in the `ecai` config:

```erlang
{supply_chain_public_origin, <<"https://ecai.example.org">>}
```

Replace the example with your deployed origin. Without this setting the handler uses
Cowboy's request scheme/host/port. Untrusted forwarding headers are not used. A wrong
origin is rejected with 403 rather than silently weakening the cross-origin check.
The demo cookie is Secure for an HTTPS origin, HttpOnly, SameSite=Strict, host-only,
and scoped to `/ecai/supply-chain/public`. Plain-HTTP local development is supported.
If a proxy changes the Host header, configure this origin even without TLS termination.

`{supply_chain_public_enabled, false}` disables only guest APIs. Managed workspaces
remain available. `{supply_chain_enabled, false}` disables the entire Recovery Lab.
Orbital verification is local and does not depend on these settings.

## First demonstration

1. Leave seed **42**, then press **Load / reset scenario**. This computes and
   independently validates a baseline and accepts it as the simulated starting
   plan. Reset is an explicit simulation operation, not a real dispatch.
2. Press **Close central bridge**, or click a road on the map. Existing routes
   remain visible and the panel reports failed checks and route-affected orders.
   Roads close for the entire four-hour planning horizon in this version.
3. Press **Retrieve + repair**. With empty memory this performs a new search.
   A validated proposal is saved to account-local recovery memory, but it does
   not replace the approved plan until **Approve simulated plan** is pressed.
4. Inspect the map, delivery timeline, rejected fragments, stock allocations and
   assignments. A fresh proposal must pass independent validation before approval.
5. Reset seed 42 while retaining memory, close the same bridge, then retrieve
   again. The identical relevant state permits an exact case hit and full
   revalidation without a new search.
6. Select a shop and increase an order quantity, toggle a vehicle's availability,
   or add an urgent order. A related case may seed repair. The decision panel
   reports the selected search start: a retrieved seed is not necessarily the
   winning start.
7. Disable all six vehicles and plan again to inspect a valid partial-service
   result with every order unserved. The system does not invent capacity or
   claim an optimality/infeasibility proof.

The **Play preview** control moves forecast markers only. It never advances
backend execution, consumes stock, or makes delivered stops irreversible.
Playback pauses when the panel/document is hidden. All input changes remain
pre-dispatch changes, even after playing the preview.

## Dashboard views

- **Network & recovery:** 2 warehouses, 24 shops, 6 trucks, 48 starting orders;
  keyboard/click road controls; vehicle and urgent-order disruptions; shop/order
  inspection; route filters; ghost approved routes; timeline; assignment table;
  inventory allocation; policy controls; revision-bound approval.
- **Recovery memory:** up to 64 full scenario/plan records per account, canonical
  ECAI terms, state/content digests, retrieved case IDs and optional curve metadata.
- **Benchmark:** measured cold search, warm start, conventional case scan and
  ECAI-postings retrieval, using the same snapshot, objective and validator.
- **Evidence & history:** bounded recent events and exportable canonical manifest
  bytes with a domain-separated SHA-256 checksum.

The layout uses existing dashboard theme variables and responsive styles. This
feature has no browser map service, chart library, CDN or new Python dependency
at runtime.

## Planning model and guarantees

The native Erlang planner is a deterministic, four-start **greedy insertion
heuristic**, not OR-Tools and not an exact vehicle-routing solver. Fresh starts
use different orderings. Warm/case repair evaluates a seeded start and three
fresh alternatives; `selected_start` and `seeded_start_won` expose which won.
The deterministic plan excludes wall-clock timing and history metadata, which
naturally vary between runs.

Vehicles have one pickup warehouse and one route returning to their home depot.
They can drive empty to another warehouse before loading. No reloads, mid-route
handoffs, transfers, breakdown rescue, driver-break model, live traffic or
physical temperature simulation are included. Travel times are fixed positive
integer minutes. Chilled goods require a refrigerated vehicle; warehouse-level
per-product expiry times are model constraints, not measured cold-chain evidence.

The objective is lexicographic: minimise unserved priority, then the number of
unserved orders, then travel minutes plus the configured penalty for changed
vehicle/warehouse assignments. Stability does **not** measure every route
sequence change. `at_risk_crates` is the quantity of unserved demand, shown as
**Unserved crates**; it is not a prediction of food waste or spoilage. There is
no currency cost model in this version.

The separate validator never invokes the planner's scheduler. It walks every
reported road path and recomputes travel/service/loading times, return time,
stock usage, capacity, refrigeration, expiry, uniqueness and order accounting.
Unserved orders are explicitly allowed and counted. Successful validation means
feasible under the model, not globally optimal. A heuristic's failure to serve
all orders is not evidence that full service is mathematically impossible.

A road/vehicle impact count is a route-dependency count. Other violations, such
as changed quantities or order accounting, appear in the failed-check list and
may not increase that count.

## What ECAI does here

`ecai_supply_chain_cases` uses the existing `ecai_terms:terms_from_record/1`
pipeline and its version. It maintains exact state-digest lookup and canonical
term postings over retained records. Related states are ranked deterministically
by feature overlap and recency. Features encode order count, demand bucket,
policy, closures and unavailable vehicles. This is an initial operational
feature set for one fixed network, not a general logistics similarity model.

The ordinary lookup comparator uses exactly the same features and ranking via
linear scan. The ECAI mode rebuilds its small in-memory postings from retained
cases on each retrieval; checksum checking and reconstruction are included in
its reported time. A common scenario term can bring every case into the
candidate set. With only 64 cases there is **no assumed indexing speedup**.

A full scenario and plan are retained. Hashes are identifiers/integrity checks,
not reversible storage or an optimisation engine. Optional existing-NIF curve
addresses are identity metadata only, with explicit available/unavailable/
disabled status. They are not a similarity metric, signature, proof of truth,
proof of optimality, or post-quantum security claim. The lab runs without the
ECAI NIF when optional curve addressing is disabled.

Each benchmark freezes case memory and does not learn from its own trial
outputs. All fresh/repair modes have four starts; exact hits may skip search.
Execution order is deterministically rotated. This is a single local trial,
not a statistically controlled benchmark or proof of ECAI superiority. Compare
solution quality alongside time. Corpus construction costs and unseen-scenario
generalisation still need separate measurement.

## State, safety and persistence

Public demos use private ETS tables owned by the service and tagged guest identifiers,
never binary account IDs or DETS. The server issues 256-bit random opaque cookie
capabilities and stores only their hashes. Defaults allow 32 active guest sessions,
64 cases per workspace, one concurrent guest job within the existing two-job global
bound, and 30-minute idle expiry with a 60-second cleanup sweep. Expired jobs cannot
recreate a deleted workspace. Guest slots do not consume the 64 durable-account slots.

Admission uses token buckets per session (40 tokens, refill 2/second) and socket-peer
address (120 tokens, refill 4/second; at most 1,024 entries). State/event/approval/export
cost 1; reset/plan cost 6; benchmark costs 12; creating a session costs an additional 10.
Socket-peer addresses are hashed; forwarded client-IP headers are not trusted. A
reverse proxy therefore shares its peer bucket across visitors. Deploy proxy-level
rate limiting as well: these application bounds are not a network DoS defence.


Each authenticated account has one DETS workspace containing its scenario,
revision, plans, case memory, comparison and the latest 40 event entries.
The owner is derived from shared authentication, never from request JSON.
Account memory is isolated at the API/service-key level; the node operator can
access the unencrypted DETS file. This is not a noncustodial or encrypted private
knowledge vault.

Default location:

```text
<ecai_paths:runtime_dir()>/supply-chain/workspaces.dets
```

The directory is created with mode 0700 and the store with 0600. Writes are
acknowledged after `dets:sync/1`. Back up this directory through normal node
operations. This single-node store is not a replicated database and history is
not a permanent, signed or append-only audit log. Do not share the same DETS file
between running nodes.

Default bounds: 64 workspaces per node, 64 cases per account, 60 orders, two
concurrent jobs across accounts, one job per account, 20-second worker deadline,
30-second service-call deadline, 8 KiB JSON body and five-second body-read budget.
No paid fallback is attempted when a budget is exhausted. The extra test-only
`start_link/1` options let tests reduce concurrency/timeouts; they are not a
public remote configuration surface.

Every mutating API operation requires `expected_revision`. Scenario changes,
reset and approval advance it. Derived proposals/comparisons do not. Approval
requires both the current proposal ID and matching input revision, and validates
again. An older job result is discarded if inputs changed while it ran. Two
concurrent requests against the same prior revision cannot both change inputs.

The browser uses the shared authenticated request client, aborts outstanding
requests on reset, checks identity/epoch before accepting responses, clears
account data on sign-out/switch, and avoids `innerHTML` and localStorage. Writes
on account routes require an explicit bearer token; cross-site Fetch Metadata requests are rejected.
Public routes instead require the dedicated same-origin request header and a valid
demo cookie (created only by GET of the public root). They ignore account credentials,
reject cross-site/sibling-site browser requests, and provide no CORS. The console
does not attach account bearer tokens to public-demo requests.
HTTP responses are `no-store`. Real network/auth integration still requires the
full umbrella's integration tests.

## HTTP API

The following original routes still require the existing managed account. Successful bodies are
`{"ok":true,"data":...}`; errors are `{"ok":false,"error":"reason"}`.

| Method | Path | Request |
| --- | --- | --- |
| GET | `/ecai/supply-chain` | Current account workspace; no body |
| POST | `/ecai/supply-chain/reset` | `expected_revision`, optional `seed` (42), `keep_cases` (true) |
| POST | `/ecai/supply-chain/event` | `expected_revision`, `event` |
| POST | `/ecai/supply-chain/plan` | `expected_revision`, optional `mode`: `cold`, `warm`, `lookup`, `ecai` |
| POST | `/ecai/supply-chain/approve` | `expected_revision`, `plan_id` |
| POST | `/ecai/supply-chain/benchmark` | `expected_revision` |
| GET | `/ecai/supply-chain/evidence` | Export; no body |

The same seven actions are available for guests by using base path
`/ecai/supply-chain/public` instead. Every public request must include
`X-ECAI-Lab-Request: 1`; POST also uses `Content-Type: application/json`.
First GET the public root and retain its cookie. Subsequent requests use that cookie
and the same revision-bound payloads. The dashboard performs this automatically.
HTTP 410 means the guest session expired: refresh the root and explicitly load a
new scenario. Mutations are never automatically replayed after expiry. HTTP 429
includes Retry-After; capacity limits may require waiting for another session to expire.

Example event payloads:

```json
{"expected_revision":1,"event":{"kind":"road","id":"bridge-central","closed":true}}
{"expected_revision":2,"event":{"kind":"vehicle","id":"T1","available":false}}
{"expected_revision":3,"event":{"kind":"urgent_order"}}
{"expected_revision":4,"event":{"kind":"demand","id":"O1","quantity":3}}
{"expected_revision":5,"event":{"kind":"policy","stability_weight":12}}
```

Use the actual revision returned by the preceding request. Unknown fields and
client-provided owners are rejected. HTTP 409 requires refreshing state before
retrying; 429 indicates a workspace/job bound; 503 indicates disabled/unavailable
service, storage failure, timeout, or uncertain request completion. Refresh after
an uncertain completion rather than assuming the operation did not run.

Verify an export locally:

```sh
python3 apps/ecai/scripts/verify_supply_chain_evidence.py \
  "$HOME/Downloads/ecai-supply-chain-evidence.json"
```

The verifier hashes the exact UTF-8 `manifest_json` string as
`SHA256(domain || 0x00 || manifest_bytes)`. It must not pretty-print/re-serialise
that string before verification. A matching checksum alone does not authenticate
an author: an attacker able to replace both the manifest and digest can create a
new matching pair.

## Tests and verification status

Executed in the implementation environment:

```sh
python3 apps/ecai/test/test_supply_chain_contract.py       # 11 tests passed
node --test apps/ecai/test/supply_chain_model.test.mjs     # 6 tests passed
python3 apps/ecai/test/test_supply_chain_browser.py        # Chromium flow passed
node --input-type=module --check < apps/ecai/priv/static/js/ecai-supply-chain.js
node --input-type=module --check < apps/ecai/priv/static/js/ecai-console.js
sh -n apps/ecai/test/run_supply_chain_tests.sh
```

The source tests inspect wiring/auth boundaries; they are **not** runtime
security tests. The Chromium test uses the real production panel, styles and
module with **mock API responses**. It checks unauthenticated use, wallet access, separate saved-account state, session
expiry/rate-limit handling, initial empty state, network rendering, changes, recovery UI, revision submission,
stale-proposal blocking, approval, memory, comparison, export, forecast-only
playback, late-account-response isolation and narrow-screen overflow. Fixture
timings are explicitly fake and never appear in production code. An accompanying
screenshot is labelled as a mocked-data UI preview, not a backend benchmark.

Not executable in the implementation environment: **Erlang compilation, EUnit,
full-umbrella tests, real Cowboy/shared-auth requests and runtime planner
benchmarks**. Erlang/rebar3 were unavailable, and the upload contains only ECAI.
Consequently the Erlang implementation is included for compilation and validation
on your node; it is not represented as runtime-verified here.

The included EUnit modules cover deterministic scenario generation, invalid
inputs, independent validation against corrupted paths/loads/stock/refrigeration/
expiry, repair, all-fleet-unavailable partial service, exact/related retrieval,
corrupt case rejection, memory bounds, comparison, account isolation, revision
conflicts, stale approval, export checksums, DETS restart, reset/retention and
worker bounds/timeouts, guest cookie isolation, expiry, quotas, rate limits,
cross-origin guards, guest nonpersistence and private persistence across restart. Run them with **OTP 27+ including EUnit**:

```sh
apps/ecai/test/run_supply_chain_tests.sh
# Or in the full existing umbrella:
rebar3 eunit --module=ecai_supply_chain_tests,ecai_supply_chain_public_tests
python3 apps/ecai/test/test_console_contract.py
```

The standalone runner compiles the new HTTP module but does not run Cowboy/auth;
it compiles only local pure dependencies and runs the model/service tests.
The browser test needs the Python Playwright package and Chromium. Set
`CHROMIUM=/path/to/chromium` when it is not `/usr/bin/chromium`.

## Source map

`ecai_supply_chain_model`: bounded scenario, mutations and candidate scheduling.
`ecai_supply_chain_planner`: deterministic insertion search and metrics.
`ecai_supply_chain_validator`: independent full-plan feasibility checks.
`ecai_supply_chain_cases`: ECAI terms, retrieval, case retention and digests.
`ecai_supply_chain_task`: planning modes and measured comparison.
`ecai_supply_chain_srv`: durable account workspaces, temporary guest workspaces and bounded jobs.
`ecai_supply_chain_guest`: private ETS, opaque guest sessions, expiry and rate limits.
`ecai_supply_chain_http`: private/public route separation, origin guards, body limits and errors.
`ecai_supply_chain_util`: canonical JSON, domain hashes and input helpers.

Existing application trails, supervisor, dashboard renderer, sidebar, controller
lifecycle, API explorer, app defaults and console contract are integrated. No
unrelated market-maker, compute-provider, LLM or billing behaviour is changed.
