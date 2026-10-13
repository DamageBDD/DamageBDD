Feature: Harden Bitcoin Core v30 relay policy and sanitize OP_RETURN payloads
  In order to prevent hostile OP_RETURN payloads from entering my mempool
  As a node operator
  I want Core v30 to behave like a hardened/Knots-style policy and my indexer to redact payload bytes

  #
  # Connection & auth for JSON-RPC via steps_http (Gun)
  #
  Background:
    Given I set base URL to http://127.0.0.1:18443
    And I set BasicAuth username to user and password to pass

  @strict
  Scenario Outline: Strict profile blocks OP_RETURN relay of any size
    Given I (re)start bitcoind with profile strict
    When I craft an OP_RETURN transaction of <bytes> bytes
    And I call testmempoolaccept on the crafted transaction
    Then mempool admission should be rejected

    Examples:
      | bytes |
      | 40    |
      | 90    |
      | 4096  |

  @legacy
  Scenario Outline: Legacy profile admits tiny carrier but rejects larger ones
    Given I (re)start bitcoind with profile legacy
    When I craft an OP_RETURN transaction of <bytes> bytes
    And I call testmempoolaccept on the crafted transaction
    Then mempool admission should be <expected>

    Examples:
      | bytes | expected |
      | 40    | accepted |
      | 90    | rejected |
      | 4096  | rejected |

  @storage
  Scenario: Storage/serving risk reduction checks
    Given I (re)start bitcoind with profile strict
    Then prune must be enabled with target at least 5 GB
    And txindex must be disabled
    And blocksonly may be enabled

  @sanitizer
  Scenario: Explorer/indexer sanitizer redacts OP_RETURN payloads
    Given a raw OP_RETURN hex payload "4b59435f444f5845582e2e2e"   # "KYC_DOXEX..."
    When the sanitizer processes the payload
    Then the rendered output must NOT contain the raw payload
    And the rendered output must contain "[redacted-op_return]"
