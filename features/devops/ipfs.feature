Feature: Ipfs module tests

  Background:

    Given I am using IPFS API at "http://127.0.0.1:5001"
    And I am using IPFS gateway "http://127.0.0.1:8082"
    #And I am using IPFS gateway "https://ipfs.io"

  Scenario: Verify a CID is healthy
    Given I set the variable "CID" to "QmdF4hVR9nmJjxkqfr3YpD3Bre2xw9yg1ApnLDk1GLxfQf"
    Given a CID "{{CID}}"
    When I call IPFS "block/stat" for the CID
    Then the response status must be 200
    And the json int at path "$.Size" must be >= 1
  
    When I call IPFS "pin/ls" for the CID with type "all"
    Then the response status must be 200
    And the json at path "$.Keys.{{CID}}.Type" must be one of "recursive,direct,indirect"
  
    When I GET "/ipfs/{{CID}}" from the gateway with Range "bytes=0-63"
    Then the response status must be one of "200,206"
    When I add the path "./" to IPFS and store the hash in "asset_hash"
    Then I print "{{asset_hash}}"

  Scenario: add a path
    When I add the path "run.meta" to IPFS and store the hash in "asset_hash"
    Then I print "{{asset_hash}}"
