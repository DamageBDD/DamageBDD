# ECAI Personality NFT operator setup

The personality store is an off-chain Lightning checkout connected to an
Aeternity AEX-141 NFT. **This is a trusted-minter system, not a trustless
Lightning-to-Aeternity bridge.** The application verifies CLN settlement before
calling `mint_paid`. The contract records the payment hash, not a payment preimage,
and cannot independently prove that a Lightning payment settled.

## Prerequisites

Use the complete DamageBDD release, including `damage_ae`, `secrets`, and
`aeser_api_encoder`, plus the configured Aeternity node and Sophia compiler used by
existing `ecai_nft` / `ecai_pqc_nft` deployments. Keep the signer in the established
`secrets:node_keypair()` provider. Never put a private key in the personality
configuration, order store, public manifest, or browser.

Keep live sales disabled until deployment, collection registration, chain reads,
and a testnet purchase have passed. The uploaded ECAI-only source archive does
not contain the external `damage_ae` implementation or a chain runtime. The
adapter uses `damage_ae:contract_call_dry/5` at the node's current top and decodes
its `return_type`/`return_value` map and native FATE option/tuple/byte values.
It does not use `contract_query/5`, because that function can fall back to sending
an on-chain transaction. Unknown response formats fail closed.

## Deploy and register

In the running Erlang release shell:

```erlang
%% Creates the contract using the existing damage_ae deployment implementation.
%% init(name, symbol, minter) uses the node public key as trusted minter.
ecai_personality_nft:deploy().
```

Take the `ct_...` address from the mined deployment result. Set the contract in
`sys.config` (or set it temporarily with `application:set_env/3`):

```erlang
{ecai, [
    {personality_nft, #{
        enabled => false,
        contract_id => <<"ct_REPLACE_WITH_DEPLOYED_CONTRACT">>,
        network_id => <<"ae_mainnet">>, %% use <<"ae_uat">> on public testnet
        confirmations => 3
    }}
]}.
```

The deployment administrator must register every sellable package. `Product` is
the exact server-side catalog record, including its real 64-hex-digit package
SHA-256, permanent manifest URI, edition limit, and positive price in sats:

```erlang
%% personality_catalog must already contain the final public manifest URI.
{ok, Product} = ecai_personality_catalog:get(<<"builder">>),
ecai_personality_nft:register_product(Product).
```

`register_product/1` returns `{pending, Map}` after submitting. It deliberately
does not claim successful registration on submission. Once mined, enable the
adapter and verify each catalog product:

```erlang
application:set_env(ecai, personality_nft, #{
    enabled => true,
    contract_id => <<"ct_REPLACE_WITH_DEPLOYED_CONTRACT">>,
    network_id => <<"ae_mainnet">>,
    confirmations => 3
}),
ecai_personality_nft:ready(Product).
%% Must return ok before checkout creates an invoice.
```

`ready/1` verifies the contract protocol, real signer/minter match, exact registered
package hash/URI/cap, and remaining on-chain supply. Unregistered, mismatched,
sold-out, disabled, unavailable, or incorrectly configured contracts fail closed.
Registration is immutable. A new package hash creates a new collection key;
changing an existing collection's URI or cap is rejected. Product price is an
off-chain offer; the immutable receipt records the paid order amount.

## Contract API

| Entrypoint | Arguments | Result / authorization |
|---|---|---|
| `init` | `name: string, symbol: string, minter: address` | Deployer becomes administrator |
| `protocol_version` | none | `"ecai-personality-nft/1"` |
| `minter` / `admin` | none | Current minter / immutable administrator |
| `set_minter` | `next: address` | Administrator only |
| `register_collection` | `key: bytes(32), package_hash: bytes(32), manifest_uri: string, edition_limit: int` | Administrator only; identical retry allowed |
| `collection_info` | `key: bytes(32)` | `option(hash * uri * cap * issued)` |
| `mint_paid` | `order_key: bytes(32), collection_key: bytes(32), to: address, payment_hash: bytes(32), price_sats: int, data: option(string)` | Minter only; returns token ID |
| `receipt_for_order` | `order_key: bytes(32)` | `option(token_id * collection_key * recipient * package_hash * manifest_uri * cap * payment_hash * price_sats * minted_height * current_height)` |
| `order_for_payment` | `payment_hash: bytes(32)` | `option(order_key)` |
| `metadata` | `token_id: int` | `option(MetadataIdentifier(manifest_uri))` |
| `owner` / `balance` | `token_id: int` / `account: address` | Standard AEX-141 optional owner / balance |
| `transfer` | `to: address, token_id: int, data: option(string)` | Owner, per-token approval, or operator; safe receiver callback |
| `transfer_to_contract` | `token_id: int` | Approved calling contract; avoids callback reentrancy |
| `approve` | `approved: address, token_id: int, enabled: bool` | Owner or owner-appointed operator only |
| `approve_all` | `operator: address, enabled: bool` | Sets caller's operator permission |
| `get_approved` / `is_approved` / `is_approved_for_all` | Standard AEX-141 arguments | Approval queries |

No burn or metadata-update entrypoint exists. Tokens and immutable sale receipts
remain auditable after transfer. `aex141_extensions()` advertises the custom
`ecai_personality_receipts_v1` extension, not the standard `mintable` extension
whose signature this contract does not implement.

## Settlement, retries, and confirmations

The order server persists the exact `nft_config` map when it issues the invoice.
`mint/1` and `lookup/1` require this snapshot; neither redirects an old sale to the
currently configured contract. The order also freezes the recipient, package,
URI, cap, and sats amount. The server must verify the settlement, amount, and
payment hash with its own CLN connection, not client-supplied status.

Only orders in `paid` or `mint_pending` state can invoke `mint/1`. Every attempt
first reads `receipt_for_order`. An already minted order returns the original
receipt after verification; a changed recipient, payment hash, amount, or
collection binding fails. The contract allows exactly one order per payment hash
and increments a collection's issued count once. Cap exhaustion does not prevent
an identical retry of its last successfully minted edition.

A submitted transaction, decoded `mint_paid` result, or `th_...` hash alone never
completes an order. The adapter checks the immutable receipt from a static chain
read, then waits for the configured key-block confirmation count (default 3).
`{pending, Map}` means polling/reconciliation must continue. A submit timeout is
ambiguous and also remains pending. An identical retry is safe; blindly creating
another invoice or payment hash for a paid order is not.

The static read is against the node configured in `damage_ae`. The adapter
requires its frozen `network_id` to equal `vanillae:network_id()` before reads or
submission, so switching the runtime network rejects existing orders. The node
still remains a trust dependency. Confirmation counting reduces reorganization risk but does
not make the off-chain settlement trustless. Operationally keep the old node's
network endpoint stable while any orders for its contracts remain outstanding.
Do not switch the global `damage_ae` network between mainnet/testnet in a process
with unsettled orders. Use separate releases and separate order stores.

## Required pre-production exercise

The contract was compiled successfully with official `aesophia_cli` 8.0.0.
Compile it again with the release's compiler and run a testnet sale
using the configured CLN environment. Verify non-minter rejection; identical
order retry; conflicting order/payment rejection; edition exhaustion; transfer
approval and receiver rejection; receipt recovery after restart; and no delivery
before the confirmation threshold. EUnit in `ecai_personality_nft.erl` covers
receipt binding and confirmation logic, but does not execute the Sophia VM.

Primary interface reference:
https://docs.aeternity.com/developer-documentation/aexs/aexs/aex-141
