@verification @security @live @active
Feature: Verify Nostr bunker health and signing
  Inspect the deployed AWS-hosted signer, expected identity, secret provenance,
  file permissions and relay readiness. Then request fixed diagnostic signatures
  and verify their signatures, denials and audit correlation through the existing
  bunker controller. Uses the configured node and approved diagnostic client.
  No keys are shown, no clients are added, and no identities or secrets are rotated.
  This is not a Bitcoin custody, reserves or complete IAM-permissions audit.

  @observe
  Scenario: The deployed signer is ready and uses the expected custody controls
    When I inspect the deployed AWS bunker health
    Then the deployed AWS bunker health checks MUST pass

  @active
  Scenario: Approved signatures and prohibited requests have verifiable outcomes
    When I verify signing through the approved bunker relays
    Then the bunker signatures and policy denials MUST be verified
