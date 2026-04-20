Feature: L402 payment via NIP-47 and execute_feature
  Background:
    Given I am using server "https://run.dev.damagebdd.com"
    #Given I am using server "https://lightning.lodgeit.org"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    And I set "content-type" header to "application/json"

  Scenario: pay for execute_feature using NWC wallet


    ############################################
    # 1. Mint NWC wallet
    ############################################
    When I make a POST request to "/api/nwc/mint"
    """
    {
      "relays": ["wss://relay.damus.io"],
      "max_single_sat": 1000,
      "max_total_sat": 5000,
      "expires_height": 0
    }
    """
    Then the response status must be "200"
    And I store the JSON at path "$.nwc_uri" in "nwc_uri"

    Given I parse the NWC URI in "nwc_uri" and store it as "conn"

    ############################################
    # 2. Call paid endpoint → expect 402
    ############################################
    When I make a POST request to "/execute_feature"
    """
    Feature: Paid test
      Scenario: simple run
        Given I set the variable "x" to "1"
        Then the variable "x" should be equal to JSON "1"
    """
    Then the response status must be "402"

    # capture invoice + macaroon from headers
    And I store the JSON at path "$.invoice" in "invoice_bolt11"
    And I store the JSON at path "$.macaroon" in "macaroon"

    ############################################
    # 3. Pay invoice via NIP-47
    ############################################
    When I build NWC request "pay_invoice" using "conn" store as "req_pay"
    """
    {
      "invoice": "{{invoice_bolt11}}"
    }
    """
    And I publish NWC request in "req_pay" store relay ack as "pub_pay"
    And I wait for NWC response to "req_pay" using "conn" store as "resp_pay"

    ############################################
    # 4. Retry request with L402 auth
    ############################################
    And I set "Authorization" header to "L402 {{macaroon}}"

    When I make a POST request to "/execute_feature"
    """
    Feature: Paid test
      Scenario: simple run
        Given I set the variable "x" to "1"
        Then the variable "x" should be equal to JSON "1"
    """
    Then the response status must be "200"
    And I print the response
