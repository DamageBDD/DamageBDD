Feature: Desktop sidebar behaviour
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I resize the WebDriver viewport to "1440" by "1100"
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: The sidebar collapses and restores its preference after reload
    Then the WebDriver dashboard layout should be "desktop"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "[data-dashboard-shell].sidebar-collapsed" should be "visible"
    Then the WebDriver element "#dashboard-nav-toggle" attribute "aria-expanded" should be "false"
    When I refresh the WebDriver page
    Then the WebDriver element "[data-dashboard-shell].sidebar-collapsed" should be "visible"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "[data-dashboard-shell].sidebar-collapsed" should be "absent"
    Then the WebDriver element "#dashboard-nav-toggle" attribute "aria-expanded" should be "true"
    Then I close the WebDriver browser

  Scenario: Keyboard focus moves before Enter activates a section
    When I press the WebDriver key "Home" in "#dashboard-link-activity"
    Then the WebDriver element "#dashboard-link-execution" should be "focused"
    When I press the WebDriver key "ArrowDown"
    Then the WebDriver element "#dashboard-link-activity" should be "focused"
    Then the WebDriver element "#execution-tab" should be "visible"
    When I press the WebDriver key "Enter"
    Then the WebDriver element "#activity-tab" should be "visible"
    Then I close the WebDriver browser

  Scenario: Resizing an open mobile drawer releases its modal restrictions
    When I resize the WebDriver viewport to "390" by "844"
    Then the WebDriver dashboard layout should be "mobile"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "#dashboard-main" property "inert" should equal JSON "true"
    When I resize the WebDriver viewport to "1440" by "1100"
    Then the WebDriver dashboard layout should be "desktop"
    Then the WebDriver element "#dashboard-main" property "inert" should equal JSON "false"
    Then the WebDriver element "#dashboard-sidebar" property "inert" should equal JSON "false"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Escape closes the drawer and returns focus to its trigger
    When I resize the WebDriver viewport to "390" by "844"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "#dashboard-sidebar" should be "contains-focus"
    When I press the WebDriver key "Escape"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    Then the WebDriver element "#dashboard-nav-toggle" should be "focused"
    Then I close the WebDriver browser
