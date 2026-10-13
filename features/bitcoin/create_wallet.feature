Feature: Create bitcoin wallet and display the wallet seed
  Background:
    Given I have created a bitcoin wallet at path "bddtestwallet0"
  Scenario: display the wallet seed
    Then I print the variable "bitcoin_wallet"
