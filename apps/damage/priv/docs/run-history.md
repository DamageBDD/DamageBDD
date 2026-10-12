# Run history — public æternity/IPFS evidence

The dashboard **does not require** `/api/run-history/nodes` or a private
execution-history API. Published run evidence is read from the public æternity
middleware and immutable IPFS objects. No wallet access token, private key, or
execution context is used for these reads.

## How a run is found

1. The primary *public transaction index* is
   `GET /mdw/v3/transactions?contract=<DAMAGE_TOKEN_CONTRACT>&type=contract_call&type=paying_for&direction=backward&limit=50`
   on the configured æternity middleware. `/v3/contracts/calls` is **not** used
   for finding DAMAGE token spends: it indexes internal contract calls and can
   miss ordinary `ContractCallTx` and wrapped `PayingForTx` transactions.
2. Preserve the legacy, successful payer scan alongside the token index:
   `/v3/accounts/<NODE_AK>/activities?owned_only=true&type=transactions&direction=backward&limit=50`.
   My account also searches that account's activity, with
   `owned_only=false`. The node, not the user, may be the payer of a wrapped
   run transaction, so account history additionally scans the token index.
3. The reader unwraps nested `PayingForTx` records and validates the configured
   token contract's `spend(node_address, amount, feature_hash, report_hash)`
   call, as defined in `apps/damage/priv/contracts/token.aes`. Transaction
   details are hydrated when necessary. For transactions exposing only encoded
   `cb_` calldata, a **best-effort** extraction accepts exactly two unique
   IPFS CIDs, restricted to the configured token contract. This cannot replace
   full FATE ABI decoding or authenticate the claimed node/runner in `run.meta`.
4. This **DamageBDD node's already-exposed IPFS-backed routes** are used:
   - `GET /reports/<report_hash>/run.meta`: public JSON manifest at the IPFS
     report CID root (new runs). It may legitimately be 404 for legacy runs.
   - `GET /features/<feature_hash>/` with `Accept: text/plain`: raw public
     Gherkin source, including feature name and tags.
   - `GET /reports/<report_hash>/` with `Accept: application/json`: list of
     files in the immutable `reports/` subdirectory. A `.plain.txt` report
     provides a best-effort status fallback for old runs.
   External IPFS gateways are **never requested** by Run history, including
   when legacy dashboard code supplies an `ipfsGateway` setting.
5. A bounded batch automatically follows up to three pages per public source
   when the first pages contain no matching runs. The **Load more runs**
   control continues from the last cursor to search older transactions. Public
   paging may be incomplete, and the UI reports scanned transactions and
   undecodable candidates rather than asserting that the full history is empty.

## Nodes, discovery, and following

- **This node**: the executing node's public `ak_` identity from the dashboard
  configuration; only records whose `spend` node argument matches are shown.
- **My account**: authenticated wallet/account's public `ak_` identity;
  both account activity and global token calls are scanned and filtered by
  the on-chain caller. The account address is public; no private session API
  is needed for run evidence.
- **Followed nodes**: selected public node identities stored locally in the
  browser. Following grants no access and does not assert registry membership.
- **Discover nodes**: the observed node arguments in recent token spends
  plus a **bounded** scan of public NodeRegistry `register_node` transactions (up to three pages). A registration transaction proves only that a
  registration was observed historically, not that a node is currently
  enabled or still owned by the same account. The NodeRegistry v2 contract
  does not offer a global enumerable state method. Owner lookup is limited
  to the scanned history, not exhaustive. Viewing public runs by node ID
  works even when registry scanning fails.

The standard registry contract address is defined by
`damage_node_registry.erl` and as `DEFAULT_REGISTRY_CONTRACT` in
`run-history-model.js`. If using another deployment, supply
the OTP `damage` configuration tuple
`{run_history_registry_contract, <<"ct_YOUR_REGISTRY">>}` or
`window.DamageActivity.nodeRegistryContract` as a public `ct_` ID.
The token contract and middleware may be overridden with
`window.DamageActivity.damageTokenContract` and `.mdwBase`. Run history always
uses same-origin DamageBDD IPFS-backed routes, not `.ipfsGateway`.

## Compatibility and availability

Reads go **directly to public AEMDW**. A same-origin, path-restricted
`/api/run-history/activities` proxy can be used as an optional CORS fallback
when deployed; its absence or a 404 does not prevent using the direct chain
source. The proxy allowlist includes `/v3/transactions` with a
contract filter, individual transactions, and public account activities. `GET /api/run-history/nodes`
may still exist on upgraded nodes but is **not called by the browser**.

Only executions with a public token `spend` and reachable IPFS evidence are
listed in this view when their CIDs can be decoded; unpaid, local-only,
unconfirmed, or undecodable ABI calls require a separate durable index or a
server-side FATE decoder. Client-side feature/tag/time filtering applies to
retrieved records; load more pages to examine older runs. A network failure
must not be presented as an empty public activity history.

## Tests

```sh
node --test apps/damage/test/scripts/run_history_model.test.mjs
python apps/damage/test/scripts/run_history_browser_test.py
rebar3 compile
rebar3 eunit --module=damage_run_history_http_tests
```
