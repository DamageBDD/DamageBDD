Feature: Phase 4B production NIP-46 relay path

  The LodgeiT Labs publisher identity is held inside the production
  nsecbunker vault.

  The production bunker must listen for NIP-46 requests addressed to the
  node pubkey and publish NIP-46 replies on the configured relay set.

  Background:
    Given the production bunker node pubkey is "a4e869b6165998b618d44014a8cb5163ccc9e6a665adfca98d4a3fe732ea1af9"
    And the authorised LodgeiT client pubkey is "4b81f037343f30a30ca1da52d13b5a78ef4d1c0e44375823c019981bb460830f"
    And the production NIP-46 relays are exactly:
      | relay                    |
      | wss://relay.primal.net   |
      | wss://relay.damus.io     |
      | wss://nos.lol            |
    And the NIP-46 event kind is 24133

  Scenario: Production bunker relay surface is visible
    When I subscribe for recent NIP-46 events authored by the production bunker node pubkey
    Then the relay subscription MUST return EOSE without relay failure

  Scenario: Production bunker accepts an authorised connect request
    When the authorised LodgeiT client publishes a NIP-46 "connect" request p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the bunker reply MUST be kind 24133
    And the bunker reply MUST be authored by the production bunker node pubkey
    And the bunker reply MUST be p-tagged to the authorised LodgeiT client pubkey
    And the bunker reply MUST contain no secret material

  Scenario: Production bunker responds to ping
    When the authorised LodgeiT client publishes a NIP-46 "ping" request p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the bunker reply MUST be kind 24133
    And the decrypted NIP-46 response result MUST be "pong"
    And the bunker reply MUST contain no secret material

  Scenario: Production bunker returns the LodgeiT Labs publisher pubkey
    When the authorised LodgeiT client publishes a NIP-46 "get_public_key" request p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the decrypted NIP-46 response result MUST equal "a4e869b6165998b618d44014a8cb5163ccc9e6a665adfca98d4a3fe732ea1af9"
    And the bunker reply MUST contain no secret material

  Scenario: Unknown client cannot reach the production signing surface
    Given an unknown client pubkey is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    When the unknown client publishes a NIP-46 "connect" request p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the request MUST be rejected or remain unsigned
    And no signature material MUST be exposed

  Scenario: Non-allowlisted method is rejected
    When the authorised LodgeiT client publishes a NIP-46 "nip04_decrypt" request p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the request MUST be rejected
    And the denial reason MUST be "method_not_allowed"
    And no signature material MUST be exposed

  Scenario: Non-allowlisted event kind is rejected
    When the authorised LodgeiT client publishes a NIP-46 "sign_event" request for kind 1 p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the request MUST be rejected
    And the denial reason MUST be "event_kind_not_allowed"
    And no signature material MUST be exposed

  Scenario: Allowed kind 30023 can be signed
    When the authorised LodgeiT client publishes a NIP-46 "sign_event" request for kind 30023 p-tagged to the production bunker node pubkey
    And I wait for a NIP-46 reply authored by the production bunker node pubkey
    Then the request MUST be accepted
    And the signed event MUST be kind 30023
    And the signed event MUST be authored by the production bunker node pubkey
    And the bunker MUST NOT publish the signed event to any relay
    And the publisher private key MUST never leave the bunker
