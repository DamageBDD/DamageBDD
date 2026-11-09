# Food Rescue & Recall — public ECAI dashboard application

## Open and explore

Open `/dashboard#food-rescue` (or `/#food-rescue` on a root-mounted console), then
choose **Applications → Food Rescue & Recall**. No account, wallet, API key,
language-model service or paid compute is needed. The standalone page is
`/static/food-rescue/index.html` and uses the same model and interface.

1. Start with **Rescue the morning**. The end-of-window cards show the final
   outcome, while the map starts at 09:00 and shows current replay state.
2. Press **Play**, use **Next event**, or move the timeline. Click a recipient
   to filter the lot cards; **Show all lots** removes that filter.
3. Try **Recall after delivery**. At 09:30 the two DAIRY-42 lots move from
   eligible delivery to recipient hold. At the end, 310 kg remains eligible;
   90 kg is held, not silently counted as rescued.
4. Reduce van capacity or increase delay, then **Compare rescue plans**.
   Changing inputs invalidates results and exports. **Check the previous plan**
   explains whether its assignments also violate the changed constraints.
5. Inspect the exact ledger, timetable and sensor fixtures. Try a recalled-lot
   release, run all reference scenarios, or export evidence.

The guided tour, keyboard controls, native dialog, reduced-motion handling,
responsive layouts and presentation mode are available without authentication.
Opening lot evidence pauses animation. Playback stops when the view is hidden,
the document is hidden or the controller is disposed.

## Synthetic fixture

Everything is fictional: suppliers, batch identifiers, recipients, demand,
temperatures, roads, vehicle availability and expiry deadlines. There is no
live geography, telemetry, recipient confirmation or dispatch integration.

Six indivisible lots total **400 kg**:

| Lot | Product | kg | Batch | Synthetic expiry |
|---|---|---:|---|---|
| TOM-01 | Tomatoes | 80 | GROW-11 | 10:10 |
| LEAF-02 | Leafy greens | 60 | GROW-12 | 09:50 |
| BREAD-03 | Bread | 100 | BAKE-18 | 13:10 |
| YOG-04 | Yoghurt A | 50 | DAIRY-42 | 11:25 |
| YOG-05 | Yoghurt B | 40 | DAIRY-42 | 12:40 |
| BERRY-06 | Berries | 70 | GROW-13 | 11:20 |

The synthetic cold rule requires three recorded pre-dispatch readings no higher
than 5°C. A missing reading is **unverifiable**, not passing. A high reading or
active recall is **quarantined**. These thresholds are invented for testing and
must not be used as food-specific operating advice or food-safety certification.
No continuous in-transit temperature record is modelled.

Vans A and B each have the selected per-trip capacity, initially 160 kg. Six
fixed trip slots visit three recipients over a 270-minute window. The hub is the
sole source. The kitchen and pantry accept chilled and ambient stock; the shelter
accepts ambient stock only. Destinations have finite total demand. Travel uses
shortest open graph paths; each van must return before its next scheduled trip.
The model does not choose arbitrary routes, split lots, consume stock, replenish
stock, reschedule the timetable or solve a general vehicle-routing problem.

## Eight scenarios and reference outcomes

All rows below use 160 kg per van and zero dispatch delay.

| Scenario | Simple dispatch: eligible kg | Rescue plan: eligible kg | Hold / unknown / other |
|---|---:|---:|---|
| Rescue the morning | 360 | 400 | 0 kg held |
| Bridge closed | 360 | 400 | North bypass used |
| Cooling failure | 330 | 330 | 70 kg quarantined |
| Missing sensor log | 340 | 340 | 60 kg unverifiable |
| Supplier recall | 310 | 310 | 90 kg held at hub |
| Recall after delivery | 310 | 310 | 90 kg held at kitchen |
| Demand surge | 400 | 400 | 100 kg demand unmet |
| One van offline | 280 | 290 | Rescue plan leaves 110 kg unallocated |

The default comparison delivers an additional **40 kg** under this model. It is
not a measured real-world waste reduction or evidence of ECAI superiority over
all conventional algorithms. Neither value is a food donation actually made.

## Planning and execution are separate

`greedyPlan` sorts by first expiry, then chooses the earliest feasible arrival.
This is a simple conventional heuristic, not a best-in-class optimisation
baseline. `rescuePlan` exactly searches the permitted whole-lot assignments to
six fixed trips. Its ordered objective is:

- Maximise planned eligible kilograms.
- Minimise kilogram-minutes to arrival.
- Minimise round-trip travel minutes for used trips.

Ties retain the first result in stable fixture/trip order. At most 7^6 complete
assignments exist (six trips or no assignment per lot); pruning reduces the
search. There is no language model or native ECAI index query in this release.
A conventional solver using the same objective can match the optimum.

Both plans pass the same initial constraint validator and run through the same
execution rules. Dispatch and arrival recheck recall, evidence and expiry. The
expiry boundary is exclusive: arrival at or after the deadline is rejected.
Recalls are processed before dispatch/arrival at the same minute.

The late-recall incident is not consulted by either planner. It is introduced
at minute 30 during execution. Already delivered matching lots receive a
**recipient recall hold**; in-transit or waiting matching lots are held and
cannot pass a subsequent release. Final eligible kilograms exclude all holds.
The original plan is not retrospectively re-optimised with future knowledge.

A hold is not proof of physical recovery, disposal or a real recipient action.
Consumption and exposure are not simulated. Unallocated kilograms are not
reported as spoiled; their status depends on this bounded planning horizon.
The live card view marks unallocated stock whose synthetic expiry window has
closed, without inventing a delivery or editing the recorded ledger.

## Seven checks for each plan

Mass accounting, no held stock counted as rescued, delivery before expiry,
vehicle capacity, recipient demand, unique delivery and passing release checks.
These are local checks over this model. The UI's acceptance action evaluates
8 scenarios × 2 plans × 7 checks = **112 checks**, not 112 remote BDD executions.
Passing checks do not validate the real-world completeness of the rules.

## Evidence and independent replay

Export from the UI, then run:

```sh
python3 apps/ecai/tools/verify_food_rescue.py \
  ~/Downloads/food-rescue-everyday.evidence.json
```

The evidence contains an exact version/scope, fixture and controls, both plans,
planned scores, per-lot states, ledger events, release gates, full replay states,
metrics and local checks. SHA-256 covers recursively key-sorted compact JSON
encoded as UTF-8, excluding the outer checksum field.

The Python verifier independently implements the fixture, path search, planners,
constraints, event ordering and ledger arithmetic. It runs no JavaScript and
trusts no stored `passed` field. It rejects unknown schemas, altered fixtures,
extra fields, duplicate JSON keys, non-integer numbers, oversized files and
inconsistent records even if rehashed. It currently accepts only the exact
known v1 fixtures and deterministic planner outputs, not arbitrary alternative
plans or real-world datasets.

**A checksum is not a signature.** Replacing the entire evidence with another
internally consistent known fixture is not an authenticity violation that this
verifier can detect. No authorship, trusted time, sensor integrity, independent
node consensus or original browser execution is established.

The browser needs HTTPS or localhost for Web Crypto. An unavailable secure
context yields an explicit export error; no fake checksum is emitted. A changed
scenario or control value during hashing prevents exporting an obsolete result.

## Integration and security boundary

The installer adds a static public panel, scoped stylesheet and ES modules to
`apps/ecai`, and connects view registration, navigation, refresh and disposal.
It preserves EnergyFlex, Agent Payment Guard and other views. The app does not
call an API or alter server routes, authentication, managed workspace access,
sys.config, the Erlang application or payment configuration.

Public demo controls are bounded local enum/numeric inputs. No arbitrary file,
URL, code, feature text or secret is accepted. No dispatch tools are exposed.
Browser-local checks can be modified by a person controlling that browser;
**never use this client as a trusted food-release authority**.

Production integration would require trusted inventory and recall data, validated
food-specific policies, authenticated roles, server-side atomic reservations and
final release controls, calibrated sensor provenance, recipient acknowledgments,
consumption/recovery handling, durable audit records and live acceptance tests.
Native ECAI retrieval and registered DamageBDD backend steps are not implemented
or claimed by this public sandbox.

## Testing

Core tests: Node 22+ and Python 3.10+. No application runtime dependencies added.
Browser tests additionally require Playwright and Chromium.

```sh
node --test apps/ecai/test/food_rescue/model.test.mjs
python3 apps/ecai/test/food_rescue/verifier_test.py
python3 apps/ecai/test/food_rescue/browser_test.py
python3 apps/ecai/test/food_rescue/console_browser_test.py
```

The model suite checks all **616** scenario/capacity/delay combinations, rejects
forged assignments and compares the default exact score with an independent
unpruned enumeration of all **117,649** assignments. Python parity checks all
616 runs, including their event histories and metrics via canonical hashes.

Browser tests default to the real DOM/model in an offline page with a test-only
SHA adapter for export. Set `FR_TEST_HTTP=1` for localhost/native Web Crypto;
that navigation was blocked by the build environment and was not validated here.
Console tests run the retrieved production controller with the actual three
public demo modules, synthetic authentication/API responses and stubs for
unrelated workspaces. No live Cowboy release, real auth service, remote DamageBDD
execution, physical dispatch or production food-safety acceptance was tested.
