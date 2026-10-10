Feature: Authentication surfaces with simulated wallet and services
  These scenarios use the production auth UI through Selenium or Appium.
  The dedicated auth fixture simulates wallet RPC, email and the auth API.
  No live credentials, signing keys, email, transaction or payment is used.

  Background:
    Given I start the configured WebDriver browser
    When I open the WebDriver dashboard
    Then the WebDriver element "#login-username" should be "visible"

  Scenario: Loading the page never prompts a wallet
    Then the WebDriver element "#login-username" should be "focused"
    Then the WebDriver element "#fixture-count-connect" property "fixtureCount" should equal JSON "0"
    Then the WebDriver element "#fixture-count-sign" property "fixtureCount" should equal JSON "0"
    Then the WebDriver page should have no horizontal overflow
    Then I close the WebDriver browser

  Scenario: Invalid email credentials leave the user at sign-in
    When I fill the WebDriver element "#login-username" with "negative@example.invalid"
    When I fill the WebDriver element "#password" with "not-a-real-password"
    When I click the WebDriver element "#loginSubmitBtn"
    Then the WebDriver text in "#connect-status" should contain "Email or password is incorrect"
    Then the WebDriver element "#loginSubmitBtn" should be "enabled"
    Then the WebDriver element "#auth-fixture-dashboard" should be "hidden"
    Then I close the WebDriver browser

  Scenario: Enter on signup never submits the login form
    When I click the WebDriver element "#auth-signup-tab"
    When I fill the WebDriver element "#signup-username" with "signup@fixture.example"
    When I press the WebDriver key "Enter"
    Then the WebDriver element "#signup-confirmation" should be "visible"
    Then the WebDriver element "#fixture-count-signup" property "fixtureCount" should equal JSON "1"
    Then the WebDriver element "#fixture-count-login" property "fixtureCount" should equal JSON "0"
    Then the WebDriver element "#auth-fixture-dashboard" should be "hidden"
    Then I close the WebDriver browser

  Scenario: Recovery retains the email and is a separate request
    When I fill the WebDriver element "#login-username" with "recovery@fixture.example"
    When I click the WebDriver element "#loginResetPasswdBtn"
    Then the WebDriver value of "#recovery-email" should be "recovery@fixture.example"
    When I press the WebDriver key "Enter"
    Then the WebDriver text in "#connect-status" should contain "Reset link requested"
    Then the WebDriver element "#fixture-count-recovery" property "fixtureCount" should equal JSON "1"
    Then the WebDriver element "#fixture-count-login" property "fixtureCount" should equal JSON "0"
    Then I close the WebDriver browser

  Scenario: Connecting a wallet requests a challenge but never signs automatically
    When I click the WebDriver element "#auth-wallet-tab"
    When I click the WebDriver element "#connect-button"
    Then the WebDriver element "#wallet-proof" should be "visible"
    Then the WebDriver text in "#connect-status" should contain "Connected, not signed in"
    Then the WebDriver element "#fixture-count-challenge" property "fixtureCount" should equal JSON "1"
    Then the WebDriver element "#fixture-count-sign" property "fixtureCount" should equal JSON "0"
    Then the WebDriver element "#fixture-count-verify" property "fixtureCount" should equal JSON "0"
    Then the WebDriver element "#fixture-count-tx" property "fixtureCount" should equal JSON "0"
    Then I close the WebDriver browser

  Scenario: Explicit signature approval produces a restricted wallet session
    When I click the WebDriver element "#auth-wallet-tab"
    When I click the WebDriver element "#connect-button"
    Then the WebDriver element "#wallet-proof" should be "visible"
    When I click the WebDriver element "#wallet-sign-in"
    Then the WebDriver element "#auth-fixture-dashboard" should be "visible"
    Then the WebDriver element "#fixture-pay" should be "disabled"
    Then the WebDriver element "#fixture-count-sign" property "fixtureCount" should equal JSON "1"
    Then the WebDriver element "#fixture-count-verify" property "fixtureCount" should equal JSON "1"
    Then the WebDriver element "#fixture-count-tx" property "fixtureCount" should equal JSON "0"
    Then I close the WebDriver browser

  Scenario: Email sign-in can explicitly be abandoned during an account switch
    When I fill the WebDriver element "#login-username" with "test@fixture.example"
    When I fill the WebDriver element "#password" with "fixture-only-password"
    When I click the WebDriver element "#loginSubmitBtn"
    Then the WebDriver element "#auth-fixture-dashboard" should be "visible"
    When I click the WebDriver element "#fixture-switch"
    Then the WebDriver element "#auth-keep-session" should be "visible"
    When I click the WebDriver element "#auth-keep-session"
    Then the WebDriver element "#auth-fixture-dashboard" should be "visible"
    Then the WebDriver element "#fixture-count-sign" property "fixtureCount" should equal JSON "0"
    Then I close the WebDriver browser

  Scenario: Disconnect signs out rather than falling back to another saved identity
    When I click the WebDriver element "#auth-wallet-tab"
    When I click the WebDriver element "#connect-button"
    Then the WebDriver element "#wallet-proof" should be "visible"
    When I click the WebDriver element "#wallet-sign-in"
    Then the WebDriver element "#auth-fixture-dashboard" should be "visible"
    When I click the WebDriver element "#fixture-disconnect"
    Then the WebDriver element "#login-username" should be "visible"
    Then the WebDriver element "#auth-fixture-dashboard" should be "hidden"
    Then I close the WebDriver browser
