# OTV-001 · Open Orbital Transfer Verification (ECAI console)

**Status:** integrated browser-side research demonstrator, not an aerospace validation tool.
**Open:** `/dashboard#orbital` (or `/#orbital` if the ECAI console is the root page).
**Requirements:** the existing ECAI console route and modern browser; no external JS, no credentials or privileged HTTP routes.

## What works now

- A native **Orbital verification** item in the existing ECAI navigation (`data-view="orbital"`).
- Interactive, perspective-projected 3D synthetic reservoirs with pan/orbit (drag), zoom (wheel), arrow keys, a transfer conduit, flow animation, and source/receiver fill levels. The mesh is rendered locally with Canvas 2D; this is an actual interactive 3D projection, **not** a physically validated fluid simulation.
- Seven deterministic scenarios (nominal plus six injected faults); 96 samples per replay. Tweak the seed for reproducibility.
- Six toy invariants: mass balance, valve/flow agreement, thermal index, pressure index, redundant sensor agreement, and timestamp monotonicity. Numeric thresholds are **synthetic, illustrative, dimensionless** and not spacecraft operating limits.
- Inspect first violation, rule counts, masses, local reference matching (an ECAI *integration stand-in*) and a three-lane telemetry chart.
- Download a JSON trace/evidence receipt with a local SHA-256 digest, or a Gherkin-style DamageBDD **blueprint**.
- Use `Present challenge` for fullscreen or `Copy technical pitch` to start an outreach message.
- Responsive desktop/mobile layout. The scene animation stops when the view is hidden, with no background simulation work and no external network call.

## Evidence verification

The export contains a SHA-256 digest over the compact `JSON.stringify(evidence_without_sha256)` representation. It is **not a signature**. It does not prove trusted sensor provenance or multiple nodes agreeing.

From the DamageBDD umbrella repository root, after applying the patch:

```sh
node apps/ecai/tools/verify_otv_evidence.mjs OTV-001-leak-1729.evidence.json
node --test apps/ecai/test/orbital_verification/otv_model.test.mjs
```

The verifier checks the SHA-256 digest, known generator version, declared scope, and a fresh re-execution of the same synthetic generator and invariants. A changed trace is rejected, even if re-hashed, unless it replays identically under the specified generator version/seed. This is a portable deterministic re-run in a separate process, not an independent modelling implementation.

`featureBlueprint()` exports a proposed Gherkin contract, *not* pre-registered DamageBDD steps. A follow-on change must implement and register the steps with the current DamageBDD executor and accept only bounded, versioned scenario IDs and seeds. A backend connection is intentionally absent from OTV-001.

## Division of responsibilities

| Present in OTV-001 | Future integration, **not** present |
| --- | --- |
| JS synthetic fixture generator and deterministic invariant checks | Native ECAI retrieval, elliptic curve-based indexing or mathematical proofs |
| Local toy reference pattern matcher | Comparative ECAI vs baseline counterexample search benchmarks |
| SHA-256 digest and same-model independent-process replay tool | DamageBDD distributed execution and independent node attestations |
| CPU-backed 3D presentation | SpaceX vehicle model, validated CFD/thermal analysis or spacecraft control |

The terminal/desktop client never transmits engineering data. There is no implied SpaceX affiliation, endorsement, flight safety claim or access to their internal systems.

## Integration points (minimal patch)

- `apps/ecai/priv/templates/ui/dashboard/ecai_console.mustache` — CSS link, navigation button and an inline new panel (so a deployed dashboard handler need not be changed).
- `apps/ecai/priv/static/js/ecai-console.js` — import, initialize, visibility, dispose, view label and wallet-guest navigation allowance.
- `apps/ecai/priv/static/js/ecai-orbital-model.js` — deterministic fixtures and checks.
- `apps/ecai/priv/static/js/ecai-orbital.js` — scene, chart, interactions and export.
- `apps/ecai/priv/static/css/ecai-orbital.css` — scoped style.
- `apps/ecai/tools/verify_otv_evidence.mjs` — standalone trace/digest replay verifier.

CSS and JS URLs are versioned `?v=otv001-v1`. No new Erlang HTTP handler is necessary for this browser-only panel. To integrate a live DamageBDD execution path, add an authenticated, narrowly scoped backend endpoint with fixed scenario IDs rather than accepting arbitrary remote scripts.

## Public development and IP

Use published research and synthetic data only. Keep proprietary/export-controlled launch vehicle specifications, internal telemetry and operational details out of the open benchmark unless properly cleared. You can retain and commercialize the ECAI and DamageBDD cores independently while setting a separate explicit license for the publicly contributed benchmark, after reviewing compatibility with the repository's current license. No license is granted or changed by this patch.

## Limitations and measurements to improve

- Toy mass balance assumes a closed two-reservoir system with `accounted_loss` of zero. A physical transfer system would need explicit phases, flows across system boundaries, sensor error models and thermodynamic relationships.
- Chart lanes use separate display axes and are not physical telemetry units.
- Reference analogues use local signature overlap, not ECAI native retrieval. Benchmark ECAI against exhaustive search and property-based baselines only when that integration is implemented.
- Browser-generated hashes establish accidental/tamper detection under a trusted generator/version, **not** authenticity.
- The standalone pitch page is a derivative of the integrated panel for direct demonstrations; it is not a hosted public site.
