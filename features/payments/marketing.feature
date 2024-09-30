Feature: Connect to lightning node, create and pay invoice
  Background:
    Given I am using server "https://staging.damagebdd.com"
    And I set the "Set-Macaroon" macaroon header to "{{LND_ADMIN_MACAROON}}"

  Scenario: I want to make a payment using a lightning invoice request for nostr posts 
    Given there is atleast 1 post mentioning npub "16d114303d8203115918ca34a220e925c022c09168175a5ace5e9f3b61640947" in the last 24 hours from npub "2f50e7b4b30616b1f7aca26bd5a4863b23d5a500e028be87a78c42861f626690"
    Then I pay the invoice with payment request "lightning:LNBC200U1PN059M7PP564GRQJMXPTT627APREW3G5WMSZGX6Y39MGWY3Z8VF2JFA64QCRRQDQQCQZRCXQ9ZF7QDSP5ZK8PJ7NJ9R8RXNYXMFD98AWL7Y5N6ZC2C39U99JVAS5WV2FSEJXS9QXPQYSGQDURLAHY36WZWWA8LY3TCPSZA57XD240GCNTS0SX7T8U52KK8EEGNPYNAWC5SMWCYGDT0WYXQJP3NMA2DA40H63R445WA9FCCJDY9E5QPRJTHU5"
