@verification @security @synthetic
Feature: Rehearse credential-leak containment
  Exercise the deployed browser-session revocation and wallet privilege policy
  against isolated synthetic state. A positive control must work before it is
  revoked, and an unrelated session must continue to work afterwards.
  No real credential is created, disclosed, revoked or scanned for leaks.
  Release-transfer routing is checked at the wallet-policy boundary only:
  this is not proof of CI publishing isolation or of live HTTP endpoint enforcement.

  Scenario: A copied session stops authenticating after revocation
    When I rehearse an isolated browser session revocation
    Then the synthetic session MUST work before revocation and fail afterwards

  Scenario: Wallet identity cannot turn into administrative authority
    When I inspect the wallet session privilege boundary
    Then wallet sessions MUST NOT gain execution signing or release transfer authority
