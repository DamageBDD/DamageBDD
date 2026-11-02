Feature: Reviewed model acceptance
  # Replace all example values before execution. The authenticated managed
  # request must provide access_token in the runner's server-side context.
  # Never commit or paste that bearer into this feature. Use a new key for
  # each deliberately new evaluation, and the same key for submission retries.
  Scenario: Require an evidence-backed evaluation gate
    When I run the ECAI evaluation suite "REPLACE_WITH_SUITE_HASH" on split "test" with key "REPLACE_WITH_UNIQUE_RUN_KEY"
    And I wait up to "120" seconds for the ECAI evaluation
    Then the ECAI evaluation release gate must pass
