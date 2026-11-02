Feature: Recorded browser vocabulary

  # Set account secret: browser_secret_test (never include its value in this file)
  Scenario: Replay the recorded journey
    Given I start a recorded browser at "https://example.test/signup"
    When I type into recorded field "#name"
      """
      Alice
      """
    When I type secret "browser_secret_test" into recorded field "#password"
    When I select recorded option in "#plan"
      """
      pro
      """
    When I set recorded checkbox "#terms" to checked
    When I set recorded checkbox "#terms" to unchecked
    When I press Enter in recorded field "#name"
    When I click recorded element "#submit"
    Then recorded element "#message" should contain text
      """
      Success
      """
    Then the recorded browser URL should start with "https://example.test/done"
    When I navigate the recorded browser to "https://example.test/logout"
    Then I close the recorded browser
