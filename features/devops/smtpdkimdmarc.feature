Feature: Setup DKIM and DMARC on Arch Linux
  As a system administrator
  I want to configure DKIM and DMARC on an Arch Linux server
  So that I can securely receive emails using a custom SMTP server

  Scenario: Install and configure OpenDKIM
    Given I have an Arch Linux server
    When I install package "opendkim"
    Then OpenDKIM should be installed successfully

    When I create and edit "/etc/opendkim/opendkim.conf"
    Then I should add the necessary configuration settings:
      | Key                   | Value                                                     |
      | Syslog                | yes                                                       |
      | UMask                 | 002                                                       |
      | Domain                | example.com                                               |
      | KeyFile               | /etc/opendkim/keys/example.com/default.private            |
      | Selector              | default                                                   |
      | Socket                | inet:8891@localhost                                       |
      | Mode                  | s                                                         |
      | Canonicalization      | relaxed/simple                                            |
      | SubDomains            | no                                                        |
      | AutoRestart           | yes                                                       |
      | AutoRestartRate       | 10/1M                                                     |
      | Background            | yes                                                       |
      | PIDFile               | /run/opendkim/opendkim.pid                                |
      | UserID                | opendkim:opendkim                                         |
      | KeyTable              | /etc/opendkim/key.table                                   |
      | SigningTable          | /etc/opendkim/signing.table                               |
      | TrustedHosts          | /etc/opendkim/trusted.hosts                               |

    When I create "key.table" and add "default._domainkey.example.com example.com:default:/etc/opendkim/keys/example.com/default.private"
    And I create "signing.table" and add "*@example.com default._domainkey.example.com"
    And I create "trusted.hosts" and add:
      | Host                 |
      | 127.0.0.1            |
      | localhost            |
      | *.example.com        |
    Then the key tables and trusted hosts should be configured
