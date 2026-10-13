Feature: Scheduled payments to contributors for marketing and promotion
  Background:
    Given I notify "fail" to "discord" webhook
    Given I am using server "https://staging.damagebdd.com"
    And I set the "Set-Macaroon" macaroon header to "{{LND_ADMIN_MACAROON}}"

  Scenario: I want to make a payment using a lightning invoice request for nostr posts 
    Given there is atleast 1 post mentioning npub "16d114303d8203115918ca34a220e925c022c09168175a5ace5e9f3b61640947" in the last 24 hours from npub "2f50e7b4b30616b1f7aca26bd5a4863b23d5a500e028be87a78c42861f626690"
    Then I pay 1000 sats to lightning address "govind@govinda.com"

    Given there is atleast 1 commit from "Govind" to repo "https://github.com/damagebdd/damagebdd.com.git" the last 24 hours
    Then I pay 100 DAMAGE to the damage account "ak_asdadasdasdasd"  once in 24 hours
    Then I pay 1000 sats to lightning address "govind@govinda.com"
