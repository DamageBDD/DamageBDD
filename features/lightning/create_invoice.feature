Feature: Connect to lightning wallet and generate invoice
  Background:
    Given I have a lightning node on "localhost" port 8011
    And I set the "Set-Macaroon" meacaroon header to "/var/lib/lnd/invoice.macaroon"
  Scenario: I want to generate an invoice for a user on a basic plan
    When I make a POST request to "/accounts/invoice"
    """
    {
      "id": ""
    }
    """
