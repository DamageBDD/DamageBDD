Feature: monitor bitcoin wallet or wallets or utxos
  Background:
    Given I notify "activity" to "discord" webhook

Scenario: monitor a bitcoin wallet
    Given I have a bitcoin wallet "btc"
    Then I monitor for "activity" on "btc"

Scenario: monitor multiple bitcoin wallets
    Given I have a bitcoin wallets
    """
    btc1
    2
    """
    Then I monitor for "activity" on "btc"

Scenario: monitor utxos from wallet
    Given I have a bitcoin wallet "btc"
    Then I monitor for "activity" on "btc"