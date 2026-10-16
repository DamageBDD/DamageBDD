# Mathematical paths in the ECAI dashboard

This integration adds a real, authenticated mathematical workspace to the existing
ECAI control-plane dashboard. It uses the existing exact-rational pathfinder; it
is not the earlier standalone HTML prototype. Open `/dashboard#math` after deploying
and restarting the updated release. The supplied source archive was
`latest-ecai.tar(1).gz` and contained `apps/ecai`, not the whole DamageBDD release.

## Install and run

From the DamageBDD repository root:

```bash
git apply --check ~/Downloads/ecai-math-dashboard-integration.patch &&
git apply ~/Downloads/ecai-math-dashboard-integration.patch

# Isolated native compilation and tests; requires Erlang/OTP 27 or newer.
bash apps/ecai/test/math_dashboard/run.sh

# Compile in the complete umbrella repository.
rebar3 compile
```

Deploy with your existing release-build procedure and restart the ECAI service.
A JavaScript refresh or router reload alone does not start the new supervised job
service. Deploy templates, JavaScript, CSS and BEAM modules together. The console
asset URL is versioned to avoid retaining the previous shell code.

The service is enabled by default. To disable it, merge the following into the
existing `ecai` application entry in `sys.config` and restart:

```erlang
{math_dashboard_enabled, false}
```

Do not replace the application's entire configuration. A merge example is in
`priv/config/math_dashboard.example.config`. The math navigation item remains
visible when the service is disabled, but API operations fail explicitly.

Sign in with an existing managed/custodial DamageBDD account. A connected wallet
alone does not authorize mathematical jobs. This addition does not create a new
login system, charge a wallet, trigger L402, or bypass the existing account resolver.

## Workspace

The form accepts exact integers or fractions, such as `-1` and `3/5`. Source and
target are models `y² = x³ + a₂x² + a₄x + a₆` over Q.

- **Run explicit demo** runs the existing demo graph in Erlang.
- **Discover & verify** calls bounded native degree-2 kernel discovery and search.
- **Import & check** accepts an exported mathematical-path JSON file and replays
  the native checks before showing a verified result. Graph JSON is not accepted.
- **Replay checks** creates a new job and freshly checks the selected path.
- **Export path JSON** preserves the exact JSON bytes emitted by the backend.
  **Export evidence bundle** additionally includes the math job metadata and
  scoped evidence in an `ecai-math-dashboard-bundle/v1` wrapper.

A selected path displays its actual ordered curve occurrences and rational maps.
Select a curve or arrow to inspect its exact coefficients, IDs and checker output.
Repeated occurrences of one model remain visible when a path contains a cycle.
Graph layout conveys composition order, not mathematical distance. Edge weights
are search costs, not DAMAGE, sats or elapsed time. The demo's degree-4 route is
not a global minimum-degree claim: its endpoint models also admit a degree-1
scaling isomorphism.

Verification, search/bounds, and run/provenance are separate tabs. The last tab
shows this mathematical job, not a fabricated association with a DamageBDD run.
No geometric curve plots or invented search-branch animation are included.

### Import your earlier successful path

Select the existing `ecai-math-path-1792141585230518.json` file in the import form.
The backend checks it afresh and returns a new job and normalized path JSON. It
records the SHA-256 of the original input separately from the exported artifact.
The export need not equal the original file byte-for-byte: submitted verification
flags and search metadata are discarded on import, and evidence is recomputed.

The bundle download is an archival wrapper, not an accepted path upload. To
reimport, use **Export path JSON**, or extract the bundle's `job.result.path_json`
string without parsing/re-serializing its contents.

An exported native path can be independently checked from the repository root:

```bash
python3 apps/ecai/test/math_pathfinder/reference_checker.py \
  /absolute/path/to/ecai-math-path.json
```

The dashboard does not execute that external Python checker. It does not infer
that the user's earlier 57-test EUnit result or earlier DamageBDD feature report
is evidence for a newly submitted artifact. Those statuses remain **not attached**.

## API

All routes are registered with the existing ECAI Cowboy listener and Trails router.
No external assets or charting dependencies are added.

| Method | Route | Behaviour |
| --- | --- | --- |
| GET | `/ecai/math/jobs` | This account's retained job summaries |
| POST | `/ecai/math/jobs` | Submit `demo`, `discover` or `import`; returns 202 |
| GET | `/ecai/math/jobs/:id` | This account's job and available result |
| POST | `/ecai/math/jobs/:id/replay` | Submit a fresh replay, with body `{}` |
| GET | `/ecai/math/jobs/:id/path` | Exact checked path JSON as an attachment |

Example discovery body:

```json
{
  "operation": "discover",
  "source": {"a2": ["0", "1"], "a4": ["-1", "1"], "a6": ["0", "1"]},
  "target": {"a2": ["0", "1"], "a4": ["-16", "1"], "a6": ["0", "1"]},
  "bounds": {"max_depth": 2, "max_curves": 64, "numerator_bound": 8, "denominator_bound": 4}
}
```

Import body: `{"operation":"import","path_json":"<original JSON text>"}`.
Keep coefficient components as decimal strings, not JavaScript Numbers. Unknown
request fields, arbitrary owner identifiers and arbitrary evaluation operations
are rejected. Jobs transition from `running` to `succeeded` or `failed`; there is
no unbounded request queue.

A successful result includes `path`, `path_json`, `artifact_sha256`, `elapsed_ms`,
`checked_at_ms`, metadata and scoped evidence. `artifact_sha256` identifies the
exact UTF-8 bytes of `path_json`; it is distinct from the native path identity.
`elapsed_ms` measures the worker task including mathematical work, verification
and encoding, not total HTTP lifecycle time or billing time.

## Access and operational limits

All reads resolve the existing managed account. Cookie-only GETs can read that
account's jobs; POSTs require an explicit bearer token resolved by
`damage_auth:resolve_oauth/2`. Invalid bearer authorization never falls back to
cookies. Wallet-only principals and cross-site Fetch Metadata requests are
rejected. No permissive CORS is installed. Cross-account job reads return 404.
Responses use `no-store, private`; imported strings are rendered as text, not HTML.

The console's existing request wrapper supplies same-origin credentials and bearer
authorization. Account changes and sign-out clear the workspace. Response-epoch
checks prevent a late response from a previous account from restoring old data.
Only visible pending jobs are polled. The workspace itself does not persist tokens
or mathematical data in browser storage.

Hard limits in this first version:

| Limit | Value |
| --- | --- |
| Concurrent task slots | 2 per node, 1 per account |
| Minimum interval between accepted account tasks | 1 second |
| Retained jobs | 8 per account, 32 per node, up to 1 hour from start |
| HTTP JSON body and returned path | 256 KiB each |
| Browser file-selection limit | 192 KiB; encoded JSON envelope must also fit HTTP limit |
| Body-read deadline | 5 seconds |
| Dashboard worker watchdog | 60 seconds |
| Discovery | depth ≤ 3; curve models ≤ 64; numerator bound ≤ 32; denominator bound ≤ 16 |
| Imported path length | ≤ 16 maps |
| Form/API rational component | ≤ 64 characters |

Records are **volatile**, cleared on restart, and may be evicted sooner when the
account or node reaches capacity. Export important evidence. This is a single-node
service, not a distributed or persistent job registry. A multi-node deployment
needs node affinity for job IDs or a shared job store before relying on polling
across nodes.

Heavy discovery/verification runs outside the coordinator in monitored, linked,
heap-limited workers. The existing engine adds its own bounded workers and exact
arithmetic limits. Abnormal termination reserves an admission slot for another
30 seconds to accommodate nested worker deadlines. These are BEAM safeguards,
not an OS security boundary or a global cluster quota. A supervisor/node crash
can leave an inner worker alive until its own deadline. Add workload isolation
before exposing untrusted expensive workloads at larger scale.

## Evidence scope

Only a successful native replay produces the green algebraic badge. The backend
checks imported paths rather than trusting their receipt flags. Native path
identity and the exported bytes' SHA-256 are reported separately from provenance.
Neither authenticates source labels. `formal_proof` remains `false`.

Independent-check certificates, DamageBDD report binding, signatures, transaction
settlement, consensus, automatic IPFS publication, public sharing and NFT minting
are not implemented by this integration. No previous successful run or price is
hard-coded as current evidence. Search counters are shown when returned by native
discovery; a complete exploration event trace is not manufactured from totals.
A failed bounded search is not a theorem that no relationship exists.

## Test commands and recorded validation

Native compilation/EUnit must be run on your machine: the delivery environment
had no Erlang runtime/compiler. The native runner also compiles the edited
renderer. Its 24 task/registry cases and 14 handler cases are supplied but were
**not executed here**. Handler cases use explicit test-only auth/Cowboy adapters,
not real sessions. These files use `.erl.fixture` extensions and are copied only
to a temporary test path; never deploy those adapters.

```bash
bash apps/ecai/test/math_dashboard/run.sh
node --test apps/ecai/test/math_dashboard/view_model.test.mjs
python3 -m unittest \
  apps/ecai/test/test_math_dashboard_contract.py \
  apps/ecai/test/test_compute_dashboard_contract.py \
  apps/ecai/test/test_ollama_keys_dashboard_contract.py \
  apps/ecai/test/test_video_dashboard_contract.py
```

Browser tests require Playwright and Chromium. They use synthetic API/auth data,
never contact a funded node and do not establish native HTTP behaviour:

```bash
python3 apps/ecai/test/math_dashboard/browser_test.py
python3 apps/ecai/test/math_dashboard/console_browser_test.py
```

Recorded results: 12 Node tests passed; 21 selected Python contract tests passed;
15 workspace browser checks and 7 actual-console browser checks passed. The
existing independent mathematical reference suite also passed 12 tests; it does
not test the new Erlang HTTP/coordinator code. JavaScript and shell syntax checks
passed. The preview screenshots use browser fixtures, not production results.

The broader pre-existing dashboard test group was also compared against the
untouched upload. Of 33 cases, baseline passed 29 and patched source passed 30.
The three remaining non-passing cases are unchanged baseline issues:

1. `test_shared_browser_routes_and_legacy_indexer_routes_are_explicit`: an old
   textual route-layout assertion conflicts with the existing conversation handler.
2. `test_code_review_backend_is_fail_closed`: an old textual assertion expects a
   fixed `origin` instead of the existing configurable review remote.
3. `test_post_requires_bearer_node_admin_and_no_live_mode`: the supplied archive
   omits `apps/damage/src/ecai_mm.erl`, which that test tries to read.

The stale API-count test was brought into line with the supplied dashboard's
already-existing routes plus this integration. Unrelated implementation behaviour
was not changed merely to make old assertions pass. Full umbrella compilation,
real authenticated Cowboy requests, live deployment and full DamageBDD feature
execution for the dashboard remain deployment-validation steps.
