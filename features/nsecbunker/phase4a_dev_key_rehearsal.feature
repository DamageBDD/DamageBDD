Feature: Phase 4A dev DamageBDD key rehearsal

  Scenario: Dev key is created inside the Phase 4A vault
    Given the Phase 4A dev key ceremony script exists
    And the Phase 4A dev vault path is configured
    When I run the Phase 4A dev key ceremony
    Then the Phase 4A dev key report MUST exist
    And the Phase 4A dev key report MUST contain a 64 lowercase hex pubkey
    And the Phase 4A dev key report MUST contain an npub
    And the Phase 4A dev key report MUST NOT contain secret material
