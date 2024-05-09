Feature: Ensure availability of damagebdd system services
  Scenario: ensure riak servers are available

    Given I am using server "http://threadripper0.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"

    Given I am using server "http://doombox.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"

    Given I am using server "http://zenbook.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"

  Scenario: ensure IPFS servers are available
    Given I am using server "http://threadripper0.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"

    Given I am using server "http://doombox.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"

    Given I am using server "http://zenbook.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"

    Given I am using server "http://yoga0.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"

  Scenario: ensure smtp sending hosts are up
    Given I am using server "https://status.sendgrid.com"
    When I make a GET request to "//api/v2/status.json"
    Then the response status must be "200"

  Scenario: ensure lightning node is running 
    # Currently no way to check if lightning rpc is ready without a macaroon
    Given I am using server "http://threadripper0.lan:8011"
    When I make a GET request to "/status"
    Then the response status must be "400"

  Scenario: ensure Aeternity nodes are available
    Given I am using server "http://threadripper0.lan:3013"
    When I make a GET request to "/v3/status"
    Then the response status must be "200"
    Then the json at path "$.syncing" must be "false"

  Scenario: ensure zx is able to resolve packages
    Given I change directory to "/home/steven/devel/aeternity/Vanillae/bindings/erlang"
    When I run the command "zx list deps"
    Then the exit status must be "0"

  Scenario: ensure LLM nodes are available
    Given I am using server "http://threadripper0.lan:11434"
    When I make a POST request to "/api/generate"
    """
    {
        "model": "mistral",
        "prompt":"Here is a haiku about llamas eating grass",
        "stream": false
    }
    """
    Then the response status must be "200"
    Then I print the response body
    Then I print the json at path "$.response"
    Then the json at path "$.done" must be "true"
