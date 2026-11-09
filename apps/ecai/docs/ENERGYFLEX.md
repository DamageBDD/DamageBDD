# EnergyFlex — public energy scheduling lab

Open **Applications → EnergyFlex**, `/dashboard#energyflex` (or `/#energyflex` when
this console is mounted at `/`). A standalone public page is also supplied at
`/static/energyflex/index.html` on the ECAI listener.

## User walkthrough

1. The evening reference is already calculated. Read the four outcome cards.
2. Press **Play** to replay 17:00–23:00. Switch the displayed plan to compare the
   optimised schedule against charge-early and tariff-aware scheduling.
3. Choose a scenario or change the site limit/departure. Manual changes invalidate
   old results; press **Recalculate this scenario** to obtain current results.
4. At the verification desk, lower capacity to 16 kW or inject a duplicate hour.
   Inspect the rejection; a rejected test plan never replaces the valid plan.
5. Export evidence and replay it with the included Python checker.

The guided tour, inline help, exact hourly data, keyboard-operable chart, responsive
layout and reduced-motion support are built in. Presentation mode supports a CSS
fallback when browser fullscreen is unavailable. Replay stops on navigation,
page hiding, tour opening and disposal.

## Reference result (synthetic)

| Strategy | Charging cost | Total variable energy cost | Peak | Required energy |
|---|---:|---:|---:|---:|
| Charge early / capacity-aware earliest deadline | A$18.90 | A$27.35 | 18 kW | 42 kWh |
| Conventional tariff-aware heuristic | A$11.90 | A$20.35 | 17 kW | 42 kWh |
| Exhaustive exact reference | A$11.90 | A$20.35 | 17 kW | 42 kWh |

The search evaluates 450 assignments, 189 feasible. The A$7.00 / 25.6% reduction is
relative to charging early, for total variable energy cost. It is not a field
saving, a retail bill forecast, or proof of an AI advantage. The conventional
tariff-aware baseline matches the optimum here and is visibly credited.

## Model and boundaries

Three vehicles each need 14 grid-side kWh, at a fixed 7 kW, in whole one-hour slots.
All arrive at 17:00; departure times are specified in the fixture. Building demand
and invented integer-cent AUD tariffs cover six hours. A shared power limit
applies to the building plus charging. The exact search is optimal only for this
explicit, small discrete model. It does not model physical grid dynamics,
charger modulation, conversion losses, fixed charges, taxes or forecast error.

Five presets: evening commute, price spike, grid squeeze, early departure, and
infeasible capacity. Controls allow 10–26 kW and Vehicle A departures at
19:00/20:00/21:00. No arbitrary uploaded model, code or remote URL is accepted.
The general model validator is bounded to eight slots/four tasks and at most
200,000 candidate assignments; the visible controls produce at most 900.

Infeasible results have a null optimum, no passing verification and no savings
claim. Incomplete heuristic plans do not receive a comparable cost/saving claim.
After input changes, all current KPI claims are cleared; the old plan is checked
against the new constraints as a labelled stale-plan experiment.

## Public access and security

This release requires only the existing public console and static assets. The new
panel is not marked `data-ecai-managed`; refresh returns before remote/session-
gated code. It does not change server authentication, wallet rules, billing,
admin routes, private indexes or device permissions. The EnergyFlex modules do
not make API/network requests or read credentials. Existing console startup may
still perform its usual public status/session checks. The standalone page avoids
those console dependencies entirely.

Serve through the existing ECAI static route and your normal HTTPS deployment.
If an upstream proxy protects the whole site, it will still protect the page;
that infrastructure policy is not changed by this bundle. Verify anonymous HTTP
access in the deployed environment. Do not make protected API routes public.

## Evidence and verification

The JSON export contains a versioned input fixture, the three schedules, all
recomputed metrics, constraint results, search counts and comparisons. Its
SHA-256 checksum covers compact sorted-key JSON excluding the `integrity` field.
The format uses integer arithmetic for prices/energy and rounded integer basis
points for percentage savings. Browser checksum export requires HTTPS or
localhost. A meaningful error is shown on unsupported/insecure contexts.

```sh
python3 apps/ecai/tools/verify_energyflex.py ENERGYFLEX-evening.evidence.json
```

The standard-library Python verifier separately implements scheduling, constraint
checking, cost accounting and full enumeration. It verifies the checksum, then
replays the declared algorithms and compares all computed results. Even a
re-hashed export is rejected when its result no longer matches the declared
inputs. File size, syntax, duplicate JSON keys and model/search sizes are bounded.

This is computational replay of a declared synthetic problem, not authentication
of the inputs. A party can legitimately construct another fixture and compute
its own valid result. Neither the checksum nor the replay proves sensor
provenance, physical truth, identity, field savings or safety certification.

## ECAI / DamageBDD execution status

**Implemented:** public dashboard integration, conventional reference scheduling,
local constraint verification, exported evidence, independent Python replay,
Node tests, browser acceptance tests and safe installer tests.

**Not invoked by this release:** native ECAI indexing/retrieval, LLM inference,
DamageBDD backend execution, cross-node attestation, blockchain writes or live
charger control. The UI and evidence explicitly preserve that boundary. There is
no Gherkin file labelled as an executed DamageBDD test. A future native adapter
must preserve the same problem contract, expose real execution receipts, and
retain equivalent conventional baselines.

## Tests

Node 22+ and Python 3.10+ are sufficient for model/replay tests. Browser tests also
require Python Playwright and Chromium. No production dependency is added.

```sh
node --test apps/ecai/test/energyflex/model.test.mjs
python3 apps/ecai/test/energyflex/verifier_test.py
python3 apps/ecai/test/energyflex/browser_test.py
python3 apps/ecai/test/energyflex/console_browser_test.py
```

`CHROMIUM=/path/to/chromium` can select a browser. `ENERGYFLEX_TEST_OUT=/tmp/ef`
selects where browser results/screenshots are written. Browser tests use actual
source, offline DOM and module URLs. The console test stubs unrelated workspaces
and the auth/API transport. In the offline about:blank context, browser export
uses a test-only SHA-256 adapter; the real WebCrypto call is covered by Node.
No real Cowboy listener, full Erlang umbrella build or production authentication
service is exercised by those tests.

## Deployment acceptance

After normal asset/release deployment, open `/dashboard#energyflex` in a private
browser window. Confirm the result is A$7.00 without a login modal, change each
scenario, and export/replay one evidence file. Navigate away during playback and
confirm it stops. Check the standalone URL too. Verify protected operations still
require their normal permissions. A hard refresh may be needed after deploying
new console/template assets; their URLs are versioned by the installer.
