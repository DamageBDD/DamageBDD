# Phase 2A — ClawDog BDD signoff plan

## Why this is the next phase

Phase 1 put `damage_nsecbunker` into the existing Damage OTP supervision tree. The next risk is not Erlang wiring; it is disagreement about expected custody behaviour after code is already built.

So the next phase is a **ClawDog BDD signoff gate**.

Do not proceed to live key generation, relay publication, or crypto backend signing until the BDD contract is agreed and hashed.

## Estimate

Expected elapsed time: **0.5–1 working day**.

Work items:

1. Review the feature file with ClawDog.
2. Adjust expected denial reasons or scope boundaries if needed.
3. Dry-run the feature in DamageBDD.
4. Record feature hash / report hash.
5. Put the approved `contract_sha` into `nsecbunker` config.

## Deliverables

- `features/nsecbunker/clawdog_nsecbunker_contract.feature`
- `apps/damage/src/steps_nsecbunker.erl`
- EUnit contract sanity tests
- Acceptance matrix
- Signoff record template
- Hash scripts

## Exit criteria

Phase 2A is complete when:

- ClawDog approves the `.feature` behaviour.
- The feature hash is recorded.
- The dry-run report hash is recorded.
- `contract_sha` in the bunker policy is updated to the approved hash.
- The implementation still fails closed when the crypto backend is absent.

## Explicit non-goals

This phase does not:

- generate the LodgeiT production key
- wire real NIP-44 encryption
- wire real Schnorr signing
- publish to relays
- expose an `nsec`
- introduce npm / `nsecbunkerd`

Those belong to Phase 2B and later.
