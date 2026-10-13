Feature: Lightning Swap Options UI (GitHub-linked)

  # This feature drives the browser via Chrome DevTools Protocol (CDP).
  # Prereq: you have a running CDP endpoint available in context (e.g. :9222).

  Background:
    Given I attach CDP
    And I set the variable "base_url" to "https://run.staging.damagebdd.com"

  Scenario: Swap Options page loads and shows the Swap Options section
    When I open "https://run.staging.damagebdd.com"
    When I wait for "#swap-options-tab"
    Then the page should contain "Lightning Swap Options"
    And the page should contain "Create Option"

  Scenario: Create a swap option linked to a GitHub issue and receive a Lightning invoice
    # Navigate to your page that includes the swap options UI.
    When I open "https://run.staging.damagebdd.com"
    When I wait for "#swap-options-tab"

    # Open modal
    When I click text "Create Option"
    When I wait for "#swap-create-modal"

    # Fill form (IDs match the UI snippet you generated)
    When I type "https://github.com/damagebdd/damagebdd/issues/42" into "#swap-issue-url"
    And I type "ak_fundertest123" into "#swap-buyer-ak"
    And I type "ak_treasury123" into "#swap-seller-ak"
    And I type "20000" into "#swap-sats"
    And I type "500" into "#swap-damage"
    And I type "86400" into "#swap-ttl"

    # Submit
    When I click "#swap-create-submit"

    # Verify invoice result rendered
    When I wait until the page contains "Lightning Invoice"
    Then the page should contain "payment_hash"

  Scenario: Refresh lists options sourced from chain events and shows issue reference
    When I open "https://run.staging.damagebdd.com"
    When I wait for "#swap-options-tab"

    # Refresh (should re-fetch MDW logs and re-render table)
    When I click "#swap-refresh-btn"

    # Expect the issue reference to appear somewhere in the table
    # (derived from issue URL: owner/repo#number)
    When I wait until the page contains "damagebdd/damagebdd#42"
    Then the page should contain "damagebdd/damagebdd#42"
