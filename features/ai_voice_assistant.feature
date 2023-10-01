Feature: My well behaved ai assistant
  Background: 
    Given I am using ai "api.openai.com"
    And I set the messages context
    """
    AI voice assistant server that performs voice to text and provides assistance 
The server must use local gpu to perform the computation
    """

  Scenario: Upload audio for voice to text
    Given I am using server "http://localhost:8080"
    And I set base URL to "/"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/api/upload" with a file attachment "/var/lib/damage/guest/lastmessage.ogg"
    Then the response should be "201"
    Then the json at path "$.id" must be "guest_voice_ai_req_0"
    When I make a GET request to "/api/tasks/?id=guest_voice_ai_req_0"
    Then the response status must be "200"
    Then the json at path "$.id" must be "guest_voice_ai_req_0"
    Then the json at path "$.result" must be "hello world"
