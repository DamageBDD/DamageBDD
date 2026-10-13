Feature: Verify the live dashboard using DamageBDD-managed Chrome
  This runs through the ordinary DamageBDD runner and its normal accounting.
  The desktop profile, credentials and driver provisioning are operator settings.

  Background:
    Given I use WebDriver profile "desktop"
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard

  Scenario: Navigate the sidebar without losing the workspace
    Then the WebDriver dashboard layout should be "desktop"
    Then the WebDriver element "#execution-tab" should be "visible"
    When I select the WebDriver dashboard section "activity-tab"
    Then the WebDriver element "#activity-tab" should be "visible"
    Then the WebDriver URL fragment should be "#activity-tab"
    When I select the WebDriver dashboard section "execution-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver element "#bdd-prompt" should be "visible"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser
