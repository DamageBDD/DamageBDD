@verification @lightning @observe @synthetic
Feature: Verify Lightning connectivity and payment policy
  Check the configured node with getinfo, then exercise the same amount-policy
  evaluator used by the NWC wallet with synthetic balances, heights and amounts.
  Enter limits in millisatoshis, with total at least as large as the single limit.
  No invoices are issued and no funds are transferred. These checks do not prove
  real payment settlement, atomic concurrent debit or production-session policy.

  @observe @live
  Scenario: The configured Lightning service is reachable
    When I inspect the configured Lightning node connection
    Then the Lightning node MUST respond with its identity and network

  @synthetic
  Scenario: Payment limits, revocation, expiry and balance are enforced
    When I rehearse the Lightning policy with single limit "{{verification_single_msat}}" and total limit "{{verification_total_msat}}" millisatoshis
    Then the synthetic Lightning policy MUST enforce limits revocation expiry and balance
