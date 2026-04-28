Feature: L402 payment via NIP-47 and execute_feature
  🧪 End-to-End BDD: L402 → NIP-47 → Execute Feature
  What this test does
    Mint NWC wallet
    Call a paid endpoint (/execute_feature) → get 402 invoice
    Pay invoice via NIP-47 over relay
    Retry request with macaroon → succeed
  This proves:
    L402 enforcement works
    NWC listener works
    relay roundtrip works
    Lightning payment works
    feature execution works

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
      "relays": [
            "wss://nostr-01.yakihonne.com",
            "wss://relay.damus.io",
            "wss://nostr-02.yakihonne.com",
            "wss://nos.lol"
        ],
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
    And I set "Content-Type" header to "text/plain"
    And I clear header "Authorization"
    When I make a POST request to "/execute_feature"
    """
    Feature: Paid test
      Scenario: simple run
        Given I set the variable "x" to "1"
        Then the variable "x" should be equal to JSON "1"
    """
    Then the response status must be "402"

    # capture invoice + macaroon from headers
    Then I store the L402 invoice in "invoice_bolt11"
    Then I store the L402 macaroon in "macaroon"

    ############################################
    # 3. Pay invoice via NIP-47
    ############################################
    When I build NWC request "pay_invoice" using "conn" store as "req_pay"
    """
    {
        "invoice": "{{invoice_bolt11}}"
    }
    """
    And I publish NWC request in "req_pay" using "conn" and wait for response store as "resp_pay"
    And I store the JSON at path "$.response.preimage" from "resp_pay" in "payment_preimage"

    ############################################
    # 4. Retry request with L402 auth
    ############################################

    And I set "Content-Type" header to "text/plain"
    And I set "Authorization" header to "L402 {{macaroon}}:{{payment_preimage}}"
    When I make a POST request to "/execute_feature/"
    """
    Feature: Paid test
      Scenario: simple run
        Given I set the variable "x" to "1"
        Then the variable "x" should be equal to JSON "1"
    """
    Then the response status must be "200"
    And I print the response
