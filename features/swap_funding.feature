Feature: Fund contractor work via Lightning swaps

  Background:
    Given I use GitHub repo "damagebdd/damagebdd"
    And I track issue "#42"
    And I set the variable "swap_channel_id" to "ch_abcd123"
    And I set the variable "funder_ae_account" to "ak_fundertest123"
    And I set the variable "lock_sats" to "20000"
    And I set the variable "payout_damage" to "500"
    And I set the variable "expiry_seconds" to "86400"

  Scenario: Funder pays invoice and receives DAMAGE
    When I fund the tracked issue with a Lightning swap option
    Then the Lightning swap option should be open for the tracked issue
    # user pays the invoice externally or via mock
    Then the Lightning invoice should be paid
    And the funder should receive DAMAGE rewards
    And the contractor should be paid for the tracked issue
