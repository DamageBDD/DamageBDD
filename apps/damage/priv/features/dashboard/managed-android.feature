Feature: Verify the live dashboard using DamageBDD-managed Appium
  Select a dedicated Android Chrome device in the trusted android profile.
  This test neither makes a payment nor runs a feature from the browser UI.

  Background:
    Given I use WebDriver profile "android"
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard

  Scenario: Mobile navigation closes the drawer and focuses the selected section
    Then the WebDriver dashboard layout should be "mobile"
    When I select the WebDriver dashboard section "activity-tab"
    Then the WebDriver element "#activity-tab" should be "visible"
    Then the WebDriver element "#activity-tab" should be "focused"
    Then the WebDriver element "#dashboard-sidebar" property "inert" should equal JSON "true"
    Then the WebDriver element "#dashboard-nav-backdrop" should be "hidden"
    When I select the WebDriver dashboard section "execution-tab"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser
