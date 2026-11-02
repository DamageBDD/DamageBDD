# Mathematical paths: public example library and exact workbench

This update adds **13 bundled candidates: 12 valid examples and one deliberately
corrupted negative control**. A new visit to `/dashboard` without a workspace hash
opens Mathematical paths and loads the doubling example immediately. Explicit
hashes such as `#search` and `#overview` still select their respective workspaces.

No login, payment, server job, or native verification is triggered by loading or
selecting a public example. The ordinary console may perform its existing session
and node-status reads. The mathematical preview itself is local.

## Install

Two patches are supplied; apply **one**, not both:

- `ecai-math-samples.patch`: incremental update **after** the previous
  `ecai-math-dashboard-integration.patch`.
- `ecai-math-dashboard-with-samples.patch`: the original dashboard integration
  **plus** this update, against the unmodified `latest-ecai.tar(1).gz` upload.

From the DamageBDD repository root, for an already-integrated dashboard:

```bash
git apply --check ~/Downloads/ecai-math-samples.patch &&
git apply ~/Downloads/ecai-math-samples.patch

bash apps/ecai/test/math_samples/run.sh
bash apps/ecai/test/math_dashboard/run.sh
rebar3 compile
```

The sample runner needs Node with ES-module support, Python 3, and Erlang/OTP 27+
for its native gate. It runs local JavaScript and Python tests before requiring
Erlang; missing Erlang exits explicitly with status 127, not a passing native test.

Deploy the templates, CSS and JavaScript together using the normal release process.
Asset versions are bumped in the shell and its module imports. The incremental
patch changes no production Erlang module, route, supervisor, authentication rule
or application setting. When installing the combined patch for the first time,
follow `DASHBOARD.md` and restart the service to start the job coordinator.

## First two minutes

Open `/dashboard` or `/dashboard#math`. The default is **Doubling on the n = 6
curve**. It factors multiplication by 2 into two degree-2 quotients followed by a
degree-1 scaling:

```
y² = x³ − 36x  →  y² = x³ + 144x  →  y² = x³ − 576x  →  y² = x³ − 36x
     deg 2               deg 2                deg 1
```

The displayed source point follows the exact rational trace:

```
(12,36) → (9,45) → (25,−35) → (25/4,−35/8).
```

Select **Calculate by group law** with `[2]P` to independently calculate the same
endpoint on the source curve. This is a nontrivial degree-4 endomorphism even though
source and target models are equal. Asking endpoint search for a path from a curve
to itself can return the degree-1 identity instead: these are different problems.

Use the selector or previous/next controls to change examples. Expand **Browse the
complete collection** to filter by a phrase such as `degree 5`, `kernel`, or
`rational`. Each example has a mathematical question and suggested rational points.

Select a curve for its equation, exact j-invariant, model discriminant, c4/c6 and
approximate real-coordinate illustration. Select an arrow for its rational functions,
coefficients, map ID and verification scope. The graph shows ordered occurrences;
a repeated model is not collapsed out of an endomorphism path.

**Use these endpoints in the editor** fills exact coefficients and suggested search
bounds. You can edit them before explicitly starting an authenticated degree-2
search. **Verify this example on node** instead submits the selected explicit maps
to the existing import/replay API; these buttons perform different operations.

## The collection

| ID | Problem | Composite degree | Native degree-2 endpoint discovery? |
| --- | --- | ---: | --- |
| `doubling-6` | [2] on y²=x³−36x; compare map composition with the group law | 4 | No: equal endpoints alone would allow the identity |
| `congruent-6` | Rational quotient of y²=x³−36x, including a non-torsion point trace | 2 | Yes, within the suggested bounds |
| `legendre-3-k0` | Quotient of y²=x(x−1)(x−3) by the kernel at x=0 | 2 | Yes |
| `legendre-3-k1` | Same non-CM source, kernel at x=1 | 2 | Yes |
| `legendre-3-k3` | Same non-CM source, kernel at x=3 | 2 | Yes |
| `half-kernel` | Rational coefficients and a kernel at x=1/2; change denominator bounds | 2 | Yes, with a sufficient denominator bound |
| `mordell-3` | y²=x³+1 → y²=x³−27 with an explicit rational degree-3 map | 3 | No; replay the supplied map |
| `mixed-6` | Compose the degree-3 map with a rational degree-2 quotient | 6 | No; replay the supplied mixed-degree path |
| `tripling-j0` | [3] as 3 × 3 × 1, returning to y²=x³+1 | 9 | No; equal endpoints do not specify [3] |
| `five-11a` | Rational degree-5 Vélu quotient from the conductor-11 example | 5 | No; replay the supplied map |
| `noncm-eight` | Three degree-2 steps from y²=x³+x²−2x; compare depth 2 and 3 | 8 | Yes, with sufficient depth |
| `rational-scale` | Degree-1 scaling by u=2/3 on y²=x³−36x | 1 | No; degree-2 discovery does not generate scaling maps |
| `tampered-control` | Deliberately corrupted Y numerator: must be rejected | Claimed 2 | Do not treat as a valid map |

“Can discover” describes the supported generator and suggested bounds, not a claim
that a new live search has already run. Bounded failure is not a nonexistence proof.

The conductor-11 source is the completed-square model
`y²=x³−x²−10x−79/4` of the LMFDB **11.a2 / Cremona 11a1** curve, whose original
model is `y²+y=x³−x²−10x−20`. The quotient has coefficients
`a2=-1, a4=-7820, a6=-1054319/4`. The target is an explicit quotient model, not a
claim that those coordinates are the minimal model displayed by a database.
The catalog links to the original data and SageMath primary documentation.

## Exact arithmetic, illustrations and evidence

- Browser point traces, curve invariants and scalar multiplication use **bounded
  BigInt rational arithmetic**, not floating-point approximation. Off-curve inputs
  fail explicitly. Kernel poles use infinity in the supported isogeny chart.
- A point experiment checks that point and the displayed chain. It is **not** an
  all-points isogeny proof. The exact native replay checks full polynomial identities.
- The SVG real-locus chart uses approximate coordinates **only for illustration**;
  it does not identify rational points or establish map validity. These are plots
  of the displayed cubic equations, not ellipses or arbitrary shape morphs.
- Public candidates have amber preview badges, **no native receipt** in their
  exported path JSON, and no invented run IDs, timings, payment amounts or reports.
- A separate **build-time Python reference-check record** is bundled with the exact
  fixture SHA-256. It is not a fresh check on the visitor's node or an authenticated
  provenance certificate. The negative control records the expected rejection.
- The generated native content IDs are tested against three known native IDs from
  the earlier working demo. Every new sample still has a supplied native replay gate.
- A successful live result uses the unchanged account-scoped job API and produces
  a fresh native receipt. Sign-in is required to start this work. A wallet identity
  alone does not bypass the managed-account requirement. No automatic job, wallet
  charge, public endpoint, or privileged sample API is added.
- Account switching clears private results and edited private inputs, and reloads
  a public sample. Late responses cannot overwrite a newer sample selection.

Local arithmetic is bounded at 4,096-bit intermediate rational components, 16 maps,
65 coefficients per polynomial and 310 characters per rational input component.
The endpoint editor retains the backend's stricter limits. Source models and
discriminants are not automatically reduced to minimal models.

## Export and share

**Export path JSON** downloads the exact standalone candidate or native checked path.
The native importer checks its content IDs and algebra; it does not trust a submitted
verification flag. Each fixture file is also served under `/static/math-samples/`.

**Export evidence bundle** archives a wrapper with the sample/check record or live
job data. The wrapper itself is not accepted as a path upload; extract its path JSON
or use Export path JSON for import.

**Export SageMath check** downloads a script using Sage's exact rational arithmetic
and polynomial ring to check all map identities, degrees and endpoint continuity:

```bash
sage -python ecai-math-check.py
```

This export was syntax-checked, not executed with Sage in the delivery environment.
It does not check native ETF identifiers, signatures or provenance. Run without
Python's `-O`, because the generated check uses assertions.

**Copy example link** copies an allowlisted public selection, for example:
`/dashboard?math_sample=five-11a#math`. It constructs a new URL rather than carrying
existing query parameters (such as authentication parameters) into the shared link.
Unknown example IDs fall back to the default. No private job is shared by this action.

## Regenerate and validate

The runtime library is bundled and has no SymPy, Sage, CDN or external API dependency.
SymPy is a build-time dependency **only** for regeneration:

```bash
python3 apps/ecai/test/math_samples/generate_samples.py
python3 apps/ecai/test/math_samples/test_samples.py
node --test apps/ecai/test/math_samples/samples.test.mjs \
  apps/ecai/test/math_dashboard/view_model.test.mjs
bash apps/ecai/test/math_samples/run.sh
```

The generator constructs and normalizes rational maps, calls the existing
independent exact-polynomial checker on all 12 positive paths, rejects the negative
control, and compares [2] and [3] symbolically with chord-and-tangent formulas.
The degree-5 map is constructed from the rational five-torsion kernel, rather than
being a label-only lookup. Catalog data, exact JSON files and the JS bundle are
regenerated together; tests compare bytes and SHA-256 hashes.

Browser tests (Playwright + Chromium) use production UI modules with synthetic
auth/API responses for live controls; they never access a funded node:

```bash
python3 apps/ecai/test/math_samples/browser_samples_test.py
python3 apps/ecai/test/math_dashboard/browser_test.py
python3 apps/ecai/test/math_dashboard/console_browser_test.py
```

Delivery validation: 65 Node tests; 6 sample Python test methods with per-fixture
subtests; 12 existing independent reference tests; 21 selected dashboard contract
tests; and 40 browser checks (17 sample, 15 workspace regression, 8 actual-console).
All of those passed. **Native sample EUnit, native dashboard EUnit, Sage execution,
full umbrella compilation and authenticated deployment were not run here.**

The supplied native sample EUnit suite includes 13 generated cases and checks IDs,
native replay, codec round trips and point evaluation. It must pass on the target
Erlang machine before treating the new fixtures as natively accepted.

The broader `test_console_contract.py` suite has two unchanged baseline failures
(out of 20): an old route-layout string assertion and an old fixed code-review
remote assertion. Both were reproduced against the previous integration baseline;
neither relevant production file was changed to conceal them. See the delivery
validation JSON for exact names and commands.
