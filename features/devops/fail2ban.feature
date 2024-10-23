Feature: Automatically ban IP addresses making bad requests to the Nginx server
  As a system administrator
  I want to automatically detect and ban IP addresses that make repeated bad requests to the Nginx server
  So that I can protect the server from malicious or erroneous traffic

  Background:
    Given that status of service "nginx" is "active"
    And I am monitoring "nginx" journal
    And I set the IP exclusion list to
    """
    192.168.1.1,127.0.0.1
    """


  Scenario: Ban an IP address after multiple 404 requests
    When the IP has made more than "10" requests with status "404" in the last "60" seconds
    Then the IP must be banned for "90" seconds

