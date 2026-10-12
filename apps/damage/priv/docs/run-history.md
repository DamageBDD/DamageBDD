# Run history — public æternity/IPFS evidence

The dashboard **does not require** `/api/run-history/nodes` or a private
execution-history API. Published run evidence is read from the public æternity
middleware and immutable IPFS objects. No wallet access token, private key, or
execution context is used for these reads.

## How a run is found

1. The primary public index is
   `GET https://mainnet.aeternity.io/mdw/v3/contracts/calls?contract_id=<DAMAGE_TOKEN_CONTRACT>&direction=backward&limit=50`.
   Only the configured DAMAGE token contract is trusted as a run source.
2. The original `reports.js` fallback remains available: a selected node
   account is scanned at
   `/v3/accounts/<NODE_AK>/activities?owned_only=true&type=transactions&direction=backward&limit=50`.
   The account view additionally scans that user's activities with
   `owned_only=false`, **and** the contract-call index because `PayingForTx`
   transactions can be submitted by the node instead of the user.
3. Contract call/transaction records are inspected for the `spend` entrypoint
   with the four arguments defined by `apps/damage/priv/contracts/token.aes`:
   `(node_address, amount, feature_hash, report_hash)`. Both hashes must be
   valid IPFS CIDs and the contract must match the configured token contract.
   Middleware transaction details are fetched when a call index omits the
   user/caller or timestamp. Pagination follows middleware `next` links.
4. Feature title/tags are read from
   `https://ipfs.io/ipfs/<feature_hash>`. New runs contain JSON metadata at
   `https://ipfs.io/ipfs/<report_hash>/run.meta`. The existing report browser
   (`damage_reports.erl`) serves the report *files* from the immutable
   `reports/` directory via `/reports/<report_hash>/`; the root `run.meta`
   must not be assumed to exist at `/reports/<report_hash>/run.meta` on an
   older deployed server.
5. If run metadata is missing, feature title and Gherkin tags can still be
   obtained from the immutable feature file. An unknown legacy result remains
   `unknown` instead of assuming success.

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
  plus a **bounded** scan of public NodeRegistry `register_node` contract
  calls (up to three pages). A registration transaction proves only that a
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
Likewise the token contract and middleware/gateway may be overridden with
`window.DamageActivity.damageTokenContract`, `.mdwBase`, and `.ipfsGateway`.

## Compatibility and availability

Reads go **directly to public AEMDW**. A same-origin, path-restricted
`/api/run-history/activities` proxy can be used as an optional CORS fallback
when deployed; its absence or a 404 does not prevent using the direct chain
source. The proxy allowlist includes `/v3/contracts/calls`, individual
transactions, and public account activities. `GET /api/run-history/nodes`
may still exist on upgraded nodes but is **not called by the browser**.

Only executions with a public token `spend` and reachable IPFS evidence are
listed in this view; unpaid, local-only, and unconfirmed runs require a
separate durable index. Client-side feature/tag/time filtering applies to
retrieved records; load more pages to examine older runs. A network failure
must not be presented as an empty public activity history.

## Tests

```sh
node --test apps/damage/test/scripts/run_history_model.test.mjs
python apps/damage/test/scripts/run_history_browser_test.py
rebar3 compile
rebar3 eunit --module=damage_run_history_http_tests
```
