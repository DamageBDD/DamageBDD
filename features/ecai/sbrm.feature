Feature: ECAI SBRM index from financial JSONL on IPFS

  Scenario: Build an index from an IPFS JSONL CID and query it
    Given I store "bafy..." in "financial_jsonl_cid"
    Given I create a new ECAI SBRM index and store it in "idx"
    Given I set the default ECAI SBRM index to the value in "idx"

    When I ingest the JSONL file from IPFS hash in "financial_jsonl_cid" into the default ECAI SBRM index
    Then I store the last ECAI SBRM ingest result in "ingest_summary"

    When I query the default ECAI SBRM index for "mini:CashAndCashEquivalents" and store the results in "results"
