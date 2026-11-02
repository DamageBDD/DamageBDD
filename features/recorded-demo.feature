Feature: Recorder demo signup

  Scenario: Replay the recorded journey
    Given I start a recorded browser at "http://127.0.0.1:8787/sample-app.html"
    When I type into recorded field "input[data-testid='signup-email']"
      """
      demo@example.test
      """
    # Supply the secret named below to the DamageBDD node before running.
    When I type secret "browser_secret_6261d21b" into recorded field "input[data-testid='signup-password']"
    When I set recorded checkbox "#agree" to checked
    When I click recorded element "button[data-testid='signup-submit']"
    Then recorded element "#result" should contain text
      """
      Your demo account is ready
      """
    Then I close the recorded browser
