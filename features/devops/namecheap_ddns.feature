Feature: Namecheap ddns configuration
  Scenario: Auto detect ip and set
    Given I configure Namecheap DDNS for domain example.com host @
    When I update Namecheap DDNS with detected IP
    Then the Namecheap DDNS update should succeed

  Scenario: Manually set ip
    Given I configure Namecheap DDNS for domain example.com host home
    Given I set Namecheap DDNS secret key to namecheap_ddns_password
    When I update Namecheap DDNS with IP 203.0.113.42
    Then the Namecheap DDNS update should succeed
    Then the Namecheap response IP must be 203.0.113.42
