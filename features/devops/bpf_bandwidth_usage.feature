Feature: Per-process bandwidth via eBPF

  Background:
    Given I am using server "http://127.0.0.1:8080"

  Scenario: nginx is receiving at least 100KB/s
    When I make a POST request to "/proc_bw/start"
    Then the response status must be "200"
    And I wait "2" seconds

    # Replace ${PID} with real PID you want to assert
    When I make a GET request to "/proc_bw/assert?pid=${PID}&min_rx=100000&min_tx=0"
    Then the response status must be "200"
    Then the json at path "$.ok" must be "true"
