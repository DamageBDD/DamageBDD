Feature: Mobile browser dashboard drawer
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: The closed drawer cannot receive focus
    Then the WebDriver dashboard layout should be "mobile"
    Then the WebDriver element "#dashboard-sidebar" property "inert" should equal JSON "true"
    Then the WebDriver element "#dashboard-main" property "inert" should equal JSON "false"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Opening and closing the drawer updates modal state and focus
    Then the WebDriver dashboard layout should be "mobile"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "#dashboard-sidebar" attribute "role" should be "dialog"
    Then the WebDriver element "#dashboard-sidebar" attribute "aria-modal" should be "true"
    Then the WebDriver element "#dashboard-sidebar" should be "contains-focus"
    Then the WebDriver element "#dashboard-main" property "inert" should equal JSON "true"
    When I click the WebDriver element "#dashboard-nav-close"
    Then the WebDriver element "#dashboard-sidebar" property "inert" should equal JSON "true"
    Then the WebDriver element "#dashboard-main" property "inert" should equal JSON "false"
    Then the WebDriver element "#dashboard-nav-toggle" should be "focused"
    Then I close the WebDriver browser

  Scenario: Selecting a section closes the drawer and focuses the panel
    Then the WebDriver dashboard layout should be "mobile"
    When I select the WebDriver dashboard section "activity-tab"
    Then the WebDriver element "#activity-tab" should be "visible"
    Then the WebDriver element "#activity-tab" should be "focused"
    Then the WebDriver element "#dashboard-sidebar" property "inert" should equal JSON "true"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Tapping outside the drawer dismisses it
    Then the WebDriver dashboard layout should be "mobile"
    When I click the WebDriver element "#dashboard-nav-toggle"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "visible"
    When I dismiss the WebDriver dashboard drawer using the backdrop
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    Then the WebDriver element "#dashboard-nav-toggle" should be "focused"
    Then I close the WebDriver browser
