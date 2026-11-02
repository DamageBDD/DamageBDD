# Qwen behaviour profiles catalogue

The **LLM evaluation → Qwen behaviour profiles** tab records behaviour objectives,
activation recipes and observed comparisons in the existing account-scoped DETS
ledger. It is a catalogue, not an activation-steering inference service. The
current evaluation providers do not apply these recipes or automatically select
them through ECAI. Saving a profile never submits an evaluation run.

## Operator workflow

1. Open the catalogue using a managed email session. Choose one of the four
   objective templates: grounded answers, Erlang patch discipline, tool contract
   discipline, or calibrated abstention.
2. Set the exact model identifier, declared model revision or weights digest,
   quantization, tags and evaluation plan. Templates deliberately start with an
   unconfigured intervention and no claimed performance.
3. Record a discovered neuron recipe or a vector digest. Save the snapshot.
   Search and status filters work on saved account profiles. **Use as new draft**
   edits a copy; a changed canonical spec receives a new content hash and starts
   without comparison evidence. Identical normalized imports reuse the snapshot.
4. Run ordinary evaluations through the existing Runs & results workflow. Once
   both target arms have complete outcomes, link an observed comparison to the
   profile. You can copy IDs from the existing paired comparison form.
5. Export the recipe JSON for reuse, or export a receipt containing the recipe
   and frozen comparison evidence. A receipt hash detects changed bytes; it does
   not certify model identity, correctness or execution of the intervention.

Linking requires ownership of both runs, identical suite/split/case coverage,
matching exact model IDs and matching declared model revision. A missing or
`unverified-model-alias` revision is rejected. Comparing one arm with itself is
rejected. Failed trials remain part of the results. Pending, uncertain or
unreviewed target arms cannot be linked as completed evidence.

Comparison snapshots retain paired improvements/regressions, both target
scorecards (including latency), the relevant run settings, target fingerprints
and notes. A configuration mismatch is visible. Selection method labels are
owner declarations (`fixed`, `ecai_selected`, `lookup_selected`), not runtime
receipts. All comparison records set `steering_attested: false` and
`model_identity_attested: false`. Quantization is recorded in the recipe but is
not attested by the existing provider metadata. There is no “verified” status.
The catalogue does not invent costs: existing reports have no authoritative
provider billing amounts.

## Recipe contract

`ecai-qwen-profile/v1` has these fields:

| Field | Meaning |
| --- | --- |
| `name`, `objective` | Display name and behaviour to evaluate |
| `model` | Exact Qwen model identifier used by the configured target |
| `model_revision` | Operator-declared immutable revision/digest; `null` for drafts |
| `quantization` | Declared runtime precision or quantization; `unspecified` for drafts |
| `tags` | Up to 16 distinct tags; normalized in sorted order |
| `intervention` | `unconfigured`, `neurons`, or `vector` |
| `evaluation_notes` | Discovery procedure, evaluation plan and known limitations |

An objective-only intervention is `{"kind":"unconfigured"}`. A configured neuron
intervention has this **illustrative, untested** shape; the coordinates below are
not a discovered behaviour profile:

```json
{
  "kind": "neurons",
  "hook": "mlp.down_proj.output",
  "token_scope": "generated",
  "normalization": "residual_norm",
  "neurons": [{"layer": 3, "index": 42, "dose_milli": 250}]
}
```

Layers and neuron indices are zero-based. `dose_milli / 1000` is the signed dose
in the chosen units, bounded to -4 through +4 by the catalogue. This is an input
bound, not a claim that every allowed dose is useful or safe. `absolute` refers
to an unnormalized additive coefficient; `residual_norm` describes a direction
scaled relative to the residual norm. Record the precise calibration procedure
in `evaluation_notes`; there is currently no inference implementation of that
normalization. `generated` applies to generated tokens and `all` includes prompt
tokens. Duplicate layer/index pairs are rejected; pairs are sorted canonically.

A vector recipe has `kind: "vector"`, `hook`, `token_scope`, `normalization`,
`layer`, `dose_milli`, and a 64-character lowercase `vector_sha256`. Supported hook
labels are `residual.post_layer` and `mlp.down_proj.output`. The catalogue stores
only the digest. It does not fetch vector URLs, load tensors, accept executable
code or validate dimensions against a loaded model. Bounds on layers and indices
are coarse schema limits; a future worker must validate the actual architecture.

## API and persistence

All endpoints retain the evaluation handler's managed-account authentication,
cross-site rejection, explicit bearer token for POST, no-store responses and
path-authoritative IDs. Caller-supplied ownership or verification fields are
rejected. Writes use the existing synchronized DETS ledger, with no new service
or settings migration.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/ecai/eval/profiles` | Account summaries, four templates and execution capabilities |
| POST | `/ecai/eval/profiles` | Validate and save an immutable recipe snapshot |
| GET | `/ecai/eval/profiles/:id` | Full owned recipe and comparison snapshots |
| POST | `/ecai/eval/profiles/:id/comparisons` | Link a server-resolved observed comparison |
| GET | `/ecai/eval/profiles/:id/evidence` | Canonical manifest bytes, SHA-256 and unsigned claim |

The comparison body uses `baseline`, `candidate`, `baseline_target`,
`candidate_target`, `selection_method` and `note`. Metric values supplied by the
caller are not accepted. Identical evidence attachments are idempotent.

Storage is bounded to 100 profiles per account, 500 per node and 32 comparisons
per profile. HTTP profile inputs are limited to 64 KiB. Profile snapshots and
their compact comparison evidence persist across restarts and outlive evaluation
run retention; they do not retain the full trial transcripts. Export run receipts
separately when those are needed. This version has no profile deletion endpoint.

## Next execution boundary

To execute steering, add a local inference adapter that validates model revision,
precision, tensor digest, hook, dimensions and calibration before applying a
recipe. It must return per-request execution metadata tied to the profile hash.
Only then should the catalogue expose execution controls or use an attested
state. Keep no-steering, fixed, ECAI-selected and simple-lookup arms on identical
context and generation limits. Discover on development data and freeze profiles
before using test/holdout data. Linking an existing evaluation cannot substitute
for this worker integration or demonstrate ECAI's selection advantage.

## Validation

The source archive contains only `apps/ecai`; the enclosing DamageBDD application
and umbrella build configuration are not included.

- JavaScript ES-module syntax checked with Node.
- Erlang syntax parsed with tree-sitter for the three changed/new production
  modules and two test modules. This is not Erlang compilation.
- All 19 available Chromium component tests passed, exercising the actual template, CSS and JavaScript with
  synthetic API fixtures: save, search, imports/exports, kind validation,
  comparisons, escaping, stale responses, session clearing and 390px layout.
- Pure EUnit profile validation/comparison tests and a DETS account-isolation /
  restart / receipt test are included. OTP, `erlc` and `rebar3` are unavailable in
  the authoring environment, so these native tests have not been executed.
- The existing console contract suite has three pre-existing failures reproduced
  against the untouched input: stale API count (122 vs 127), three missing
  expected navigation entries, and `chatWorkspace` markup expectations.
- No live Qwen inference, steering experiment or production deployment occurred.

In the full umbrella checkout, run:

```sh
rebar3 eunit --module=ecai_eval_profiles_tests,ecai_eval_ledger_tests,ecai_eval_tests
python3 apps/ecai/test/test_ecai_eval_browser.py
```

The browser suite needs Python Playwright and its Chromium browser. Its existing
DamageBDD account-settings test needs `apps/damage` from the full checkout.
