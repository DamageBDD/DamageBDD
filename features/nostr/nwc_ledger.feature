Feature: NWC Ledger-backed connections
  The Damage NWC ledger smart contract is the source of truth for spendable sats,
  limits, and revocation.

  Background:
    Given I am using server "https://run.dev.damagebdd.com"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    And I set "content-type" header to "application/json"

  Scenario: Mint -> Balance 0 -> Credit -> Balance increases -> Revoke
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
    Then the json at path "$.status" must be "ok"
    Then I store the JSON at path "$.client_pubkey" in "client_pubkey"

    When I make a POST request to "/api/nwc/ledger/balance"
    """
    {"client_pubkey":"{{client_pubkey}}"}
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    Then the json at path "$.balance_sat" must be "0"

    When I make a POST request to "/api/nwc/ledger/credit"
    """
    {
      "client_pubkey":"{{client_pubkey}}",
      "amount_sat": 2000,
      "ref":"bdd-credit-1",
      "meta":"{}"
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    Then the json at path "$.credited_sat" must be "2000"

    When I make a POST request to "/api/nwc/ledger/balance"
    """
    {"client_pubkey":"{{client_pubkey}}"}
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    Then the json at path "$.balance_sat" must be "2000"

    When I make a POST request to "/api/nwc/revoke"
    """
    {"client_pubkey":"{{client_pubkey}}"}
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    Then the json at path "$.revoked" must be "true"
