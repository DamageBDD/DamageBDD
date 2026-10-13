# Nsecbunker ClawDog features

`clawdog_nsecbunker_contract.feature` is the behaviour contract for Phase 2A.

This feature deliberately exercises the bunker gate/policy layer and not real Schnorr signing. That is intentional: ClawDog signs off what the bunker is allowed to attempt before the crypto backend can produce signatures.

The contract hash should be computed over this feature file and copied into `contract_sha` in the `nsecbunker` config.
