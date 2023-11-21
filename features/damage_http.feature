Feature: Http test feature
  Scenario: Test post yaml
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/x-yaml"
    When I make a POST request to "/tests/"
    """
refund_address: "mohjSavDdQYHRYXcS3uS6ttaHP8amyvX78"
customer_type: "Individual"
full_name: "John Doe"
date_of_birth: "1980-01-01"
address: "123 Main Street, Sydney, NSW"
identification_verification:
  document_type: "Passport"
  document_number: "A1234567"
email: "john.doe@damagebdd.com"
phone: "0412345678"
    """
    Then the response status must be "201"
    Then the yaml at path "$.email" must be "john.doe@damagebdd.com"

  Scenario: Test post json
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/tests/"
    """
    {
        "refund_address": "mohjSavDdQYHRYXcS3uS6ttaHP8amyvX78",
        "customer_type": "Individual",
        "full_name": "John Doe",
        "date_of_birth": "1980-01-01",
        "address": "123 Main Street, Sydney, NSW",
        "identification_verification": {
            "document_type": "Passport",
            "document_number": "A1234567"
        },
        "email": "john.doe@damagebdd.com",
        "phone": "0412345678"
    }
    """
    Then the response status must be "201"
    Then the json at path "$.email" must be "john.doe@damagebdd.com"
