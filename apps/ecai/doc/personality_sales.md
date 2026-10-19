# AI personalities: dashboard and Lightning sales

Open `/dashboard#personalities`. A shareable edition link is
`/dashboard?personality=builder#personalities` (also `mathematician` and `skeptic`).
The catalogue is public; checkout and order history require an existing managed
DamageBDD account. A connected wallet-only session can browse but cannot create
orders. Buyers supply an Aeternity `ak_` recipient, then scan the locally generated
Lightning QR or open/copy the BOLT11 invoice. The server checks CLN settlement,
mints the NFT, waits for chain confirmation and unlocks the JSON personality package.

## Delivered functionality

- Dashboard catalogue, descriptions, traits, sats prices and local edition availability.
- Local QR encoder; no invoice is sent to a third-party QR service.
- Durable account-scoped orders with idempotent checkout, history and resume.
- Core Lightning verification against a pinned treasury identity and network.
- AEX-141 NFT with immutable manifest/hash/cap and deduplicated payment/order receipts.
- Downloadable package and purchase receipt; buyer memory and secrets are not published.
- Account-owned personality selection in conversations, with persistent choices
  and per-request model instructions. See `personality_conversations.md`.
- Three original starter packages containing system instructions, OpenAI-style
  `messages`, licence terms and portability notes. They are explicitly **not evaluated**
  against models yet. Tool connectors, inference, memory services and behavior
  certification are not included in these packages.

## Launch configuration

The UI and catalogue work immediately after compiling/restarting this application.
**Live invoice issuance defaults to disabled.** The supplied example config uses
CLN regtest and Aeternity testnet. The complete DamageBDD umbrella release must
provide `damage_auth`, `damage_cln`, `damage_ae`, `secrets`, `vanillae`, `jsx`, Cowboy
and the normal ECAI dependencies. This archive contains the ECAI app only.

1. Merge `priv/config/personalities.example.config` into `sys.config`. Set CLN's
   exact compressed node public key from `getinfo`. Existing DamageBDD CLN transport
   owns the RPC connection, rune and credentials. Invoice amounts are integer
   millisatoshis calculated as `price_sats * 1000`, matching the existing
   `cln:create_invoice/4` integer-only interface.
2. Review/edit the JSON editions in `priv/personalities/`. Defaults are 21,000 sats
   and 100 editions per package. These are editable starter values, not market
   valuations. The server hashes exact JSON bytes; retain the final bytes.
3. Build the public manifest for each edition with
   `ecai_personality_catalog:manifest(Id)`. Publish and pin its JSON, retaining the
   resulting permanent `ipfs://...` URI. This manifest contains the package hash,
   licence and catalogue details; do not publish customer memory, order data or
   private keys. An HTTPS manifest is supported but IPFS provides a content address.

   ```erlang
   {ok, Manifest} = ecai_personality_catalog:manifest(<<"builder">>),
   file:write_file("/tmp/builder-manifest.json", jsx:encode(Manifest)).
   ```

   Publish that file with your existing IPFS pinning workflow. Manifest output
   omits its own URI so that generating an IPFS content address is not circular.
4. Configure `personality_catalog` with the final manifest URIs. Keep prices,
   editions and package bytes fixed during initial deployment. For example:

   ```erlang
   ManifestURIs = #{
       <<"mathematician">> => <<"ipfs://REPLACE_MATHEMATICIAN_CID">>,
       <<"skeptic">> => <<"ipfs://REPLACE_SKEPTIC_CID">>,
       <<"builder">> => <<"ipfs://REPLACE_BUILDER_CID">>
   },
   Products = [P#{manifest_uri => maps:get(maps:get(id, P), ManifestURIs)}
               || P <- ecai_personality_catalog:defaults()],
   application:set_env(ecai, personality_catalog, Products).
   ```

   Persist the resulting literal product maps under `{personality_catalog, [...]}`
   in `sys.config`; shell `application:set_env` changes do not survive a release
   restart. Every product supports `package_file` (basename only), with default
   `<id>.json`; the package's schema, id and version must match the catalogue.
5. Deploy the NFT contract and register each exact product, following
   `personality_nft_operations.md`. Use `ecai_personality_catalog:all()` to obtain
   validated products with computed package hashes. Do not substitute invented
   package hashes. Enable the NFT adapter after deployment, then require
   `ecai_personality_nft:ready(Product)` to return `ok` for each edition.
6. Require `ecai_personality_cln:ready()` to return the expected treasury identity.
   Exercise a real testnet/regtest sale and restart recovery using the complete
   release. After that, configure the intended production networks and contract,
   explicitly authorize CLN mainnet with `allow_mainnet => true` when using
   `network => <<"bitcoin">>`, then set `personality_sales_enabled` to `true`.

Use separate runtime stores/releases for test and production. Never repoint the
CLN treasury or Aeternity network while orders are outstanding. Each order freezes
the intended configuration; mismatches fail closed. Gas is paid by the configured
Aeternity minter; this release does not purchase AE or provision channels.

## HTTP routes

| Method | Path | Access/result |
|---|---|---|
| GET | `/ecai/personalities` | Public catalogue; no package instructions |
| POST | `/ecai/personalities/orders` | Managed bearer; create/resume an idempotent purchase |
| GET | `/ecai/personalities/orders` | Account's latest 100 orders |
| GET | `/ecai/personalities/orders/:id` | Account-owned order status |
| POST | `/ecai/personalities/orders/:id/reconcile` | Managed bearer, `{}` body; schedule bounded verification |
| GET | `/ecai/personalities/orders/:id/package` | Account-owned confirmed purchase; JSON attachment |

Create body (all three keys required; additional keys rejected):

```json
{
  "personality_id": "builder",
  "recipient": "ak_REAL_CHECKSUM_VALID_RECIPIENT",
  "idempotency_key": "unique-random-client-key-at-least-16-bytes"
}
```

The buyer cannot set the price, payment status, mint result or package hash.
JSON responses use `{"ok":true,"data":...}` or a sanitized error code.
Create responds with a durable `invoice_pending` order while external work runs.
Reuse the exact same idempotency key after an unknown response. Reusing it with
a changed recipient or personality returns a conflict. A different account gets
an independent namespace. User A cannot read or reconcile User B's order.

## Settlement and recovery

`invoice_pending -> pending -> paid -> mint_pending -> minted` is the successful
path. `expired` requires CLN to report that state. A browser countdown alone never
releases an edition or proves a payment failed. `cancelled` means readiness failed
before any invoice creation attempt; no payment request was issued for that order.

The coordinator commits the order and issuance intent to DETS before invoking
CLN. A deterministic label ensures retries recover the same invoice. After any
ambiguous issuance attempt, the edition remains reserved even if a subsequent
lookup is empty: the prior request may still arrive. Never delete such orders to
make stock available. Reconciliation queries CLN before creating another invoice.
Amounts, label, stored hash, BOLT11 and actual received millisatoshis are checked.

Payment confirmation is durable before minting begins. A submitted transaction
does not fulfill a sale. The adapter reads the on-chain receipt, checks the full
immutable order binding and the configured confirmation threshold. Repeated
submissions cannot mint the same order or payment hash twice. Failed or delayed
minting remains recoverable without requiring another buyer payment.

The stored package bytes are the bytes purchased, even if a future version changes
on disk. Download authorization belongs to the original purchasing account;
transferring the NFT does not revoke copies or automatically transfer hosted
download access. The licence explains this limitation. No conversation memory is
included in a transferable edition.

The store defaults under `ecai_paths:runtime_dir()/personalities`, with private
directory/file permissions. Back it up alongside the CLN invoice database. DETS
automatic repair is disabled: if an unclean VM shutdown leaves a table requiring
repair, startup fails closed. Preserve the file, restore a verified backup or
perform an offline repair, and reconcile retained orders against CLN and on-chain
receipts before reopening sales. Never replace the store with an empty table to
clear this error. Service restart recovery is tested; hardware durability and
disaster recovery require an operator-managed backup policy. DETS
is a single-node store, not a distributed ledger. Run one active checkout writer
and dedicated collection/minter configuration; external minting or multiple
independent sales stores could consume capacity reserved for paid orders. Local
availability counts reservations conservatively; chain readiness is rechecked
before issuing invoices.

Disabling new sales does not stop settlement of existing orders. If a paid mint
cannot be completed, an operator must resolve it or issue a separately reviewed
refund through the existing wallet. There is no automatic outbound refund route.
Lightning settlement and Aeternity minting are separate operations, not an atomic
cross-chain transaction.

## Validation scope

See `test/personalities/` for backend/payment harnesses and
`test/test_personalities_browser.mjs` for Chromium component tests. The tests use
fake remote services and test invoice fixtures, never live payments. Sophia
compilation verifies syntax/types; the Erlang adapter tests verify receipt binding
and confirmation logic. Live CLN/auth/Aeternity execution requires the complete
configured release and is a required operator check before enabling production.

Validation for this change (19 October 2026): all eight changed/new Erlang handler,
supervisor, coordinator and adapter modules compile with warnings as errors;
33 EUnit tests pass (16 coordinator, 6 NFT receipt, 11 CLN adapter); 10 Chromium
component tests pass; 3 QR tests pass, including independent ZXing decoding;
4 targeted console integration tests pass. Sophia 8.0.0 compiles the contract
with warnings treated as errors. The entire older console contract suite still
has two assertions that already fail against the uploaded baseline (conversation
history route expectations and a reviewed-push literal); those unrelated features
were not modified here.
