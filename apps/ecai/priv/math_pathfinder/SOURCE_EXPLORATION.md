# Source-only mathematical exploration

The new **Explore from source** mode asks for one exact curve and finite bounds.
No destination, preloaded graph, remote catalogue or learned answer is supplied.
The existing **Connect two given curves** mode remains available.

## Patch base and installation (rebased delivery)

`ecai-source-only-explorer-rebased.patch` applies directly to the uploaded
`latest-ecai.tar(2).gz` snapshot (SHA-256
`a41e62ef2af500f92f8937970b8e23b0d0201edf3933e01a4b53dbd65c2115df`).
That snapshot already includes the mathematical dashboard integration and the
13-example public workbench. Use this patch **instead of** the previous explorer
incremental/combined patches; do not stack both versions.

The source archive contains `apps/ecai` only. This patch also adds the two
previously supplied DamageBDD explorer feature/step files unchanged. It never
modifies an existing DamageBDD file from an unseen base. `git apply --check` will
stop if those new paths already exist; compare the existing files rather than
force-overwriting them.

```bash
# From the full DamageBDD repository, at the uploaded latest snapshot:
git apply --check ~/Downloads/ecai-source-only-explorer-rebased.patch &&
git apply ~/Downloads/ecai-source-only-explorer-rebased.patch

# Compile and execute the native tests; export actual native evidence.
bash apps/ecai/test/math_explorer/run.sh --export "$PWD/ecai-exploration.json"

# Independent check of the newly exported native report.
python3 apps/ecai/test/math_explorer/reference_checker.py "$PWD/ecai-exploration.json"

bash apps/ecai/test/math_dashboard/run.sh
bash apps/ecai/test/math_samples/run.sh
rebar3 compile
```

The export command refuses to overwrite an existing file. Use another filename
for a subsequent run. Deploy templates, JavaScript, CSS and BEAM files together,
then restart the ECAI service using your normal release process.

### Working alongside the latest public samples

The latest landing behaviour is preserved: `/dashboard` without a hash opens
Mathematical paths and locally loads the public doubling sample. No mathematical
job starts automatically. Explicit workspace hashes and public sample deep links
still work. All 13 sample JSON files, the catalogue, the bundled sample module
and the exact-arithmetic helper are unchanged by this rebase.

Expand **Edit a problem or import your own path**. Its question defaults to
**Explore from source · no target**. The displayed source is filled from the
selected public example; change it to any supported exact model. To reproduce
the seven-model reference experiment below, set `(a2,a4,a6) = (0,-1,0)`, depth 2,
numerator bound 8 and denominator bound 4, then explicitly submit the exploration
with a managed account.

**Use these endpoints in the editor** still selects the two-curve connection
mode. Switching back to source-only mode hides/disables target fields and caps
retained models at 32. Two-curve mode retains the existing 64-model maximum.

Exact point tracing, group-law calculations and SageMath export use the selected
exploration row's path. Changing rows clears stale point calculations. Selected
path exports preserve the original path JSON; an evidence bundle records the
selected model ID alongside the complete job. Loading a public example clears
private exploration rows and classification evidence and restores the explicit
preview badge. Account switches, sign-out and late-response guards remain active.

## Native API

```erlang
application:ensure_all_started(crypto).
{ok, Seed} = ecai_math_curve:new(0, -1, 0).
{ok, Exploration} = ecai_math_explorer:explore(Seed, #{
    max_depth => 2,
    max_curves => 24,
    numerator_bound => 8,
    denominator_bound => 4,
    timeout_ms => 20000
}).
maps:with([summary, stop_reason, completed_within_declared_bounds], Exploration).

%% Every result, including the seed's zero-hop path, is independently replayable.
Rows = maps:get(results, Exploration).
[{ok, _} = ecai_math_pathfinder:verify_path(maps:get(path, Row)) || Row <- Rows].
{ok, Json} = ecai_math_explorer:encode(Exploration).
ok = file:write_file("ecai-exploration-native.json", Json, [exclusive]).
```

`ecai_math_pathfinder:from_steps/2` assembles and checks a path from explicit maps,
without requiring a target argument or a stored graph. It does not accept a
submitted `verified` flag as evidence.

## What is explored

The explorer performs deterministic breadth-first expansion of exact curve
models. It enumerates rational cubic roots within numerator/denominator bounds,
constructs degree-2 isogenies, checks them, and retains one checked witness path
per distinct exact model. Revisited models do not replace earlier witnesses.
Neither shortest global isogeny degree nor a complete isogeny class is claimed.

The result list includes the source as a zero-hop path. `max_curves` counts that
source. Every accepted row includes its exact curve, local class, source-comparison
certificate, class-membership certificate, and checked path. IDs label exact
objects; mathematical checks do not rest on hash proximity. Conflicting models
with the same model identifier stop the exploration rather than being merged.

An independent Python reference calculation for `y²=x³-x`, depth 2, numerator
bound 8 and denominator bound 4 gives these expected results:

| Exact model | Q-relation to source |
| --- | --- |
| `y²=x³-x` | Source |
| `y²=x³+6x²+x` | Non-isomorphic |
| `y²=x³+4x` | Non-isomorphic |
| `y²=x³-6x²+x` | Non-isomorphic |
| `y²=x³-12x²+32x` | Isomorphic |
| `y²=x³-16x` | Isomorphic |
| `y²=x³+12x²+32x` | Isomorphic |

That is seven models in four local Q-isomorphism classes, including three models
non-isomorphic to the source. These are **reference expectations**, not a native
run claimed by this delivery. The native EUnit assertions check these results on
your machine. Different inputs and bounds produce different explorations.

## Exact Q-isomorphism decisions

`ecai_math_isomorphism:compare/2` translates each supported model into short form:

```
A = a4 - a2²/3
B = a6 - a2*a4/3 + 2*a2³/27
j = 1728 * 4*A³ / (4*A³ + 27*B²)
```

For short models, a forward rational scale must satisfy
`A_target=u⁴*A_source` and `B_target=u⁶*B_source`, with nonzero rational `u`.

- Different j-invariants establish non-isomorphism.
- For `j=1728`, the A ratio must be a rational fourth power.
- For `j=0`, the B ratio must be a rational sixth power.
- Otherwise, `(B_target/B_source)/(A_target/A_source)` must be a rational square,
  and the fourth/sixth-power coefficient equations are also checked.

Rational powers are decided by integer-root brackets on reduced numerators and
denominators, not floating-point approximations or integer factorisation. A
positive decision includes an explicit degree-1 map checked by the existing exact
map verifier. A negative decision includes the invariant or power obstruction.
Unsupported/oversized arithmetic produces an error or partial stop, never a
fabricated non-isomorphism decision. This covers the existing nonsingular Q-model
family with `a1=a3=0`; it does not add finite fields or general number fields.

`ecai_math_isomorphism:verify(Source, Target, Certificate)` recomputes and compares
the certificate. Local classes are grouped among retained models only; labels
like class 2 or a representative model ID are not global canonical class IDs.
Crucially, **isomorphic models are not pruned during search**: root bounds depend
on coordinates, so that pruning could lose paths available in another model.

The standard Weierstrass isomorphism convention is documented by SageMath:
https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/weierstrass_morphism.html
Our forward scale convention is `X=u²*x+shift`, `Y=u³*y`; Sage's displayed
`(u,r,s,t)` convention uses the inverse transformation.

## Dashboard and HTTP

The same account-scoped job endpoint accepts a source-only request:

```json
{
  "operation": "explore",
  "source": {"a2": ["0", "1"], "a4": ["-1", "1"], "a6": ["0", "1"]},
  "bounds": {"max_depth": 2, "max_curves": 24, "numerator_bound": 8,
             "denominator_bound": 4, "timeout_ms": 8000}
}
```

POST this to `/ecai/math/jobs` through the existing authenticated wrapper.
Supplying a `target` with `explore` is rejected. Coefficient components remain
strings. Account controls, bearer requirements, rate/concurrency limits, no-store
headers, same-origin policy and node-local retention remain in effect.

Successful exploration jobs return `result.exploration` and the exact
`result.exploration_json`. Every serialized result row contains `path_json`, not a
second mutable copy of that path object. The dashboard parses it for display and
preserves the original bytes for export. A complete report export is distinct
from a single path export.

Select a model to inspect its path and Q-classification evidence. A filter shows
only non-isomorphic-to-source models, without hiding the fact that the selected
path can belong to another row. Native replay for an exploration requires a
specific model selection:

```
POST /ecai/math/jobs/:id/replay
{"model_id":"<retained model ID>"}

GET /ecai/math/jobs/:id/path/:model_id
```

The service looks up that model inside the authenticated owner's existing job;
it does not accept a client-submitted replacement path for this route. Missing
selection returns 409; another account's job or an unknown model returns 404.
A replay is a new single-path job with `replayed_job_id` and `replayed_model_id`.
The older single-path replay/download routes are unchanged.

## Budgets and honest partial results

Exploration limits: at most depth 3, 32 retained models, numerator bound 32,
denominator bound 16, and a requested time budget up to 20,000 ms. Defaults are
depth 2, 24 models, bounds 8/4 and 8,000 ms. The serialized report is limited to
256 KiB; row insertion stops before the row-data budget is exceeded. The HTTP
result includes the parsed report and its original JSON string, so that response
is larger than the standalone report. The existing HTTP input limit stays 256 KiB.

A model, time, export-size or arithmetic/checking stop retains preceding checked
results and explicitly sets `completed_within_declared_bounds=false`.
The time budget is cooperative and checked between operations, not a hard
real-time deadline; an in-flight arithmetic/encoding operation can overrun it.
An outer 45-second native watchdog and the existing 60-second dashboard watchdog
remain hard failure safeguards. A watchdog/worker crash can fail the entire job;
partial recovery is not promised for that case.

`bounded_search_exhausted` means only the declared depth and coordinate-bounded
search was processed. `global_completeness` and `novel_to_mathematics` are always
`not_claimed`. There is no complete search-event graph, corpus-novelty check,
formal proof-assistant certificate, settlement, NFT minting or automatic IPFS
publication in this extension.

## Independent report checker

Export **exploration JSON**, then run:

```bash
python3 apps/ecai/test/math_explorer/reference_checker.py /absolute/path/report.json
```

This standard-library checker independently checks path algebra, Q-isomorphism
decisions, integer-root certificates, local groups, summary counts and SHA-256 of
each embedded path's UTF-8 bytes. It does not check native Erlang ETF IDs,
signatures, provenance, timing, search completeness or mathematical novelty.

For just one selected path, use the existing checker:

```bash
python3 apps/ecai/test/math_pathfinder/reference_checker.py /absolute/path/path.json
```

The dashboard's import control still accepts single mathematical-path JSON, not
exploration reports or evidence-bundle wrappers. The independent checker result
is not automatically attached as a dashboard badge.

## DamageBDD acceptance

New feature: `apps/damage/features/ecai/mathematical_source_exploration.feature`.
Its two scenarios exercise source-only classification and partial-result
retention. The corresponding new step module is
`apps/damage/src/steps_ecai_math_explorer.erl`. It writes the native report and
exported report JSON to the scenario context. It does not silently publish the
context, associate an older report CID, or claim the new feature has run.

## Validation boundary

Local validation uses the independent Python reference and Chromium with synthetic
API/auth fixtures. `fixtures.py` creates Python test data with fixture-scoped
identifiers; it is not a native Erlang execution and its data must not be advertised
as one. The UI previews are clearly marked as synthetic API previews.

Erlang/OTP was unavailable in the delivery environment. Native compilation/EUnit,
real authenticated Cowboy calls, full release deployment and the new deployed
DamageBDD feature execution remain **unrun here**. Native runners contain 42 new
explorer tests and 39 dashboard/handler tests. Existing core regression tests also
remain in the repository. Test-only auth/Cowboy adapters retain `.erl.fixture`
extensions and must never enter a release.

```bash
python3 apps/ecai/test/math_explorer/reference_tests.py
python3 apps/ecai/test/math_explorer/browser_test.py
python3 apps/ecai/test/math_dashboard/browser_test.py
python3 apps/ecai/test/math_dashboard/console_browser_test.py
node --test apps/ecai/test/math_dashboard/view_model.test.mjs
```

## Rebase validation

Executed against this rebased tree: 65 Node tests, 27 independent Python explorer
tests, 12 Python pathfinder reference tests, six sample-test methods (with
per-fixture checks), 21 selected static dashboard contract tests, and 65 browser
checks (17 sample, 25 source-only/cross-feature, 15 workspace, eight console).
Browser checks use synthetic API/auth fixtures, not a live node. Generated Sage
scripts were syntax-checked, not executed in Sage. Native compilation/EUnit and
full release deployment remain unrun because the build environment has no Erlang.

The broader 33-case dashboard group remains at 30 passing cases, exactly matching
the untouched new upload. Its existing failures are the route-layout string
assertion and fixed code-review remote assertion; its existing error is the
missing `apps/damage/src/ecai_mm.erl` file in this ECAI-only archive. No unrelated
production files were changed to conceal those issues.
