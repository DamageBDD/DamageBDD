Feature: Automatically ban IP addresses making bad requests to the Postfix server
  As a system administrator
  I want to automatically detect and ban IP addresses that make repeated bad requests to the Nginx server
  So that I can protect the server from malicious or erroneous traffic

  Background:
    Given that status of service "postfix" is "active"
    And I am monitoring "postfix" journal
    And I set the IP exclusion list to
    """
    192.168.1.1,127.0.0.1
    """


  Scenario: Ban an IP address after multiple 404 requests
    When the IP has made more than "5" failed SASL auth requests in the last "600" seconds
    Then the IP must be banned for "900" seconds

