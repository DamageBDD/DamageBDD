Feature: Dashboard navigation and authoring state
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: Workspace is the initial section
    Then the WebDriver element "#execution-tab" should be "visible"
    Then the WebDriver element "#dashboard-link-execution" attribute "aria-current" should be "page"
    Then the WebDriver element "#dashboard-navigation[role=tablist]" should be "absent"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Selecting dashboard sections updates panel and history
    When I select the WebDriver dashboard section "activity-tab"
    Then the WebDriver element "#activity-tab" should be "visible"
    Then the WebDriver URL fragment should be "#activity-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "analytics-tab"
    Then the WebDriver element "#analytics-tab" should be "visible"
    Then the WebDriver URL fragment should be "#analytics-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "schedules-tab"
    Then the WebDriver element "#schedules-tab" should be "visible"
    Then the WebDriver URL fragment should be "#schedules-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "settings-tab"
    Then the WebDriver element "#settings-tab" should be "visible"
    Then the WebDriver URL fragment should be "#settings-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "swap-options-tab"
    Then the WebDriver element "#swap-options-tab" should be "visible"
    Then the WebDriver URL fragment should be "#swap-options-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "ecai-jobs-tab"
    Then the WebDriver element "#ecai-jobs-tab" should be "visible"
    Then the WebDriver URL fragment should be "#ecai-jobs-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    When I select the WebDriver dashboard section "execution-tab"
    Then the WebDriver element "#execution-tab" should be "visible"
    Then the WebDriver URL fragment should be "#execution-tab"
    Then exactly one WebDriver dashboard section should be visible
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Navigation preserves prompt and unsaved feature edits
    When I fill the WebDriver element "#damageTextArea" with
    """
    Feature: Unsaved draft
      Scenario: Preserve this work
        Given I set the variable "x" to "1"
    """
    When I remember the WebDriver value of "#damageTextArea" as "draft"
    When I fill the WebDriver element "#bdd-prompt" with "Check the health endpoint without running it"
    When I select the WebDriver dashboard section "activity-tab"
    When I select the WebDriver dashboard section "execution-tab"
    Then the WebDriver value of "#damageTextArea" should equal remembered "draft"
    Then the WebDriver value of "#bdd-prompt" should be "Check the health endpoint without running it"
    Then I close the WebDriver browser

  Scenario: Back and Forward restore the corresponding section
    When I select the WebDriver dashboard section "activity-tab"
    When I select the WebDriver dashboard section "schedules-tab"
    When I go back in the WebDriver browser
    Then the WebDriver element "#activity-tab" should be "visible"
    Then the WebDriver URL fragment should be "#activity-tab"
    When I go forward in the WebDriver browser
    Then the WebDriver element "#schedules-tab" should be "visible"
    Then the WebDriver URL fragment should be "#schedules-tab"
    Then I close the WebDriver browser

  Scenario: A deep link selects its section on a full page load
    When I open the WebDriver dashboard at fragment "#analytics-tab"
    Then the WebDriver element "#analytics-tab" should be "visible"
    Then the WebDriver text in "#dashboard-section-title" should contain "Analytics"
    Then exactly one WebDriver dashboard section should be visible
    Then I close the WebDriver browser

  Scenario: An unknown deep link falls back to Workspace
    When I open the WebDriver dashboard at fragment "#unknown-dashboard-section"
    Then the WebDriver element "#execution-tab" should be "visible"
    Then exactly one WebDriver dashboard section should be visible
    Then I close the WebDriver browser

  Scenario: Execution context can be expanded without losing the feature
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep context draft"
    When I click the WebDriver element "#edit-execution-context-btn"
    Then the WebDriver element "#execution-context-editor" should be "visible"
    Then the WebDriver element "#edit-execution-context-btn" attribute "aria-expanded" should be "true"
    When I click the WebDriver element "#edit-execution-context-btn"
    Then the WebDriver element "#execution-context-editor" should be "hidden"
    Then the WebDriver value of "#damageTextArea" should be "Feature: Keep context draft"
    Then I close the WebDriver browser

  Scenario: The step library inserts a deployed signature into the editor
    When I click the WebDriver element ".bdd-step-library summary"
    When I fill the WebDriver element "#bdd-step-search" with "I make a GET request"
    Then the WebDriver text in "#bdd-step-results" should contain "I make a GET request"
    When I click the WebDriver element "#bdd-step-results .bdd-step-item:first-child button"
    Then the WebDriver value of "#damageTextArea" should contain "I make a GET request"
    Then the WebDriver element "#damageTextArea" should be "focused"
    Then I close the WebDriver browser
