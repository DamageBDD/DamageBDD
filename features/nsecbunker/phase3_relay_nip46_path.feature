Feature: Phase 3 relay and encrypted NIP46 path
  The bunker decides whether to sign.
  The relay layer publishes.
  Relay publication success or failure MUST NOT change the signing decision.

  Scenario: Subscription filter targets NIP46 events p tagged to the bunker
    Given Phase 3 disposable bunker pubkey is "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    When the Phase 3 subscription filter is created
    Then the Phase 3 subscription filter MUST include kind 24133
    And the Phase 3 subscription filter MUST be p tagged to the bunker

  Scenario: Signed response event is returned when relay publication is return only
    Given Phase 3 relay publication mode is "return_only"
    And Phase 3 disposable client pubkey is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    And Phase 3 disposable bunker pubkey is "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    And the bunker has produced a signed NIP46 response event
    When the Phase 3 relay client handles the signed response event
    Then the Phase 3 relay result MUST be ok
    And the Phase 3 relay result MUST contain a response event
    And the Phase 3 publication result MUST be ok

  Scenario: Signing decision survives relay publication failure
    Given Phase 3 relay publication mode is "test_fail"
    And Phase 3 disposable client pubkey is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    And Phase 3 disposable bunker pubkey is "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    And the bunker has produced a signed NIP46 response event
    When the Phase 3 relay client handles the signed response event
    Then the Phase 3 relay result MUST be ok
    And the Phase 3 relay result MUST contain a response event
    And the Phase 3 publication result MUST be failure
    And the Phase 3 signing decision MUST survive relay publication failure
