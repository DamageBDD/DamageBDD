Feature: Connect to lightning node, create a hold invoice pay funds and release it

  Background:
    Given I am using server "https://staging.damagebdd.com"

  Scenario: I want to make a hold invoice for a test case
    When I create a holdinvoice with params
    """
    {
        "label": "JIRA-94",
        "description": "some annoying bug",
        "amount_msats": 100000,
        "cltv": 144,
        "executor": "ak_2eu6yAH46eu9T88WN7MDnyr1QzW6GLWAc667Z93U44wLewuhLN"
    }
    """
    Then I store the json path at "$.bolt11" in variable "PaymentHash"
    Then I display the qrcode for "PaymentHash"
    Then I wait for funds in escrow "PaymentHash"
    # assuming QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF is the hash for the test 
    When the status of test case "QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF" changes to "success"
    Then the funds in escrow "PaymentHash" are released
