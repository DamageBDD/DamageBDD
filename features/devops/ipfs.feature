Background:
  Given I am using IPFS API at "http://127.0.0.1:5001"
  And I am using IPFS gateway "https://cloudflare-ipfs.com"

Scenario: Verify a CID is healthy
  Given a CID "QmYourCidHere"
  When I call IPFS "block/stat" for the CID
  Then the response status must be 200
  And the json int at path "$.Size" must be >= 1

  When I call IPFS "pin/ls" for the CID with type "all"
  Then the response status must be 200
  And the json at path "$.Keys.QmYourCidHere.Type" must be one of "recursive,direct,indirect"

  When I GET "/ipfs/<cid>" from the gateway with Range "bytes=0-63"
  Then the response status must be 200 or 206
