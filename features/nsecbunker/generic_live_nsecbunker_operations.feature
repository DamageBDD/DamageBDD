@damage @nsecbunker @nip46 @live @production-safe
Feature: Live damage nsecbunker operations using the node damage_nostr identity
  The live server must prove that the configured damage nsecbunker is operating
  end-to-end on the production node.
  The NIP-46 client for this test is not an external generated key. It is the
  node's existing damage_nostr identity, derived from the same damage_nostr_nsec
  used by damage_nostr. The test must never print, report, or persist the nsec
  or any private-key material.

  Background:
    Given the live damage nsecbunker server is running
    And the live damage nsecbunker vault is ready
    And the live damage nsecbunker node pubkey is loaded from the running bunker policy
    And the live NIP-46 client is the damage_nostr node identity
    And the live NIP-46 client pubkey is authorised by the running bunker policy
    And the live NIP-46 relays are loaded from the running bunker config
    And the live NIP-46 relay bridge is running and subscribed
    And the live NIP-46 test run id is generated

  Scenario: Live identity and relay filter are internally consistent
    Then the live bunker public key MUST equal the vault guard public key
    And the live NIP-46 client pubkey MUST NOT equal the bunker pubkey
    And the live NIP-46 subscription filter MUST include kind 24133
    And the live NIP-46 subscription filter MUST be p-tagged to the bunker pubkey
    And no live test context MUST contain secret material

  Scenario: Live local bunker core accepts the damage_nostr client
    When I call the live bunker plain request method "ping" as the damage_nostr client
    Then the live bunker plain response MUST be accepted
    And the live bunker plain response result MUST be "pong"
    And the live bunker audit log MUST contain the test run id
    And the live bunker audit log MUST contain decision "allowed"
    And no live test context MUST contain secret material

  Scenario: Live local bunker returns its configured public key
    When I call the live bunker plain request method "get_public_key" as the damage_nostr client
    Then the live bunker plain response MUST be accepted
    And the live bunker plain response result MUST equal the bunker pubkey
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material

  Scenario: Live NIP-46 relay round trip responds to ping
    When I publish a live NIP-46 "ping" request from the damage_nostr client
    Then the live NIP-46 request MUST be accepted by at least one relay
    And a live NIP-46 reply MUST be received
    And the live NIP-46 reply MUST be kind 24133
    And the live NIP-46 reply MUST be authored by the bunker pubkey
    And the live NIP-46 reply MUST be p-tagged to the damage_nostr client pubkey
    And the decrypted live NIP-46 response result MUST be "pong"
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material

  Scenario: Live NIP-46 relay round trip returns the bunker public key
    When I publish a live NIP-46 "get_public_key" request from the damage_nostr client
    Then the live NIP-46 request MUST be accepted by at least one relay
    And a live NIP-46 reply MUST be received
    And the decrypted live NIP-46 response result MUST equal the bunker pubkey
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material

  Scenario: Live NIP-46 rejects a non-allowlisted method
    When I publish a live NIP-46 "nip04_decrypt" request from the damage_nostr client
    Then the live NIP-46 request MUST be accepted by at least one relay
    And a live NIP-46 reply MUST be received
    And the decrypted live NIP-46 response MUST be rejected
    And the decrypted live NIP-46 error reason MUST be "method_not_allowed"
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material

  Scenario: Live NIP-46 rejects an event kind outside the running policy
    When I publish a live NIP-46 "sign_event" request for a kind not allowed by the running bunker policy from the damage_nostr client
    Then the live NIP-46 request MUST be accepted by at least one relay
    And a live NIP-46 reply MUST be received
    And the decrypted live NIP-46 response MUST be rejected
    And the decrypted live NIP-46 error reason MUST be "kind_not_allowed"
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material

  Scenario: Live NIP-46 signs an allowed addressable article without publishing it
    When I publish a live NIP-46 "sign_event" request for allowed kind 30023 from the damage_nostr client
    Then the live NIP-46 request MUST be accepted by at least one relay
    And a live NIP-46 reply MUST be received
    And the decrypted live NIP-46 response MUST be accepted
    And the signed live NIP-46 event MUST be kind 30023
    And the signed live NIP-46 event MUST be authored by the bunker pubkey
    And the signed live NIP-46 event MUST contain the test run id
    And the signed live NIP-46 event MUST NOT be published by the bunker relays
    And the live bunker audit log MUST contain the test run id
    And no live test context MUST contain secret material
