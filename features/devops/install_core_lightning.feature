Feature: Secure installation of Core Lightning from a GitHub release
  In order to run Core Lightning safely on this node
  As an operator
  I want a scripted, hash-verified install from an official GitHub release artifact

  Background:
    # Identify the executing node in DamageBDD context (no-op but consistent)
    Given I am the node named "wallet"

    # Work in a scratch directory
    And I change directory to "/tmp"

  # This expects /usr/local/bin/install-core-lightning to exist and be executable.
  # It MUST verify the SHA256 hash, install binaries under /opt/core-lightning,
  # create a restricted "cln" system user, and (optionally) wire up systemd.
  Scenario Outline: Install Core Lightning from a verified GitHub release artifact
    When I run the command "/usr/local/bin/install-core-lightning \"<ReleaseUrl>\" \"<Sha256>\""
    Then the exit status must be "0"

    # Sanity check that the binary is on PATH and executable
    When I run the command "lightningd --version"
    Then the exit status must be "0"

    # Optional: verify the systemd service is active if the installer creates it
    When I run the command "systemctl is-active --quiet lightningd"
    Then the exit status must be "0"

    Examples:
      | ReleaseUrl                                                                                       | Sha256                                      |
      | https://github.com/ElementsProject/lightning/releases/download/v24.08.1/clightning-v24.08.1.tar.xz | 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef |
