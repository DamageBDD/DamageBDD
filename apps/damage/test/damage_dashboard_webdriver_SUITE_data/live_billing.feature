Feature: Authorised billing read-only controls
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: An invoice-authorised test account can view invoice management
    Then the WebDriver element "#billing-nav" property "hidden" should equal JSON "false"
    When I select the WebDriver dashboard section "billing-tab"
    Then the WebDriver element "#enterprise-billing" should be "visible"
    Then the WebDriver text in "#billing-title" should contain "Invoices"
    Then the WebDriver element "#billing-status-filter" should be "visible"
    When I click the WebDriver element "[data-billing-pane=customers]"
    Then the WebDriver element "[data-billing-content=customers]" should be "visible"
    When I click the WebDriver element "[data-billing-pane=invoices]"
    Then the WebDriver element "[data-billing-content=invoices]" should be "visible"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser
