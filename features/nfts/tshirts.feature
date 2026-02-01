Feature: Mint T-Shirt order-slot NFTs to the executor and list them for customers to buy

  # Non-technical explanation:
  # - The executor mints a limited number of "order-slot" NFTs (inventory).
  # - Each NFT represents an entitlement to one printed t-shirt of a given style/options.
  # - Customers later purchase one listed NFT.
  # - A successful purchase triggers imminent print fulfillment for that NFT.

  Scenario: Mint a small batch of "DamageBDD T-Shirt" order-slot NFTs and publish them for sale
    # Create a batch identifier (useful for filtering listings)
    Given I store an uuid in "batch_id"
    Given I store current time string in "minted_at" with format "%Y-%m-%dT%H:%M:%S%z"

    # Define the product template (these values show on the storefront listing)
    Given I set the variable "product" to "DamageBDD T-Shirt"
    Given I set the variable "sku" to "TSHIRT-DAMAGEBDD-BLACK"
    Given I set the variable "size" to "L"
    Given I set the variable "color" to "Black"
    Given I set the variable "price_sats" to "50000"
    Given I set the variable "quantity_to_mint" to "10"

    # Mint inventory NFTs to the BDD executor (the node wallet).
    # The node automatically:
    # - stores the metadata in IPFS
    # - mints NFTs to itself (inventory)
    # - lists them for customers to buy
    When I mint "{{quantity_to_mint}}" Knowledge NFTs to the executor with this product metadata
    """
    {
      "type": "damagebdd.product.order_slot",
      "version": 1,

      "batch_id": "{{batch_id}}",
      "minted_at": "{{minted_at}}",

      "product": {
        "name": "{{product}}",
        "sku": "{{sku}}",
        "options": {
          "size": "{{size}}",
          "color": "{{color}}"
        }
      },

      "commercial": {
        "price_sats": "{{price_sats}}",
        "currency": "sats",
        "inventory_kind": "executor_minted"
      },

      "semantics": {
        "ownership_is_entitlement_to_print": true,
        "purchase_triggers_imminent_print": true
      },

      "fulfillment": {
        "print_status": "ready_to_queue_after_purchase",
        "queue_reason": "customer_purchase"
      }
    }
    """

    # Store the mint result (for UI / audit logs)
    Then I store the Knowledge NFT mint result in "mint_receipt"

    # Simple sanity checks for non-technical users:
    Then the response must contain text "ok"
    Then the response must contain text "{{batch_id}}"
    Then the response must contain text "{{sku}}"

    # Verify storefront has the listings available for customers.
    # This assumes your node exposes a public listing endpoint.
    When I make a GET request to "/api/store/listings?sku={{sku}}&batch_id={{batch_id}}"
    Then the response status must be "200"
    Then the response must contain text "{{sku}}"
    Then the response must contain text "available"

    # Optional: show output in the run report
    Then I print the response:

