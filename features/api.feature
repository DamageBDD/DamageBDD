Feature: Test DamageBDD API
  Scenario: Post feature data
    Given I am using server "http://localhost:8080"
    When I make a GET request to "/execute_feature/"
    Then the response status must be "200"
    When I make a POST request to "/execute_feature/"
    """
    {
        "feature": "Feature: For testing an request to google\n  Scenario: root\n    When I make a GET request to \"/\"\n    Then the response status must be \"200\"\n",
        "account": "guest",
        "host": "damagebdd.com",
        "port": 443
    }
     
    """
    Then the json at path "$.status" must be "ok"

