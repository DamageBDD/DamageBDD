Feature: L402 end-to-end paywall
  Scenario: Paywall challenge, pay invoice, retry with L402 auth
    Given I am using server "http://localhost:8080"
    And I set "content-type" header to "application/json"

    # 1) Hit a protected endpoint without Authorization → expect 402 + L402 challenge
    When I make a POST request to "/api/protected/run"
    """
    {"hello":"world"}
    """
    Then the response status must be "402"
    Then I store L402 challenge macaroon in "l402_macaroon" and invoice in "l402_invoice"

    # 2) Pay invoice and get preimage
    When I pay the L402 invoice "{{l402_invoice}}" via CLN and store preimage in "l402_preimage"

    # 3) Retry with Authorization: L402 <macaroon>:<preimage>
    When I set L402 Authorization header using macaroon "{{l402_macaroon}}" and preimage "{{l402_preimage}}"
    And I make a POST request to "/api/protected/run"
    """
    {"hello":"world"}
    """
    Then the response status must be "200"
