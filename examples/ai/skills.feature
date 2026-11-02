@ai @live
Feature: AI skills return results with explicit behavioural contracts

  Background:
    Given I use AI profile "local"

  Scenario: Classify a billing complaint into an approved category
    Given I set the AI input to
      """
      I was charged twice for order A123. Please help with the duplicate charge.
      """
    And I set the AI labels to
      """
      ["billing", "technical", "sales"]
      """
    When I run AI skill "classify" and store result in "ai_category"
    Then the AI result should equal "billing"
    And the AI request should finish within "30000" milliseconds

  Scenario: Extract typed facts and preserve missing values
    Given I set the AI input to
      """
      Order A123 has a total of 42.50 AUD. No refund date is recorded.
      """
    And I set the AI fields to
      """
      {"order_id":"string","amount":"number","currency":"string","refund_date":"string"}
      """
    When I extract fields from the AI input and store result in "ai_order"
    Then the AI result should be valid JSON
    And the AI result at pointer "/order_id" should equal JSON
      """
      "A123"
      """
    And the AI result at pointer "/amount" should equal JSON
      """
      42.5
      """
    And the AI result at pointer "/refund_date" should equal JSON
      """
      null
      """

  Scenario: Summarize an incident while retaining its identifier
    Given I set the AI input to
      """
      Incident INC-481 affected checkout for twelve minutes.
      The rollback restored service. Root cause remains under investigation.
      """
    When I summarize the AI input and store result in "ai_summary"
    Then the AI result should contain "INC-481"

  Scenario: Run a configured versioned skill
    Given I set the AI input to
      """
      A customer reports a duplicate charge for order A123.
      """
    When I run AI skill "support-triage" and store result in "ai_triage"
    Then the AI result should be valid JSON
