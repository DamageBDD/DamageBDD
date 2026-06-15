@clawdog @nsecbunker @phase2a @custody_contract
Feature: LodgeiT Genesis NIP-46 bunker custody contract

  The bunker protects the LodgeiT publisher identity.
  It signs only narrowly authorised NIP-46 requests and never exposes nsec material.
  Relay publication remains outside bunker scope until the separate relay integration phase.

  Background:
    Given the bunker has generated the deployment signing key inside the vault
    And the deployment nsec has never left the vault
    And the bunker expected public key is recorded as BUNKER_PUBKEY_HEX
    And the authorised client pubkey allowlist contains AUTHORISED_CLIENT_PUBKEY_HEX
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
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX calls get_public_key
    Then the bunker response MUST contain BUNKER_PUBKEY_HEX
    And the returned public key MUST equal the public key recorded in the deployment identity record
    And no identity rotation may occur without a separate ratified identity-rotation record
    And the decision MUST be written to the deterministic audit log
    And the method decision MUST be allowed

  Scenario: Authorised client can ping the bunker without invoking signing
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX calls ping
    Then the method decision MUST be allowed
    And the decision MUST be written to the deterministic audit log
    And no signing backend MUST be invoked

  Scenario: Unknown client cannot call an allowed method
    When client UNKNOWN_CLIENT_PUBKEY_HEX calls get_public_key
    Then the method decision MUST be rejected
    And the denial reason MUST be client_not_authorized
    And no signing backend MUST be invoked

  Scenario: Unsupported NIP-46 methods are rejected before signing
    When any client requests publish_event or nip04_encrypt
    Then the request MUST be rejected
    And the denial reason MUST be method_not_allowed
    And no signature MUST be produced
    And no signing backend MUST be invoked

  Scenario: Authorised client can request signing for a kind 1 announcement
    Given bunker time is 1778000000
    And an unsigned event of kind 1
    And the event passes stale, size, HTML, kind, and client policy checks
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the signing decision MUST be allowed
    And the decision MUST be written to the deterministic audit log
    And the bunker MUST NOT publish the event to any relay
    And publication geometry MUST remain owned by configured publication tooling

  Scenario: Authorised client can request signing for a kind 30023 long-form event with required tags
    Given bunker time is 1778000000
    And an unsigned kind 30023 event with the required minimal tags
    And the event passes stale, size, HTML, kind, and client policy checks
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the signing decision MUST be allowed
    And the bunker MUST NOT reject merely because of the d-tag naming scheme
    And the bunker MUST NOT reject merely because of the IPFS CID tag namespace
    And the bunker MUST NOT publish the event to any relay

  Scenario: Unsupported event kind is rejected before signing
    Given bunker time is 1778000000
    And an unsigned event of kind 4
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be kind_not_allowed
    And no signature MUST be produced

  Scenario: Stale signing request is rejected before signing
    Given bunker time is 1778000000
    And an unsigned event of kind 1
    And a signing request has created_at 1777990000
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be request_stale
    And no signature MUST be produced

  Scenario: Future-dated signing request is rejected before signing
    Given bunker time is 1778000000
    And an unsigned event of kind 1
    And a signing request has created_at 1778001000
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be request_from_future
    And no signature MUST be produced

  Scenario: Oversized kind 30023 event is rejected before signing
    Given bunker time is 1778000000
    And an unsigned kind 30023 event larger than 131072 bytes
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be event_too_large
    And no signature MUST be produced

  Scenario: Kind 30023 without required tags is rejected before signing
    Given bunker time is 1778000000
    And an unsigned event of kind 30023
    And the event does not contain tags d, title, and published_at
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be missing_required_tag
    And no signature MUST be produced

  Scenario: Kind 30023 active content is rejected before signing
    Given bunker time is 1778000000
    And an unsigned kind 30023 event whose content contains <script
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be active_content_not_allowed
    And no signature MUST be produced

  Scenario: Duplicate same-payload replay is idempotent and does not create a divergent signature
    Given authorised client AUTHORISED_CLIENT_PUBKEY_HEX submitted request id REQ-REPLAY for payload hash HASH-A
    When the same client submits request id REQ-REPLAY for payload hash HASH-A again
    Then the replay decision MAY be duplicate_same_payload
    And the bunker MUST NOT produce a divergent signature

  Scenario: Replay conflict is rejected before signing
    Given authorised client AUTHORISED_CLIENT_PUBKEY_HEX submitted request id REQ-CONFLICT for payload hash HASH-A
    When the same client submits request id REQ-CONFLICT for payload hash HASH-B
    Then the request MUST be rejected
    And the denial reason MUST be replay_conflict
    And no signature MUST be produced
    And no signing backend MUST be invoked

  Scenario: Rate limited client is rejected before signing
    Given bunker time is 1778000000
    And authorised client AUTHORISED_CLIENT_PUBKEY_HEX has exceeded 30 requests in a 60 second window
    And an unsigned event of kind 1
    When the client requests signing
    Then the request MUST be rejected before signing
    And the denial reason MUST be rate_limited
    And no signature MUST be produced

  Scenario: Signing timeout fails closed
    Given bunker time is 1778000000
    And an unsigned event of kind 1
    And a signing request cannot complete within 10000 milliseconds
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the request MUST fail closed
    And the denial reason MUST be signing_timeout
    And no partial signature material MUST be exposed

  Scenario: Vault integrity failure fails closed before signing
    Given the vault fails integrity verification
    When any client requests any signing operation
    Then the request MUST fail closed
    And the denial reason MUST be vault_integrity_failed
    And no signing backend MUST be invoked

  Scenario: Vault public key mismatch fails closed before signing
    Given the vault unseals to a public key other than BUNKER_PUBKEY_HEX
    When any client requests any signing operation
    Then the request MUST fail closed
    And the denial reason MUST be vault_pubkey_mismatch
    And identity rotation MUST require a separate ratified identity-rotation record
    And no signing backend MUST be invoked

  Scenario: Audit line is deterministic and redacted
    When the bunker writes an audit row
    Then the row MUST use deterministic field order
    And the row MUST include schema_version, ts_unix, requester_pubkey, request_id, method, decision, deny_reason, event_kind, event_id, payload_sha256, bunker_pubkey, and contract_sha
    And the row MUST NOT include nsec, plaintext NIP-46 payload, unsigned event content, or signature nonce material

  Scenario: Relay drift cannot alter the signing decision
    Given bunker time is 1778000000
    And an unsigned kind 30023 event with the required minimal tags
    And the configured publication relay vector changes after initial publication
    When authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing
    Then the signing decision MUST be allowed
    And the bunker signing decision MUST be independent of the relay vector
    And relay publication MUST remain outside bunker scope
