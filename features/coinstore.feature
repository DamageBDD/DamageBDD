Feature: Coinstore spot API
  Background:
    Given I use Coinstore API
    And I use Coinstore credentials from API key secret "coinstore_api_key" and secret key secret "coinstore_secret_key"

  Scenario: Read spot balances
    When I get my Coinstore spot balances
    Then the Coinstore response should succeed

  Scenario: Read current BTCUSDT orders
    When I get my Coinstore current orders with query "symbol=BTCUSDT"
    Then the Coinstore response should succeed

  Scenario: Read public market depth
    When I get Coinstore market depth for "BTCUSDT" with depth "20"
    Then the Coinstore response should succeed

  Scenario: Place a limit order explicitly
    Given I allow Coinstore trading
    When I create a Coinstore order
      """
      {"symbol":"BTCUSDT","side":"BUY","ordType":"LIMIT","ordPrice":"30000","ordQty":"1"}
      """
    Then the Coinstore response should succeed

  Scenario: Use a raw signed endpoint without re-encoding the query
    When I make a signed Coinstore GET request to "/trade/order/orderInfo" with query "ordId=1780715084580128"
    Then the Coinstore response should succeed
