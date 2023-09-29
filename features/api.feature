Feature: Test DamageBDD API
  Scenario: Post feature data
    When I make a GET request to "/api/execute_feature/"
    Then the response status must be "200"
    When I make a POST request to "/api/execute_feature/"
    """
    {
        "feature": "Feature: For testing an request to google\n  Scenario: root\n    When I make a GET request to \"/\"\n    Then the response status must be \"200\"\n",
        "account": "guest",
        "host": "damagebdd.com",
        "port": 443
    }
     
    """
    Then the json at path "$.status" must be "ok"
