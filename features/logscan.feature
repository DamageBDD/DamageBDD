@logs @demo
Feature: Log scanning and querying
  As a node operator
  I want to tail files and query journald for patterns
  So I can detect errors, confirm healthy behavior, and avoid regressions

  Background:
    # optional context: nothing required

  # -----------------------------
  # File log tailing
  # -----------------------------
  Scenario: Tail file logs incrementally
    When I tail the log file "/var/log/lightningd.log" since last check matching:
      """
      gossip_store: get delete entry offset
      STATUS_FAIL_INTERNAL_ERROR
      """
    Then the logs must NOT contain any line matching:
      """
      STATUS_FAIL_INTERNAL_ERROR
      """
    When I tail the log file "/var/log/lightningd.log" since last check
    Then the logs must contain at least one line matching:
      """
      peer_connected
      """

  # -----------------------------
  # Journald querying with cursor
  # -----------------------------
  Scenario: Query journald for crash signatures
    When I query journald for "SYSLOG_IDENTIFIER=lightningd" over the last 60 minutes matching:
      """
      gossip_store: get delete entry offset
      """
    Then the logs must NOT contain any line matching:
      """
      get delete entry offset
      """
    When I query journald for "UNIT=lightningd.service" over the last 5 minutes matching:
      """
      Connected to peer
      """
    Then the logs must contain at least one line matching:
      """
      Connected to peer
      """

  # -----------------------------
  # Mixed checks
  # -----------------------------
  Scenario: Combined file + journald checks
    When I tail the log file "/var/log/syslog" since last check matching:
      """
      sshd
      """
    Then the logs must contain at least one line matching:
      """
      sshd
      """
    When I query journald for "SYSLOG_IDENTIFIER=sshd" over the last 10 minutes matching:
      """
      Failed password
      """
    Then the logs must NOT contain any line matching:
      """
      Failed password
      """
