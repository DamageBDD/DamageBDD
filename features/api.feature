Feature: Test DamageBDD API
  Scenario: Post feature data
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/api/execute_feature/"
    """
    {
        "feature": "Feature: For testing an echo server running on localhost\n   Scenario: root\n        When I make a GET request to \"/\"\n        Then the response status must be \"200\"\n        When I make a POST request to \"/echo/read_body\"\n        \"\"\"        {\"status\" : \"ok\"}\n        \"\"\"\n        Then the json at path \"$.status\" must be \"ok\"",
        "account": "guest"
    }
     
    """
    Then the json at path "$.status" must be "ok"
