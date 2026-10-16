# ECAI Mathematical Pathfinder

An additive, stateless Erlang implementation of a first mathematical pathfinder:
**discover candidate rational isogenies, search a directed graph, and replay exact
algebraic checks for every returned transformation.**

This first application is elliptic-curve arithmetic, not a general theorem prover.
It does not infer mathematical similarity from distances between hashed curve
points. Hashes identify exact models, maps and path records; they do not establish
mathematical truth or the truth of source/provenance labels.

## Installation and isolated tests

Apply the patch at the DamageBDD repository root. It adds files only. It does not
replace `ecai_sup.erl`, `ecai_relation.erl`, `rebar.config`, the NIF, or existing
application configuration. The new source modules are picked up by the existing
`ecai` application build; there is no new registered server or startup hook.

Requirements: Erlang/OTP **27 or later** (the JSON codec uses OTP's `json` module),
`crypto`, compiler and EUnit. No SageMath, Python, network, GPU or ECAI NIF is
needed for native discovery, map verification, graph search or the demo.

```bash
bash apps/ecai/test/math_pathfinder/run.sh --demo
rebar3 compile
```

The isolated runner compiles only the new math modules, the new DamageBDD step
module, and the existing `ecai_relation.erl` when present. It does not build the
rest of the release or download dependencies. It uses a temporary BEAM directory
and compiles the new modules with warnings as errors.

## First result

Inside the release's Erlang shell:

```erlang
application:ensure_all_started(crypto).
{ok, Path} = ecai_math_pathfinder:demo().
maps:with([hops, total_degree, total_cost, id], Path).
{ok, Proof} = ecai_math_pathfinder:verify_path(Path).
```

The demo contains explicit maps along:

```text
E0: y² = x³ − x
  -- degree 2 --> E1: y² = x³ + 4x
  -- degree 2 --> E2: y² = x³ − 16x
```

Expected totals: two hops, cost two, composite degree four. Each map is represented
by its rational functions, not merely by an endpoint label or degree claim.

These endpoint models are also isomorphic by `(x,y) -> (4x,8y)`; the two-hop demo
is deliberately a restricted graph example, not a claim that degree four is the
smallest possible isogeny between the endpoints. Search optimizes **positive edge
cost within the supplied graph and depth bound**, not global isogeny degree.

## Discover the maps rather than hand-load them

```erlang
{ok, Source} = ecai_math_curve:new(0, -1, 0).
{ok, Target} = ecai_math_curve:new(0, -16, 0).
{ok, DiscoveredPath} = ecai_math_pathfinder:solve_two(
    Source, Target,
    #{max_depth => 2, numerator_bound => 8, denominator_bound => 4}
).
```

`solve_two/3` constructs a fresh graph by enumerating rational two-torsion
kernels, constructs explicit degree-2 quotient maps, checks them, and searches
the resulting graph. For a source `y²=x³+a2*x²+a4*x+a6`, it enumerates reduced
rationals `r=n/d` within the supplied numerator/denominator bounds, retains roots
of the cubic, and uses the subgroup `{O,(r,0)}` as a kernel.

This search is explicitly **incomplete outside those bounds**. It is neither a
complete rational-root solver nor a complete isogeny-class enumerator. More
advanced candidate generators can supply maps to the same checker.

`expand_two(Graph, Source, Options)` returns the graph without running a target
query. Defaults: depth two, 64 visited curve models, `|n|<=8`, `1<=d<=4`.
Expansion depth is capped at four, visited models at 256, and wall time at 30
seconds. Hitting the curve limit returns an error, not an apparently complete
partial graph.

## Build, query, and evaluate a graph

```erlang
{ok, E0} = ecai_math_curve:new(0, -1, 0).
{ok, Phi} = ecai_math_isogeny:two(E0, 0).
E1 = maps:get(codomain, Phi).
{ok, Psi} = ecai_math_isogeny:two(E1, 0).
E2 = maps:get(codomain, Psi).

{ok, G1} = ecai_math_pathfinder:add_isogeny(
    ecai_math_pathfinder:new(), Phi,
    #{cost => 1, source => <<"local exact kernel construction">>}
).
{ok, G2} = ecai_math_pathfinder:add_isogeny(G1, Psi).
{ok, Path} = ecai_math_pathfinder:find(G2, E0, E2, #{max_depth => 8}).
{ok, infinity} = ecai_math_pathfinder:apply_path(Path, {1, 0}).
```

`add_isogeny` canonicalizes structure but stores a **candidate**, not a trusted
verification flag. `find` rechecks candidate maps before traversal and memoizes
those checks only within that query. Failed or resource-limited checks make the
edge unusable for that query. A returned path can be rechecked without access
to the graph using `verify_path/1`.

Curves may be passed directly or by `ecai_math_curve:id(Curve)`. Graph limits are
4,000 exact models and 10,000 candidate maps. Re-inserting the same map merges
up to 16 source labels; a conflicting edge cost returns `duplicate_cost_conflict`
rather than silently changing the optimization problem.

`ecai_math_isogeny:scale(Curve, U)` constructs the degree-one map
`(x,y) -> (U²x,U³y)` for nonzero rational `U`.

## What the checker establishes

Supported domain and codomain models are nonsingular elliptic curves over **Q**:

```text
y² = f(x) = x³ + a2*x² + a4*x + a6
```

A candidate supplies:

```erlang
#{kind => isogeny,
  domain => SourceCurve, codomain => TargetCurve, degree => 2,
  x_num => [-1,0,1], x_den => [0,1],
  y_num => [1,0,1], y_den => [0,0,1]}.
```

Polynomial coefficients are in **ascending** order. Integers and `{N,D}` exact
rationals are accepted by the native API. Floats are rejected. Both rational
functions are reduced and denominators made monic before map identity is computed.

For `X=N/D` and `Y=y*M/L`, the checker establishes the exact polynomial identity:

```text
f_source * M² * D³
 = (N³ + a2_target*N²*D + a4_target*N*D² + a6_target*D³) * L².
```

It also checks nonsingularity, a nonconstant reduced X map, its declared degree,
and pole orders at the origin: `deg(N)-deg(D)=1` and `deg(M)=deg(L)`. These are
checked over Q, not using rounded coordinates or a few randomly chosen points.
Under the standard smooth-projective-curve facts that a nonconstant rational map
extends to a morphism and an origin-preserving morphism of elliptic curves is a
homomorphism, this validates the stated rational isogeny. In characteristic zero
there is no inseparability ambiguity. The degree is the degree of the reduced
rational X function.

A path receipt rechecks exact endpoint continuity and multiplies the degrees.
It retains a **factored composition**: it does not expand all steps into a single
large rational function. `apply_path/2` evaluates the factors in order, handling
kernel points and infinity. An unsupported affine exceptional case is reported
as an error rather than guessed.

This is executable exact-algebra verification, **not a Lean kernel certificate**;
receipts explicitly include `formal_proof => false`. The checker implementation,
Erlang integer arithmetic, and the stated mathematical facts are part of the
trusted basis. “Verified” does not authenticate an external source label.

## Search correctness and resource limits

The search uses deterministic, positive-weight Dijkstra traversal. Dominance is
tracked by **{curve ID, hop count}**, not just curve ID: an inexpensive but deep
arrival must not discard a costlier short arrival that can still reach the goal
within the hop bound. Sorted outgoing map IDs make insertion-order-independent
results reproducible. Identity paths have zero steps, cost zero and degree one.

Defaults:

```erlang
#{max_depth => 8, max_states => 10000,
  max_frontier => 10000, timeout_ms => 5000}.
```

Search limits fail explicitly. `not_found_within_bounds` means only that the
searched graph, verified usable edges and requested bounds yielded no path; it is
not a theorem that the mathematical objects are unrelated.

Native map degree is capped at 32; input polynomials at degree 64; curve/map
coefficient numerators and denominators at 1,024 bits; intermediate rational
integers at 8,192 bits. Polynomial intermediates are also degree-limited. A
mathematically valid input may therefore be refused as resource-limited.

Operations run in monitored, heap-limited BEAM workers with deadlines. These are
local computation safeguards, **not an OS isolation boundary**. Some operations
invoke another bounded worker; cancellation can leave that inner worker running
until its own short deadline. There is no public HTTP endpoint in this patch.
Any future network-facing service needs authentication, admission control and
appropriate process/OS isolation before accepting expensive workloads.

## Persist and independently replay evidence

```erlang
ok = ecai_math_codec:save("math-path.json", Path).
{ok, ReloadedPath} = ecai_math_codec:load("math-path.json").
{ok, _} = ecai_math_pathfinder:verify_path(ReloadedPath).
```

Save uses exclusive creation and returns `{error,eexist}` rather than overwriting
an existing receipt. Files are local JSON, not automatic IPFS publication, NFT
minting, signatures, consensus, or an append-only audit service. Load re-verifies
a path even when its JSON contains a submitted “verified” status.

JSON rational coefficients are `["numerator","denominator"]` decimal strings,
so they do not lose precision in JavaScript tooling. Graphs round-trip without
trusting serialized adjacency indexes. JSON decoding never turns arbitrary keys
into Erlang atoms, never uses `file:consult`, and never evaluates source code.
Integers beyond JavaScript’s exact range are also emitted as decimal strings.
Input is capped at 2 MiB. Hashes use versioned, domain-separated deterministic
Erlang external-term encodings. They are local content identities, not signatures
or universal cross-language/cross-implementation identifiers.

An independent standard-library Python checker is included:

```bash
python3 apps/ecai/test/math_pathfinder/reference_checker.py math-path.json
python3 apps/ecai/test/math_pathfinder/reference_tests.py
```

It uses a different identity-checking route: a rigorous polynomial degree bound
and exactly `bound+1` distinct exact evaluations of the denominator-cleared
polynomial. That establishes the polynomial identity, not merely empirical
agreement at sample points. It checks the map/chain algebra but **does not verify
Erlang ETF hashes, signatures, or provenance**.

The portable demo graph is in `apps/ecai/priv/math_pathfinder/demo_graph.json`.

## SageMath candidate generator (optional)

```bash
sage -python apps/ecai/priv/math_pathfinder/export_sage.py \
  --a2 0 --a4 -1 --a6 0 --depth 2 --degrees 2 3 5 \
  --output sage-graph.json
```

Then in Erlang:

```erlang
{ok, SageGraph} = ecai_math_codec:load("sage-graph.json").
ecai_math_pathfinder:stats(SageGraph).
```

The exporter enumerates explicit prime-degree isogenies and exports rational
functions. For the supported chart it derives the Y factor from the X derivative
and Sage's differential scaling factor; the Erlang checker does not trust that
derivation and checks the full identity independently. Exported records remain
candidates. No online LMFDB request or label-only assertion is treated as proof.
Run expensive Sage work in an appropriately restricted environment with an
external time limit. The helper itself does not create a security sandbox.

Exact curve models, not isomorphism classes, are graph nodes. Equivalent models
from different generators require explicit isomorphism maps to connect them;
this version does not canonicalize arbitrary models by j-invariant or perform
minimal-model conversion.

## ECAI and DamageBDD integration

```erlang
{ok, Relation} = ecai_math_pathfinder:to_relation(Path).
```

This verifies the path before calling `ecai_relation:new/4` with predicate
`{isogenous_over,q}` and attaching the replay record with `with_proof/2`. It does
not alter the existing generic composition rules or require the curve NIF. The
existing relation identity describes the endpoint claim; distinct map/path
identities are retained in the attached evidence. Deduplicating endpoint
relations is not an evidence-history store.

DamageBDD steps are added as `steps_ecai_math.erl`, with two Gherkin scenarios in:

```text
apps/damage/features/ecai/mathematical_pathfinder.feature
```

The scenarios cover explicit degree-2 composition and fresh bounded discovery.
The EUnit suite also invokes the step callbacks directly. Execute the feature
through your existing DamageBDD runner to obtain its normal report lifecycle.
The patch does not assert that a full deployed DamageBDD/IPFS/consensus run has
already occurred.

## Main files

| Module | Responsibility |
|---|---|
| `ecai_math_q` | Exact, normalized, bounded rational arithmetic |
| `ecai_math_poly` | Q[x], polynomial division and rational-function normalization |
| `ecai_math_curve` | Exact model identity, nonsingularity and point membership |
| `ecai_math_isogeny` | Candidate construction, map checking and point evaluation |
| `ecai_math_pathfinder` | Candidate graph, bounded discovery/search, replay and ECAI bridge |
| `ecai_math_job` | Monitored, deadline- and heap-limited local computation |
| `ecai_math_codec` | Fixed-key JSON interchange and exclusive receipt writes |
| `steps_ecai_math` | DamageBDD feature callbacks |

## Sources for the optional Sage adapter and mathematical conventions

- SageMath isogenies: https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/ell_curve_isogeny.html
- SageMath composite morphisms: https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/hom_composite.html
- SageMath general-field curve methods: https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/ell_field.html
- Erlang JSON module: https://www.erlang.org/doc/apps/stdlib/json.html

## Not implemented in this first version

No general theorem/lemma search, symbolic-expression identity corpus, Lean proof
export, finite-field isogeny backend, large-prime isogeny algorithm, automatic
LMFDB synchronization, persistent shared OTP graph service, web dashboard or
public HTTP API. Those can be built around the explicit-map checker and graph
interfaces without confusing retrieval evidence with a mathematical proof.
