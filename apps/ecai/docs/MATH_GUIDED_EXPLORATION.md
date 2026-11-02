# Mathematical Paths · guided exploration in ECAI

Open `/dashboard#math` (or `/#math` where the dashboard is hosted at the root).
The **five-stage guide** is designed for someone seeing elliptic curves for the
first time as well as a mathematician checking exact maps. The guide buttons
scroll within the Math panel and do **not** change the dashboard hash or start
server jobs. Existing public samples, node jobs, imports, verification,
provenance and exports retain their original IDs and behavior.

## 01 · Visualize (browser only)

The animation samples the *real* bounded component of the non-singular
Weierstrass curve

\[
E: y^2=x^3-4x.
\]

Affine drawing transforms turn samples into wing/petal contours; the dragonfly
body contains illustrative drawing primitives. The renderer resamples the
resulting contour at uniform arc-length intervals, computes finite DFT
coefficients, and evaluates

\[
 z_N(t) = \sum_{k=-N}^{N} c_k e^{2\pi i k t}
\]

for real time `t`. Raising the Fourier order improves the approximate contour.
These are finite floating-point computations and not the native math service.
In particular, the Fourier basis does **not** implement a rational isogeny or
semantic embedding. Source:
`priv/static/js/ecai-math-kernel.js`. Good visualization reference:
[Fourier rotating vectors](https://www.3blue1brown.com/lessons/fourier-series/).

## 02 · Experiment (local exact candidates)

Select one of the 13 curated, locally bundled mathematical examples. Each has
exact coefficient strings, a candidate path, mathematical question, points to
experiment with, and reference checks. The page can trace rational points with
BigInt arithmetic without contacting the node. This is **not** a fresh node
verification; status clearly says *Example preview*. One negative-control
example deliberately corrupts a map. Sources:
`priv/static/math-samples/`, `priv/static/js/ecai-math-samples.js`,
`priv/static/js/ecai-math-exact.js`.

## 03 · Explore (managed account, native service)

Open the path editor to choose either source-only bounded exploration or
source/target discovery over `Q`. Input coefficients are integers or fractions,
not floating-point. Search bounds constrain hop count, model count, candidate
rational degree-2 kernels, and (for source-only exploration) time. The
pathfinder does not assert that the bounded search discovered the entire
isogeny class or a global shortest route. Source:
`src/ecai_math_pathfinder.erl`, `src/ecai_math_explorer.erl`, and
`src/ecai_math_dashboard_task.erl`. Background:
[SageMath elliptic curves](https://doc.sagemath.org/html/en/reference/arithmetic_curves/index.html)
and [SageMath isogenies](https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/ell_curve_isogeny.html).

## 04 · Verify (exact proof scope and provenance)

The ordered graph conveys *composition*, not Euclidean distance or shortest
path. Select a curve to inspect its rational coefficients, invariants and
model identity, or select a map to inspect the rational formula and degree.
A single point experiment is useful debugging, not an all-points proof.
Live node replay performs exact polynomial-identity checks for the selected
maps. The Verification, Search & bounds, and Run & provenance tabs separate
what was checked from what was searched and who/what generated the artifact.
Exported path JSON keeps rational values as exact strings. Bundled example
checks and fresh node checks are distinct. Sources:
`src/ecai_math_isogeny.erl`, `src/ecai_math_dashboard_task.erl`,
`priv/static/js/ecai-math-paths.js`.

## 05 · Connect to ECAI (architecture and limits)

The currently documented ECAI knowledge layer includes source-indexed
retrieval, retained provenance, typed relations, model access controls and
review surfaces. See the [ECAI capability and evidence guide](https://damagebdd.com/ecai/).
The mathematical pathfinder is a **separate** exact-math capability: a map
between elliptic curves does not by itself establish a semantic relationship,
source truth, equivalence of human-language assertions, or that a BDD behavior
was executed. A semantic-to-curve bridge needs:

1. A precise versioned encoding for semantic objects and relations.
2. Testable preservation conditions from relation operations to curve/maps.
3. Replayable links back to source identities, query inputs and DamageBDD
   behavior evidence.
4. Negative tests and independent validation across the bridge.

The UI labels this boundary explicitly. No hidden inference or production
integration with the math kernel is claimed.

## Native integration details

- Main template: `priv/templates/ui/dashboard/ecai_math_paths.mustache`.
- Navigation and existing samples/jobs: `priv/static/js/ecai-math-paths.js`.
- Visualizer: `priv/static/js/ecai-math-kernel.js`.
- Scoped responsive CSS: `priv/static/css/ecai-math-paths.css` and
  `priv/static/css/ecai-math-kernel.css`.
- Browser UI test: `test/math_dashboard/guide_browser_test.py`.
- Contracts: `test/test_math_dashboard_contract.py`.

The CSS and JS query strings use `math-guided-journey-v1` so a deployed
browser does not retain the prior layout or navigation handlers.

### Run smoke tests

```sh
node --test apps/ecai/test/math_dashboard/kernel.test.mjs \
  apps/ecai/test/math_dashboard/view_model.test.mjs \
  apps/ecai/test/math_samples/samples.test.mjs
python3 -m unittest apps/ecai/test/test_math_dashboard_contract.py
python3 apps/ecai/test/math_dashboard/guide_browser_test.py
python3 apps/ecai/test/math_dashboard/browser_test.py
```

Browser tests use synthetic auth and local fixtures; they cannot establish
native Erlang compilation or live service availability. Native tests still
require OTP, rebar3, and the umbrella app dependencies.
