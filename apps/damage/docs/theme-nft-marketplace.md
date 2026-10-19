# DamageBDD Theme NFT marketplace (v1)

A node-wide **data-only**, versioned theme design system with IPFS distribution,
AEX-141 ownership licensing, Lightning (sats) and AEX-9 DAMAGE checkout.

## Installation

Apply the overlay to the corresponding versions of `apps/damage`, `apps/ecai`,
and `apps/nosternity` (see the accompanying `.patch`). Build and start the
normal OTP release. The supervised `damage_theme_store` stores catalog,
selections, and invoice journal in `damage_config:state_dir()/themes/catalog.dets`.
Back up this file along with the existing node state; keep it private and
read/writeable only by the node service user. The stores are per-node, not
replicated. Reinstalling or importing by IPFS CID is required on another node.

An AEX-141 contract must be deployed on the **same Aeternity network** as the
DAMAGE AEX-9 token. The constructor accepts the deployed DAMAGE token contract
address. Check the selected network and token address carefully before deploy:

```erlang
TokenCt = "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk".
Source = damage_ae:contract_path(damage, "contracts/theme_nft.aes").
damage_ae:contract_deploy(Source, [TokenCt]).
```

This command is an example requiring a funded/unlocked node keypair and a
working Sophia compiler and AE node. Inspect the deploy response for its
`contract_id`; **do not configure a placeholder ID**. The contract creator
becomes the registry administrator and the **only Lightning minter**. A
separate marketplace operator must have its own deployment or explicit
contract delegation added and audited first. Deployment was not executed
or simulated in this delivery.

In the `damage` OTP application configuration (Erlang tuples, not JSON maps):

```erlang
{damage, [
  {theme_nft_contract, <<"ct_REPLACE_WITH_DEPLOYED_THEME_NFT_CONTRACT">>},
  {theme_damage_token_contract,
      <<"ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk">>}
]}.
```

Merge these entries into the existing `damage` configuration, rather than
creating a duplicate application entry. The token configured in the Erlang
adapter must equal the token passed to the deployed contract constructor.
Existing `damage_cln`, IPFS, AE middleware, node secrets and browser
session/auth services must be operational. No network or signing key is
hardcoded into the implementation; the displayed token address above is the
repository's current `DAMAGE_TOKEN_CONTRACT` macro and must be validated
for your deployment.

## Admin and marketplace

- Public shop: `/themes`, catalog: `GET /api/themes`
- Node admin: `/dashboard/node/themes`, API: `GET/POST /api/admin/themes`
- CSS: `GET /api/themes/css?app=damage|ecai|nosternity|erm|bop`
- Branding: `GET /api/themes/branding?app=...`
- Lightning checkout: `POST /api/themes/buy/sats`, then `POST
  /api/themes/order/settle` with `{ "order_id": "..." }` to verify the invoice
  and reconcile or trigger the NFT mint; `GET /api/themes/order?id=...`
  is **read-only** and has no financial effects.
- DAMAGE checkout: `POST /api/themes/buy/damage` (custodial account with
  previously approved allowance) or an **external-wallet signing intent**.

POST routes require an authenticated session, a JSON body, the
`x-damage-settings-action: 1` header, and the same Origin/CSRF check as the
existing admin settings UI. Admin actions additionally check the actual
`node_admin` role and allowlist; **wallet login does not grant node-admin**.

A public theme can be selected from the admin UI for each app independently.
The optional overrides are `name`, `tagline`, `logo`, and `favicon`.
Logos/icons are constrained to same-origin `/static/img/` PNG/JPEG/WebP/ICO.
Place the actual images on each target app listener yourself; these local
operator-controlled brand assets are **not** distributed by the v1 IPFS bundle.
The theme tokens and branding *references* are portable; uploaded binary image
packaging and CSP-safe asset serving are explicitly deferred.

## Theme manifest

```json
{
  "schema": "damage-theme/v1",
  "id": "orbit",
  "version": "1.0.0",
  "name": "Orbit",
  "description": "Soft graphite with an amber accent",
  "tokens": {
    "background": "#121824", "surface": "#202d3c", "text": "#ecf0f7",
    "muted": "#a1b0c5", "accent": "#f6c268", "border": "#354458"
  },
  "branding": {"name": "", "tagline": "", "logo": "", "favicon": ""},
  "apps": ["damage", "ecai", "nosternity"],
  "price_sats": 2500,
  "price_damage": 500000000
}
```

`price_damage` is **integer AEX-9 base units**: the repository's
`DAMAGE_DECIMALS` is `8`, hence 500000000 means 5 DAMAGE. `price_sats` is
integer satoshis, converted to msat for the Lightning invoice.
A v1 bundle contains `theme.json`, generated `theme.css` and `metadata.json`.
The validator rejects arbitrary CSS/JS, remote image URLs, control characters,
raw HTML and off-spec color values. The content digest is SHA-256 of a
canonicalized Erlang term (not the on-disk JSON bytes). All nodes must run
an implementation of the **same v1 digest algorithm**. Each registered theme
version binds immutable CID, digest and dual currency prices in AEX-141
contract storage.

## Publishing and remote import

The node-admin publish action validates the manifest, packages and pins the
files in IPFS, journals an `pending_registration` record and submits
`register_theme` to the NFT registry. An uncertain outcome stays pending and
requires operator reconciliation; the contract forbids key re-registration.
Remote nodes use IPFS `CID/theme.json` and only install if the on-chain
registry confirms the **exact** `CID` and canonical digest. The admin
`import` button performs this check; the server never extracts arbitrary tar
archives or loads user-provided CSS/JS.

## Payment and license semantics

**Lightning:** a customer starts checkout with their authenticated Aeternity
address. The server uses a unique invoice label, persists the invoice hash,
amount and beneficiary, then on an explicit POST checks the paid CLN invoice
and its label/hash/received amount. After a durable `minting` marker it
calls admin-only `mint_sats`. The contract consumes the unique `payment_id` so
it can never mint twice. After an uncertain transaction the server only
reads that ID on chain; it **does not** automatically rebroadcast. An operator
must manually resolve a stuck paid/minting journal entry using CLN evidence
and AE transaction history. A paid invoice alone is not a licence.

**DAMAGE:** the AEX-141 `buy_damage(key)` entrypoint atomically invokes AEX-9
`transfer_allowance(buyer, publisher, amount)` and mints an NFT to the buyer.
Customers using managed custody must authorize an exact allowance for the
NFT contract beforehand. Wallet-only sessions get the contract/entrypoint
and allowance intent to execute in their external Aeternity wallet, **not**
a forged server-side signature. The current Theme Studio does not yet automate
external Superhero signing of those two transactions.

**Activating:** a node administrator supplies a theme key and token ID. The
server verifies the NFT is for that theme **and belongs to the node admin
account**, then saves the selection. Future CSS/branding reads reverify
ownership. If a paid NFT is transferred or chain verification fails, the app
falls back to its built-in default design. Free bundled themes do not require
licences. Free imported themes can be activated without an NFT because the
registry's immutable manifest advertises both prices as zero.

## Verification

```sh
rebar3 compile
rebar3 eunit --module=damage_theme_manifest_tests
node --check apps/damage/priv/static/js/theme-studio.js
```

The BDD public API probe is at
`apps/damage/priv/features/themes/theme_marketplace.feature` (adjust the
server URL to your staging node before running). Before accepting live money,
run an actual Sophia compile/deploy on a testnet, exercise wrong-allowance
reverts, inspect all returned FATE record and option shapes, test a real CLN
payment and crash recovery, and audit the contract. **The artifact has only
been statically reviewed; no Erlang/Sophia compiler or production services
were present in the patch-building environment.**
