Feature: Accountable asynchronous code review
  Scenario: Launch a review without occupying the parent feature
    Given I use agent template "code-review"
    When I start an agent task named "review" with objective
      """
      Review the configured source snapshot for correctness and failure handling.
      Explain each finding with file references and evidence. Separate confirmed
      observations from hypotheses. Produce review.md. Do not apply changes,
      merge code, publish reports, or claim that unrun tests passed.
      """
    Then the agent task "review" should be accepted
    And the agent task "review" should have learning evidence

# Acceptance here means that the separate task exists, NOT that it completed.
# Inspect /automated-tasks or the authenticated API for its eventual outcome.
# An optional bounded join is:
#   When I await agent task "review" for "30" seconds
#   Then the agent task "review" should be "completed"
# The join never extends the task's own deadline or approval permissions.
