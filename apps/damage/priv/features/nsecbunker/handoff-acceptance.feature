@damage @nsecbunker @handoff @read-only
Feature: Original AWS bunker handoff is supported by current evidence
  Run the dashboard checks first. These assertions only read evidence; they
  never perform maintenance, add clients or manufacture operator signoff.

  Scenario: Technical handover is complete
    Then the bunker handoff health evidence MUST be fresh
    And the bunker handoff technical checks MUST be complete

  Scenario: The operator has accepted the verified handover
    Then the bunker handoff MUST have an operator acceptance
