Feature: Public-node relay policy (observer mode, no RPC)
  In order to learn a peer's OP_RETURN relay policy
  As a researcher
  I want to broadcast a crafted tx and probe the same peer via P2P

  Background:
    Given a target peer "node.damagebdd.net:8333"

  @tiny
  Scenario: Tiny OP_RETURN likely accepted by permissive nodes
    When I craft an OP_RETURN transaction of 40 bytes
    And I P2P-broadcast the transaction to the target peer
    And I wait 3 seconds
    And I P2P-query getdata for the transaction by txid
    Then the peer response should be "tx" or "unknown"

  @large
  Scenario: Large OP_RETURN likely filtered
    When I craft an OP_RETURN transaction of 4096 bytes
    And I P2P-broadcast the transaction to the target peer
    And I wait 3 seconds
    And I P2P-query getdata for the transaction by txid
    Then the peer response should be "notfound" or "unknown"

  @mid
  Scenario Outline: Threshold probing
    When I craft an OP_RETURN transaction of <bytes> bytes
    And I P2P-broadcast the transaction to the target peer
    And I wait 3 seconds
    And I P2P-query getdata for the transaction by txid
    Then the peer response should be <expected>

    Examples:
      | bytes | expected              |
      |  80   | tx or unknown         |
      |  120  | notfound or unknown   |
      |  512  | notfound or unknown   |
