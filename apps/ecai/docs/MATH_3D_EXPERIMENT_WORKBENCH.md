# ECAI · 3D geometric experiment workbench

Navigate to `/dashboard#math` or `/#math`. Within guided Stage 01, the
**Geometric experiment workbench** sits between the Fourier drawing and the
exact mathematical sample library. It requires no sign-in or network.

## Working capabilities

- **3D dragonfly**: Four triangulated wings. Their chordwise width follows
  the positive real branch of the bounded Weierstrass component
  `y² = x³ − 4x`. A lift and twist parameter determines the wing camber.
  Body, eyes and antennae are deterministic illustrative primitives.
- **Elliptic torus**: A tube swept along a lifted real oval, with three
  decorative braided guides and twistable cross-section.
- **Double helix**: Two tubular strands with radii modulated by the real
  Weierstrass oval, connected by regularly spaced bars.
- **Viewing**: 3D projection into an HTML canvas, lit triangle surfaces,
  optional triangle edges, drag rotation, mouse wheel zoom, focus + arrow-key
  rotation, auto rotation, reduced-motion preference support. Auto-motion and
  drawing stop when the Math view is hidden/offscreen; listeners are disposed.
  The renderer is a small CPU-backed triangle renderer (not Three.js/WebGL),
  so it has no external dependency or service call. It is intentionally
  bounded to detail 10–40.
- **Experiment**: Prepare OBJ, experiment JSON, viewport PNG, and an AEX-141
  metadata *template*. Experiment/mesh IDs are SHA-256 digests. The metadata
  template contains placeholder IPFS CIDs, not made-up published addresses.

## Reproduibility and hash scope

`ecai-math-3d.js` exports `generate3DMesh`, `meshToOBJ` and
`experimentBundle`. For a fixed generator version, shape, mesh detail and
lift/twist setting, the OBJ's ordered vertex and triangle records are
repeatable. Positions use six decimal places. Its SHA-256 is computed on
**exact OBJ UTF-8 bytes**; `experiment_id` is SHA-256 of an ordered JSON claim
containing the source equation, generator version, parameters, mesh count,
mesh hash and verification scope. These hashes are local calculations, not
chain receipts. The preview camera and PNG are *not* included in that hash.
There is a standards-compliant pure-JS SHA-256 fallback when SubtleCrypto is
not available (for example, an offline HTML preview).

The visualization samples real floating-point points. It does NOT prove an
isogeny or preserve semantic relationships. It is distinct from the exact
rational pathfinder, the DamageBDD verified-execution layer, and all fungible
DAMAGE tokens.

## NFT mint handoff — not an actual mint

The workbench **does not mint**. The existing ECAI mint-review endpoint is
restricted to eligible *index job* artifacts, and cannot honestly be reused
for arbitrary local geometry. `Prepare experiment for mint` is an export step.

The UI provides four downloads:

1. `ecai-SHAPE.obj` — geometry bytes, no binary installer or dependencies.
2. `ecai-SHAPE-experiment.json` — reproducible claim and hashes.
3. `ecai-SHAPE.png` — viewport preview, whose angle is not hash-bound.
4. `ecai-SHAPE-aex141-metadata-template.json` — collectable description with
   `ipfs://REPLACE_*` markers to replace after uploading OBJ and claim.

A user/operator can pin mesh, manifest and edited NFT metadata to IPFS,
then mint via a **configured AEX-141** collection and explicit wallet signing.
The AEX-141 standard has several metadata types and optional `mintable`
extensions: the deployed contract interface must be inspected before calling
`mint`. In the Æternity AEX-141 reference example, metadata files can be
pinned to IPFS and used as a metadata URL. Follow official docs:
<https://docs.aeternity.com/developer-documentation/aexs/aexs/aex-141>
<https://github.com/aeternity/aex141-nft-collection-example>

**Required for native ECAI on-chain mint:**

- Authenticated experiment registry (`experiment_id`, generator version,
  parameter schema, mesh hash, ownership/rights, immutable public outputs).
- Content-size limits, virus/content checks as appropriate, trusted IPFS
  pinning and pin verification; no private prompts or credentials published.
- Owner consent, collection and supported metadata type lookup, chain/network
  id checks, fee preview and cap, explicit recipient, operator authorization.
- Idempotency key tied to experiment hash and recipient; submission is
  `pending` until a canonical-chain receipt reaches required confirmations.
- Attach `contract_id`, `token_id`, `tx_hash`, `manifest_cid`, chain id,
  confirmation status. Never assert minted on a submitted tx alone.
- Optional DamageBDD run to verify regeneration independently and anchor its
  report alongside the mesh hash. Distinguish BDD results from exact math.

Suggested future API boundaries:

```
POST /ecai/math/experiments/inspect   # validate a submitted local experiment
POST /ecai/math/experiments          # authenticated immutable registration
POST /ecai/math/experiments/:id/publish # IPFS upload/pin with review
POST /ecai/math/experiments/:id/mint-review # explicit fee + recipient consent
GET  /ecai/math/experiments/:id/mint # network receipt/confirmation status
```

These are **design proposals**, not implemented routes.

## Follow-on visual workbenches

- **Point transport lab:** Animate actual points from a source elliptic curve
  to a target using a selected rational isogeny from a sample path. Show
  the kernel, degree, exceptional points and checked algebraic identities.
- **Isogeny graph explorer:** Render exact curves as nodes and exact rational
  map records as edges. Colour by degree, bound, verification status and
  search provenance, and distinguish node verification from supplied preview.
- **Proof timeline:** Show rational point evaluation, polynomial identity
  checks, negative controls and boundary between local preview and node replay.
- **Knowledge/BDD bridge:** Visualization of an explicitly defined semantic
  embedding preserving typed relations; connect each edge to source and
  DamageBDD evidence. Do not present the bridge as already proven.

## Local tests

```bash
node --test apps/ecai/test/math_dashboard/geometry3d.test.mjs
python3 apps/ecai/test/math_dashboard/geometry3d_browser_test.py
python3 -m unittest apps/ecai/test/test_math_dashboard_contract.py
```

Playwright tests use the shipped template and same ES module, local assets
only, a stubbed forbidden-network request, and downloads. Erlang/OTP runtime
compilation and live IPFS/NFT flows are separate deployment tests.
