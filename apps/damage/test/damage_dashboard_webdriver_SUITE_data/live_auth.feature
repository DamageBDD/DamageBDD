Feature: Real dashboard authentication
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Scenario: An unauthenticated browser cannot see the dashboard
    Given I start the configured WebDriver browser
    When I open the WebDriver dashboard
    Then the WebDriver element "#login-username" should be "visible"
    Then the WebDriver element "#dashboard-sidebar" should be "absent"
    Then the WebDriver element "[data-dashboard-shell]" should be "absent"
    Then I close the WebDriver browser

  Scenario: Invalid credentials show a failure and do not reveal the shell
    Given I start the configured WebDriver browser
    When I open the WebDriver dashboard
    When I fill the WebDriver element "#login-username" with "dashboard-negative-test@example.invalid"
    When I fill the WebDriver element "#password" with "not-a-real-password"
    When I click the WebDriver element "#loginSubmitBtn"
    Then the WebDriver text in "#connect-status" should contain "Login Failed"
    Then the WebDriver element "[data-dashboard-shell]" should be "absent"
    Then I close the WebDriver browser

  Scenario: A real test account can sign in and then sign out
    Given I start the configured WebDriver browser
    When I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"
    When I select the WebDriver dashboard section "activity-tab"
    When I select the WebDriver dashboard section "execution-tab"
    When I use the WebDriver sidebar action "sign-out"
    Then the WebDriver element "#logout-modal" should be "visible"
    When I click the WebDriver element "#logoutSubmitBtn"
    Then the WebDriver element "#login-username" should be "visible"
    Then I close the WebDriver browser
