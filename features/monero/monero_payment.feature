@monero @local
Feature: Monero payments through a local wallet RPC

  Background:
    Given the local Monero wallet RPC is available

  Scenario: Create a unique subaddress invoice
    Given I create a Monero invoice for "0.001" XMR in "invoice"
    Then I print variable "invoice"
    Then the Monero invoice in "invoice" should not be paid

  @requires_manual_payment
  Scenario: Verify a paid invoice after ten confirmations
    Given I create a Monero invoice for "0.001" XMR in "invoice"
    Then I print variable "invoice"
    Then I wait for the Monero invoice in "invoice" to be paid with "10" confirmations for up to "3600" seconds
    Then I print variable "invoice_status"

  Scenario: Read wallet balance
    Then I store the Monero wallet balance in "monero_balance"
    Then I print variable "monero_balance"
