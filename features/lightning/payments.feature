Feature: Connect to lightning node, create and pay invoice

  Background:
    Given I am using server "https://damagebdd.com"

  Scenario: I want to make a payment to an lnaddress when tests pass
    Given test case "QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF" status was "success" in the last "24" hours  
    When I make a GET request to "/.well-known/lnurlp/asyncmind"
    Then the response status must be "200"
    Then the json at path "$.tag" must be "payRequest"
    Then I store the JSON at path "$.callback" in "lnserviceurl"
    Given I am using server "http://localhost:8011"
    When I make a POST request to "{{lnserviceurl}}"
    """
    {
      "memo": "funding prod",
      "amount": 10,
      "expiry": 3600
    }
    """
    Then the response status must be "201"
    Then the json at path "$.memo" must be "thanks for the fish"
    Then I store the JSON at path "$.payment_request" in "payment_request"
    Then I pay the invoice with payment request "payment_request"

  Scenario: I want to make a payment using a lightning invoice request
    Given test case "QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF" status was "success" in the last 24 hours  
    Then I pay the invoice with payment request "lightning:lnbc100u1pn05rmypp5s2xmyvajk7areg87lvnlmtpl0jy8d9hnhsq8gda4l5a775cq0y6qdqqcqzzsxqyz5vqsp500uqnhr2k5mshx6v9eehnlem438e3nk2rshy5gx3ga3l3chzf55s9qxpqysgq8znkrnsa7lh0phvxt20nknmeqzvdmx7pu465psf90jgh7rshrztsme7p8jf9eas8n368jmlrzz2dyl3mrvs6qp9q4nqud4v56r5df4qp4my6jf"

  Scenario: I want to make a payment using a lightning invoice request
    Given test case "QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF" status was "success" in the last 24 hours  
    Then I pay 1000 sats to the invoice with payment request "lightning:lnbc100u1pn05rmypp5s2xmyvajk7areg87lvnlmtpl0jy8d9hnhsq8gda4l5a775cq0y6qdqqcqzzsxqyz5vqsp500uqnhr2k5mshx6v9eehnlem438e3nk2rshy5gx3ga3l3chzf55s9qxpqysgq8znkrnsa7lh0phvxt20nknmeqzvdmx7pu465psf90jgh7rshrztsme7p8jf9eas8n368jmlrzz2dyl3mrvs6qp9q4nqud4v56r5df4qp4my6jf"

