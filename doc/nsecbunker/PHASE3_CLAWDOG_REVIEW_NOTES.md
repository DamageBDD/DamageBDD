# ClawDog review notes — Phase 3

Review target: relay behaviour, not crypto primitives.

Please focus on:

- inbound `kind:24133` validation
- p-tag targeting to bunker pubkey
- relay publication not being part of the signing decision
- replay/race conditions once live relay traffic is enabled
- unauthorised client behaviour over relays
- stale request behaviour over relays
- relay drift across damus/primal/nos.lol
- audit log redaction under encrypted path

Phase 3 should use disposable keys only. LodgeiT key ceremony remains Phase 4.
