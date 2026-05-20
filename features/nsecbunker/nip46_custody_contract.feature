@phase0 @custody @nip46 @generic-deployment @immediate-release
Feature: Generic NIP-46 custody contract
  A NIP-46 bunker identity is an irreversible custody surface.
  The bunker MUST be narrow, fail-closed, auditable, and behaviourally verified
  before the public key is bound into any deployment identity record.

  Background:
    Given the bunker has generated the deployment signing key inside the vault
    And the deployment nsec has never left the vault
    And the bunker expected public key is recorded as "BUNKER_PUBKEY_HEX"
    And the authorised client pubkey allowlist contains "AUTHORISED_CLIENT_PUBKEY_HEX"
    And the allowed NIP-46 methods are exactly:
     | method         |
     | connect        |
     | ping           |
     | get_public_key |
     | sign_event     |
    And the allowed event kinds are exactly:
     | kind  |
     | 1     |
     | 30023 |
    And the stale event skew window is 600 seconds relative to bunker time
    And the maximum byte size for kind 1 is 4096 bytes
    And the maximum byte size for kind 30023 is 131072 bytes
    And the bunker signs only and never publishes to relays

  Scenario: Authorised client can discover the stable public key
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" calls "get_public_key"
    Then the bunker response MUST contain "BUNKER_PUBKEY_HEX"
    And the returned public key MUST equal the public key recorded in the deployment identity record
    And no identity rotation may occur without a separate ratified identity-rotation record
    And the decision MUST be written to the deterministic audit log

  Scenario Outline: Authorised client can call only exact allowed NIP-46 methods
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" calls "<method>"
    Then the method decision MUST be "allowed"

    Examples:
     | method         |
     | connect        |
     | ping           |
     | get_public_key |
     | sign_event     |

  Scenario Outline: Unknown or misspelled methods are rejected
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" calls "<method>"
    Then the method decision MUST be "rejected"
    And the denial reason MUST be "method_not_allowed"
    And the decision MUST be written to the deterministic audit log

    Examples:
     | method          |
     | SIGN_EVENT      |
     | sign-event      |
     | nip04_decrypt   |
     | publish_event   |
     | get_relays      |


  Scenario: Unauthorised client cannot use the bunker
    When client "UNAUTHORISED_CLIENT_PUBKEY_HEX" calls "sign_event"
    Then the request MUST be rejected before signing
    And the denial reason MUST be "client_not_authorized"
    And the decision MUST be written to the deterministic audit log

  Scenario: Stale signing request is rejected
    Given bunker time is 1778000000
    And a signing request has created_at 1777999000
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "request_stale"
    And the decision MUST be written to the deterministic audit log

  Scenario: Signing request too far in the future is rejected
    Given bunker time is 1778000000
    And a signing request has created_at 1778001000
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "request_from_future"
    And the decision MUST be written to the deterministic audit log

  Scenario Outline: Only configured event kinds are signable
    Given an unsigned event of kind <kind>
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the signing decision MUST be "<decision>"
    And the denial reason SHOULD be "<reason>"

    Examples:
   | kind  | decision | reason           |
   | 1     | allowed  | none             |
   | 30023 | allowed  | none             |
   | 0     | rejected | kind_not_allowed |
   | 3     | rejected | kind_not_allowed |
   | 4     | rejected | kind_not_allowed |
   | 9735  | rejected | kind_not_allowed |

  Scenario: Oversized kind 1 event is rejected
    Given an unsigned kind 1 event larger than 4096 bytes
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "event_too_large"
    And no signature MUST be produced

  Scenario: Oversized kind 30023 event is rejected
    Given an unsigned kind 30023 event larger than 131072 bytes
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "event_too_large"
    And no signature MUST be produced

  Scenario: Minimal NIP-23 long-form tags are required
    Given an unsigned kind 30023 event
    When the event does not contain tags "d", "title", and "published_at"
    And authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "missing_required_tag"
    And no signature MUST be produced

  Scenario: Publication geometry is not owned by the bunker
    Given an unsigned kind 30023 event with the required minimal tags
    And the event passes stale, size, HTML, kind, and client policy checks
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the bunker MUST NOT reject merely because of the d-tag naming scheme
    And the bunker MUST NOT reject merely because of the IPFS CID tag namespace
    And the bunker MUST NOT publish the event to any relay
    And publication geometry MUST remain owned by configured publication tooling

  Scenario: HTML or active script content in long-form event is rejected
    Given an unsigned kind 30023 event whose content contains "<script"
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "active_content_not_allowed"
    And no signature MUST be produced

  Scenario: Replay with the same requester and request id is idempotent only for the same payload
    Given authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" submitted request id "REQ-1" for payload hash "HASH-A"
    When the same client submits request id "REQ-1" for payload hash "HASH-A" again
    Then the bunker MUST NOT produce a divergent signature
    And the replay decision MAY be "duplicate_same_payload"

  Scenario: Replay with the same requester and request id but a different payload is rejected
    Given authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" submitted request id "REQ-1" for payload hash "HASH-A"
    When the same client submits request id "REQ-1" for payload hash "HASH-B"
    Then the request MUST be rejected before signing
    And the denial reason MUST be "replay_conflict"
    And no signature MUST be produced

  Scenario: Rate limit is enforced before signing
    Given authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" has exceeded 30 requests in a 60 second window
    When the client requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be "rate_limited"
    And the decision MUST be written to the deterministic audit log

  Scenario: Timeout policy is enforced before signing
    Given a signing request cannot complete within 10000 milliseconds
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing
    Then the request MUST fail closed
    And the denial reason MUST be "signing_timeout"
    And no partial signature material MUST be exposed

  Scenario: Vault corruption fails closed
    Given the vault fails integrity verification
    When any client requests any signing operation
    Then the request MUST be rejected before signing
    And the denial reason MUST be "vault_integrity_failed"
    And no signing backend MUST be invoked

  Scenario: Vault public key mismatch fails closed
    Given the vault unseals to a public key other than "BUNKER_PUBKEY_HEX"
    When any client requests "get_public_key" or "sign_event"
    Then the request MUST be rejected
    And the denial reason MUST be "vault_pubkey_mismatch"
    And identity rotation MUST require a separate ratified identity-rotation record

  Scenario: Audit logs prove decisions without leaking keys or payloads
    When the bunker writes an audit row
    Then the row MUST use deterministic field order
    And the row MUST include schema_version, ts_unix, requester_pubkey, request_id, method, decision, deny_reason, event_kind, event_id, payload_sha256, bunker_pubkey, and contract_sha
    And the row MUST NOT include nsec, plaintext NIP-46 payload, unsigned event content, or signature nonce material

  Scenario: Relay-set drift does not change signer behaviour
    Given the configured publication relay vector changes after initial publication
    When authorised client "AUTHORISED_CLIENT_PUBKEY_HEX" requests signing for an otherwise valid event
    Then the bunker signing decision MUST be independent of the relay vector
    And relay publication MUST remain outside bunker scope
