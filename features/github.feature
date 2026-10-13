Feature: Sync GitHub issues with DamageBDD

  Background:
    Given I use github oauth token "ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXX"
    And I use github repo "damagebdd/damagebdd"

  Scenario: Verify an issue is open
    When I load github issue "42"
    Then the github issue state should be "open"

  Scenario: Mark commit status after DamageBDD run
    When I set github status for sha "abc123def456" to "success"
      with description "DamageBDD: all BDD suites green"
      and context "damagebdd/ci"
    Then the github combined status for ref "abc123def456" should be "success"
