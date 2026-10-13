Feature: Lightning Swap Options API (issue-linked)

  # Tests:
  #  - Create a swap option via your backend API (which should also create an LN invoice)
  #  - List swap options via your backend API (which should be backed by AE contract events)
  #  - Fetch raw AE contract logs from MDW for the LightningSwapOption contract
  Background:

    Given I am using server "https://run.dev.damagebdd.com"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    And I set "accept" header to "application/json"
    And I set "content-type" header to "application/json"

    # Adjust these to your actual deployment
    And I set the variable "swap_contract_id" to "ct_REPLACE_ME"
    And I set the variable "issue_url" to "https://github.com/damagebdd/damagebdd/issues/42"
    And I set the variable "buyer_ak" to "ak_fundertest123"
    And I set the variable "seller_ak" to "ak_treasury123"

    And I set the variable "lock_sats" to "20000"
    And I set the variable "payout_damage" to "500"
    And I set the variable "expiry_seconds" to "86400"

  Scenario: Create a swap option returns a Lightning invoice and payment hash
    When I make a POST request to "/swaps"
    """
    {
      "contract_id": "{{swap_contract_id}}",
      "issue_url": "{{issue_url}}",
      "buyer_ak": "{{buyer_ak}}",
      "seller_ak": "{{seller_ak}}",
      "sats_amount": {{lock_sats}},
      "damage_amount": {{payout_damage}},
      "expiry_seconds": {{expiry_seconds}}
    }
    """
    Then the response status must be one of "200,201"
    Then the response must contain text "bolt11"
    Then the response must contain text "payment_hash"

  Scenario: List swap options includes the issue link
    When I make a GET request to "/swaps"
    Then the response status must be "200"
    Then the response must contain text "{{issue_url}}"

  Scenario: MDW contract logs are accessible for the swap contract
    # Switch base URL to MDW for this scenario
    Given I set base URL to "https://mainnet.aeternity.io/mdw"
    And I set "accept" header to "application/json"

    # Pull latest logs for the contract; you can also add &event=<EVENT_HASH> once you’ve got it
    When I make a GET request to "/v3/contracts/logs?contract_id={{swap_contract_id}}&direction=backward&limit=10"
    Then the response status must be "200"
    Then the response must contain text "\"data\""
