# ClawDog acceptance matrix — `damage_nsecbunker`

| ID | Behaviour | Expected decision | Denial reason | Signs? | Publishes? | Audit? |
|---:|-----------|-------------------|---------------|--------|------------|--------|
| B01 | Authorised client calls `get_public_key` | allowed | none | no | no | yes |
| B02 | Authorised client calls `ping` | allowed | none | no | no | yes |
| B03 | Unknown client calls allowed method | rejected | `client_not_authorized` | no | no | yes |
| B04 | Unsupported NIP-46 method | rejected | `method_not_allowed` | no | no | yes |
| B05 | Authorised kind `1` signing request | allowed | none | yes, after gate | no | yes |
| B06 | Authorised kind `30023` with required tags | allowed | none | yes, after gate | no | yes |
| B07 | Unsupported event kind | rejected | `kind_not_allowed` | no | no | yes |
| B08 | Stale request | rejected | `request_stale` | no | no | yes |
| B09 | Future request | rejected | `request_from_future` | no | no | yes |
| B10 | Oversized `kind:30023` | rejected | `event_too_large` | no | no | yes |
| B11 | `kind:30023` missing required tags | rejected | `missing_required_tag` | no | no | yes |
| B12 | `kind:30023` active content | rejected | `active_content_not_allowed` | no | no | yes |
| B13 | Duplicate same-payload replay | idempotent | none / duplicate | no divergent signature | no | yes |
| B14 | Replay conflict | rejected | `replay_conflict` | no | no | yes |
| B15 | Rate limit exceeded | rejected | `rate_limited` | no | no | yes |
| B16 | Signing timeout | rejected | `signing_timeout` | no partial sig | no | yes |
| B17 | Vault integrity failure | rejected | `vault_integrity_failed` | no | no | yes |
| B18 | Vault pubkey mismatch | rejected | `vault_pubkey_mismatch` | no | no | yes |
| B19 | Audit row | deterministic/redacted | n/a | n/a | n/a | yes |
| B20 | Relay drift | signing decision unchanged | n/a | as policy allows | no | yes |

## Scope boundary

The bunker signs; it does not publish.

Publication geometry, relay fanout, relay acceptance, pinning, soaking, and final broadcast remain owned by configured publication tooling. The bunker policy must not change based on relay drift.
