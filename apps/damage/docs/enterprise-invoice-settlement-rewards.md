# Enterprise invoice settlement rewards

DamageBDD can optionally mint a transferable AEX-141 collectible after an
invoice payment has been independently verified by a billing administrator.
The feature is deliberately separate from invoice payment processing: it does
not charge a wallet, prove a bank transfer, or assign a receivable.

## Billing workflow

1. Add a customer and, optionally, their Aeternity `ak_...` settlement account.
2. Create a recurring plan and generate/approve an invoice as normal.
3. Independently verify payment.
4. In **Billing -> Invoices -> Record payment**, optionally select **Mint a
   transferable settlement attestation + reward NFT** and confirm the recipient.
5. DamageBDD persists the paid invoice and queued reward before any chain call.
6. The worker derives a SHA-256 commitment over the private issued invoice and
   payment record, then mints one AEX-141 token to the recipient.
7. The NFT appears through the existing NFT gallery/middleware index and can be
   transferred using standard AEX-141-compatible wallet tooling.

If the node loses the mint response after submitting the transaction, the
invoice moves to `unknown`. Retrying is safe: the contract indexes the unique
attestation hash and refuses a second mint for the same settlement. The worker
queries that index before minting and during reconciliation.

## Privacy and legal semantics

The public token contains the attestation SHA-256, paid date, reward class,
issuer label and generic reward artwork. DamageBDD does **not** publish the
customer name, email, billing address, invoice amount, payment reference, PDF,
or line items to the NFT contract.

The recipient account, token ownership and subsequent transfers are public
blockchain data. A recipient should therefore use an account they are willing
to associate with the collectible.

The NFT is a reward/attestation only. Transferring it transfers collectible
ownership; it does not transfer or assign the invoice, payment, contract,
receivable, service entitlement, warranty, refund right or any other legal
claim. Do not represent it as a financial asset or invoice token.

## Deploy the AEX-141 contract

Deploy `contracts/invoice_settlement_nft.aes` from the billing node using the
existing node contract deployment path. From a trusted Erlang shell, for
example:

```erlang
Result = damage_ae:contract_deploy(
    damage_invoice_settlement_nft:contract_source(),
    []
).
```

Record the returned `ct_...` contract ID. The deploying node account becomes
the contract administrator and is the only account allowed to mint settlement
rewards. Customers remain free to transfer tokens after minting.

Before enabling production minting, verify the deployed contract source and
admin account and test `meta_info`, `settlement_token` and a test mint on the
intended network.

## Configuration

Add `settlement_nft` inside the existing `enterprise_invoices` proplist:

```erlang
{enterprise_invoices, [
    {enabled, true},
    %% ...existing billing configuration...
    {settlement_nft, [
        {enabled, false},
        {contract_id, <<"ct_REPLACE_WITH_DEPLOYED_CONTRACT">>},
        {reward_class, <<"customer">>}
    ]}
]}.
```

Keep `enabled` false until the contract is deployed and verified. Enabling the
feature does not mint automatically for every invoice: the billing admin must
opt in while recording a payment, or explicitly queue a settlement reward on an
already-paid invoice.

## Attestation verification

A paid invoice stores the same `attestation_sha256` recorded in the NFT
metadata. Someone who possesses the private invoice/payment record can
recompute the commitment with DamageBDD and compare it with the token. The
contract also exposes:

- `settlement_token(attestation_hash)` to resolve a commitment to its token ID.
- `settlement(token_id)` for the immutable original recipient, paid date,
  reward class and issue height.
- `verifies(token_id, attestation_hash)` for a direct boolean check.

The existing NFT gallery marks tokens carrying `attestation_sha256` as
settlement rewards. Customers can copy an `aex141:<contract>:<token>:<hash>`
reference or use the browser share sheet from the reward card. That share text
contains no private invoice fields. Because the contract implements standard
AEX-141 transfer/approval entrypoints, the current owner can also transfer or
trade the collectible with compatible Aeternity wallet/marketplace tooling.
