Feature: Enterprise invoice authentication boundary
  Billing records and PDFs are not available through shared payment credentials.
  Use an isolated staging node with no production billing data.

  Scenario: Missing bearer credentials cannot list invoices
    Given I am using server "http://127.0.0.1:8080"
    Given I set "Authorization" header to ""
    When I make a GET request to "/api/billing/invoices"
    Then the response status must be "401"

  Scenario: A malformed bearer cannot reveal billing session capabilities
    Given I am using server "http://127.0.0.1:8080"
    Given I set "Authorization" header to "Bearer not-a-real-token"
    When I make a GET request to "/api/billing/session"
    Then the response status must be "401"

  Scenario: Shared L402 credentials cannot download an invoice PDF
    Given I am using server "http://127.0.0.1:8080"
    Given I set "Authorization" header to "L402 test-macaroon:test-preimage"
    When I make a GET request to "/api/billing/invoices/test-invoice/pdf"
    Then the response status must be "401"
