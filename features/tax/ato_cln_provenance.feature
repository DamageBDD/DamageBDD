Feature: Australian tax evidence from settled Lightning payments
  Cryptocurrency receipts are recorded in millisatoshis, and tax treatment
  must remain under review until a qualified reviewer classifies them.

  Scenario: Only settled invoices become unclassified tax evidence
    Given a settled CLN invoice of "100000000000" millisatoshis at Unix time "1759320010"
    When I normalise the settled invoice as tax evidence
    Then the tax event must require manual classification
    And the tax event amount must be "100000000000" millisatoshis
    And the tax event must have source provenance
