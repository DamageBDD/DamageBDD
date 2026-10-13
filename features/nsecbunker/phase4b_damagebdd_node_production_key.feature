Feature: Phase 4B production DamageBDD node key ceremony

  Scenario: Production DamageBDD node key is created inside the Phase 4B vault
    Given the Phase 4B production key ceremony script exists
    And the Phase 4B production vault path is configured
    And the Phase 4B production key ceremony is explicitly approved
    When I run the Phase 4B production key ceremony
    Then the Phase 4B production key report MUST exist
    And the Phase 4B production key report MUST contain a 64 lowercase hex pubkey
    And the Phase 4B production key report MUST contain an npub
    And the Phase 4B production key report MUST NOT contain secret material
    And the Phase 4B production vault MUST exist
    And the Phase 4B production vault MUST NOT be world readable
