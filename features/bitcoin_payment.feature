Feature: Bitcoin payment processing and refunds
  Background:
    Given I have loaded a bitcoin wallet from path "bddtestwallet0"
  Scenario: Make payment from test wallet to newly generated address in target wallet
    Given I have loaded a bitcoin wallet from path "bddtestwallet1"
    Given I create a new receive address "bddtestaddress0"
    When I transfer 0.00000001 BTC from "bddtestwallet0" to "bddtestaddress0"
    And I wait 60 seconds
    Then the balance of "bddtestwallet1" must be greater than 0
    

