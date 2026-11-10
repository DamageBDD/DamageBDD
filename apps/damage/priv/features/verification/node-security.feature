@verification @security @node @observe @linux
Feature: Verify this node's security baseline
  Inspect the Linux node executing this feature, not a user-supplied remote host.
  Check process privileges, private secret-file permissions, crash-dump settings,
  credential transport, live TCP listeners, secure-cookie configuration and
  disabled automatic code reload. Collect every finding before deciding the result.
  This strict local-production baseline expects a same-host reverse proxy:
  all TCP listeners owned by this BEAM, and the configured EPMD port, must be
  loopback-only. Public TLS listeners and remote clusters need a different policy.
  Requires node administrator authority. No secrets are decrypted or printed.
  No shell commands, network probes, payments, configuration changes or restarts.
  Only the redacted report and normal DamageBDD execution artifacts are written.
  Missing evidence fails the check. A pass is a local point-in-time observation,
  not proof of host integrity, firewall enforcement, TLS edge security, absence
  of vulnerabilities, complete secret discovery or cloud-account permissions.

  Scenario: All required local-production controls have fresh passing evidence
    Then the running node MUST pass the local production security baseline
