Feature: Testing lnurlpay

  Background:
    Given I am using server "https://asyncmind.xyz"

  Scenario: I want to make a payment to an lnaddress when tests pass
    Given test case "QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF" status was "success" in the last "24" hours
    When I make a GET request to "/.well-known/lnurlp/asyncmind"
    Then the response status must be "200"
    Then the json at path "$.tag" must be "payRequest"
    Then I store the JSON at path "$.callback" in "lnserviceurl"
    When I make a POST request to "{{lnserviceurl}}"
    """
    {
      "memo": "funding prod",
      "amount": 10,
      "expiry": 3600
    }
    """
    Then the response status must be "201"
    Then I store the JSON at path "$.payment_request" in "payment_request"
    Then I pay the invoice with payment request "payment_request"
