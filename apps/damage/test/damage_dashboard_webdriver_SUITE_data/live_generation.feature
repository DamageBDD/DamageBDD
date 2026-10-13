Feature: Live ECAI generation without feature execution
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: The configured ECAI returns a reviewable draft for a real prompt
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep live test draft"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Use only available HTTP steps. Check GET https://example.com/ returns HTTP 200. Do not execute the feature or print credentials."
    When I click the WebDriver element "#bdd-generate"
    When I set the WebDriver wait to "180000" milliseconds
    Then the WebDriver element "#bdd-draft-panel" should be "visible"
    Then the WebDriver element "#bdd-accept" should be "enabled"
    Then the WebDriver text in "#bdd-draft-source" should contain "Feature:"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the WebDriver text in "#bdd-run-status" should contain "Not run"
    Then I close the WebDriver browser
