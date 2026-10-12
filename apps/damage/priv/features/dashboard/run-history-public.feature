Feature: Public run history is indexed by æternity and IPFS
  Public run history does not require a DamageBDD history or registry API.

  Scenario: The DAMAGE token has a public contract call history
    Given I am using server "https://mainnet.aeternity.io/mdw"
    When I make a GET request to "/v3/contracts/calls?contract_id=ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk&limit=10"
    Then the response status must be "200"

  Scenario: The node registry's historical calls are public
    Given I am using server "https://mainnet.aeternity.io/mdw"
    When I make a GET request to "/v3/contracts/calls?contract_id=ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ&limit=10"
    Then the response status must be "200"
