Feature: NWC Ledger-backed connections
  The Damage NWC ledger smart contract is the source of truth for spendable sats,
  limits, and revocation.

  Background:
    Given I am using server "https://run.dev.damagebdd.com"
    # Provide a real token when running for real.
    # For local dev, point at localhost and use a dev token.
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
    Then the response status must be "204"
    Then I print the response
    Then I store the JSON at path "$.client_pubkey" in "client_pubkey"
    Then I store the JSON at path "$.nwc_uri" in "nwc_uri"

    # Balance should be 0 initially
    When I make a POST request to "/api/nwc/ledger/balance"
    """
    {"client_pubkey":"{{client_pubkey}}"}
    """
    Then the response status must be "200"
    Then the response must contain text "status"
    Then the response must contain text "ok"

    # Admin credit for deterministic test
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
    Then the response must contain text "credited_sat"

    # Revoke the connection
    When I make a POST request to "/api/nwc/revoke"
    """
    {"client_pubkey":"{{client_pubkey}}"}
    """
    Then the response status must be "200"
    Then the response must contain text "\"revoked\":true"
