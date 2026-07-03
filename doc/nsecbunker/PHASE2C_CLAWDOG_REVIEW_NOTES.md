# ClawDog review notes — Phase 2C

Please review Phase 2C as crypto semantic hardening.

Attack assumptions to check:

- Does event-id serialization exactly match NIP-01 array shape?
- Does BIP340 signing match vector 0 exactly?
- Does BIP340 verification reject invalid signatures?
- Does NIP-44 vector 0 match conversation key and payload exactly?
- Does real NIP-44 through the vault avoid the Phase 2B `plain:` path?
- Does wrong vault passphrase fail closed?
- Does production mode block plain NIP44 even if the old test env var is present?
- Does any response contain secret-shaped fields or values?

Phase 2C does not approve relay wiring, key ceremony, or LodgeiT bank-back. Those remain Phase 3/4/5.
