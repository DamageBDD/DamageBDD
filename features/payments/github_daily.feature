Feature: Reward daily commits with LNURL payment

  Scenario: Pay via LNURL if repo has commits today
    Given I am using server "https://api.github.com"
    And I set "Accept" header to "application/vnd.github+json"
    And I set "User-Agent" header to "DamageBDD"
    And I set the variable "Owner" to "DamageBDD"
    And I set the variable "Repo" to "DamageBDD.com"
    And I set the variable "Branch" to "main"
    And I store current time string in "Today" with format "%Y-%m-%d"
    And I set the variable "Since" to "{{Today}}T00:00:00Z"
    And I set the variable "Until" to "{{Today}}T23:59:59Z"

    When I make a GET request to "/repos/{{Owner}}/{{Repo}}/commits?sha={{Branch}}&since={{Since}}&until={{Until}}"
    Then the response status must be "200"
    And I store the JSON at path "$" in "Commits"
    And the variable "Commits" should be equal to JSON:
      []

    # If there are commits, make a payment
    # This branch is triggered when commits are not equal to []

  Scenario: Make LNURL payment if commits exist
    Given I set the variable "LNURLPayServer" to "https://pay.example.com"
    Given I am using server "{{LNURLPayServer}}"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer YOUR_LNURL_API_KEY"

    When I make a POST request to "/api/v1/pay"
    """
    {
      "amount": 1000,
      "lnurl": "lnurl1dp68gurn8ghj7mrww4exctn0d3skccnpwpc82unvwqhk6ct9wfjx2ap0d3skccnpwpc82unvwqhk6"
    }
    """
    Then the response status must be "200"
    And I print the response
