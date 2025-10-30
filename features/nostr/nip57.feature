Feature: Testing lnurlpay nip57

  Background:
    Given I am using server "https://asyncmind.xyz"

  Scenario: I want to make a payment to an lnaddress when tests pass
    When I make a GET request to "/.well-known/lnurlp/asyncmind"
    Then the response status must be "200"

#### Appendix C: LNURL Server Configuration
#
#The lnurl server will need some additional pieces of information so that clients can know that zap invoices are supported:
#
#1. Add a `nostrPubkey` to the lnurl-pay static endpoint `/.well-known/lnurlp/<user>`, where `nostrPubkey` is the nostr pubkey your server will use to sign `zap receipt` events. Clients will use this to validate `zap receipt`s.
#2. Add an `allowsNostr` field and set it to true.

    Then the json at path "$.allowsNostr" must be "true"
    Then the json at path "$.nostrPubkey" must be "npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc"
    Then the json at path "$.tag" must be "payRequest"
    Then I store the JSON at path "$.callback" in "lnserviceurl"
    When I make a POST request to "{{lnserviceurl}}"
    """
    {
      "memo": "funding prod",
      "amount": 10,
      "expiry": 3600
    }
    """
    Then the response status must be "201"
    Then I print the response
    Then the json at path "$.tag" must be "payRequest"
    Then I store the JSON at path "$.payment_request" in "payment_request"
    Then I pay the invoice with payment request "payment_request"

#### Appendix D: LNURL Server Zap Request Validation
#
#When a client sends a `zap request` event to a server's lnurl-pay callback URL, there will be a `nostr` query parameter whose value is that event which is URI- and JSON-encoded. If present, the `zap request` event must be validated in the following ways:
#
#1. It MUST have a valid nostr signature
#2. It MUST have tags
#3. It MUST have only one `p` tag
#4. It MUST have 0 or 1 `e` tags
#5. There should be a `relays` tag with the relays to send the `zap receipt` to.
#6. If there is an `amount` tag, it MUST be equal to the `amount` query parameter.
#7. If there is an `a` tag, it MUST be a valid event coordinate
#8. There MUST be 0 or 1 `P` tags. If there is one, it MUST be equal to the `zap receipt`'s `pubkey`.

  Scenario: LNURL Server Zap Request Validation
    Given I create and store a nostr event as "NOSTR_ZAP" 
    """
    {
        kind: 9734,
        content: "awesome post!",
        pubkey: "npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc",
        created_at: {{timestamp}},
        tags: [
            ["relays", ...relays],
            ["amount", 100],
            ["lnurl", lnurl],
            ["p", recipientPubkey],
        ],
    }
    """
    When I make a POST request to "/zap"
    """
    {{{NOSTR_ZAP}}}
    """
    Then the response status must be "200"
