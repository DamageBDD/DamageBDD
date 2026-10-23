Feature: Review with an operator-approved monetary ceiling
  # Uses the exact accounting schedule on the configured code-review template.
  # This launch scenario is asynchronous; inspect completion in /automated-tasks.
  Scenario: Submit an accounted review
    Given I use agent template "code-review"
    When I start an agent task named "review" with objective
      """
      Review the configured source snapshot. Produce review.md with specific
      findings and supporting file references. Do not apply changes or claim
      unrun tests passed. Stay within the granted capabilities and budget.
      """
    Then the agent task "review" should be accepted

  # Completion assertions are provided for a feature that has refreshed or joined
  # its own task handle; handles are not assumed to carry across scenarios:
  # When I await agent task "review" for "60" seconds
  # Then the agent task "review" should have settled accounting
  # And the agent task "review" should stay within its monetary budget
