Feature: Desktop duplicate-submit guards with fixture responses
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I resize the WebDriver viewport to "1440" by "1100"
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: Repeated generation shortcuts submit once
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response gate is "hold"
    When I press the WebDriver key "Control+Enter"
    When I press the WebDriver key "Control+Enter"
    When the dashboard fixture response gate is "release"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-draft-panel" should be "visible"
    Then the dashboard fixture should have "1" requests for "generate"
    Then the dashboard fixture should have "0" requests for "execute"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then I close the WebDriver browser

  Scenario: Repeated Run shortcuts submit once
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Fixture-only execution"
    Given the dashboard fixture response gate is "hold"
    When I press the WebDriver key "Control+Enter"
    When I press the WebDriver key "Control+Enter"
    When the dashboard fixture response gate is "release"
    Then the WebDriver element "#execute-feature-btn" should be "enabled"
    Then the dashboard fixture should have "1" requests for "execute"
    Then I close the WebDriver browser
