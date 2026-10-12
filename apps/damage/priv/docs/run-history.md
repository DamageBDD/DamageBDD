# Dashboard run history (public execution evidence)

The **Run history** dashboard panel defaults to the current node when the
node AE public address is available. If the wallet is locked and there is no
configured public node identifier, the page waits for the asynchronous browser
session, then automatically selects the signed-in account. Without either
identity, **Discover nodes** shows recent public network runs (not mislabeled
as local-node runs). The first history request starts on initial direct/history
navigation or first activation of the panel; no Refresh click is required.
Published evidence is read-only: no bearer token, signing key or private run
context is needed by the history API.

## Views

- **This node:** published DAMAGE `spend` events for the configured node ID.
- **My account:** public account transaction activities for the authenticated
  account, or another `ak_...` account selected or entered in the field.
- **Followed nodes:** nodes followed via the authenticated browser's local
  preferences (account-scoped `localStorage`). Follow is allowed only after a
  NodeRegistry lookup verifies the registration; previous follows can be removed.
- **Discover nodes:** recently published network runs plus a collapsed registry
  directory that can be expanded for NodeRegistry registration discovery,
  owner `ak_...` search or node `ak_...` / `ct_...` lookup. Direct owner/node
  lookup works for older registrations.

Feature title or CID, Gherkin tags (space-separated AND semantics), result
(passed/failed/unknown), account, and time range (24h, 7d, 30d, all or custom)
are available. Results are paged and sorted newest first. Each row links to
its immutable feature, full report, on-chain transaction, node and public
account activity.

## Read-only registry API

`GET /api/run-history/nodes?owner=ak_...` — registered nodes owned by the
supplied account (maximum 64 returned, check `total` and `complete`).

`GET /api/run-history/nodes?node=ak_...` — verify and retrieve a single node.

`GET /api/run-history/nodes?discover=1` — browse *recent* registration
transactions. Its `complete:false` signals that NodeRegistry v2 does **not**
expose a global enumeration API. This discovery scan is intentionally bounded:
it is not a complete registry listing. For reliable historical lookup, use the
owner-account or node-ID route. Read methods may return 503 while the node
registry is unreachable or the node keypair needed by its existing read path
is unavailable. No node is labeled as registered based only on middleware
transaction metadata.

## Same-origin activity fallback

`GET /api/run-history/activities?path=/v3/transactions?...` retrieves public
Aeternity middleware pages through DamageBDD only when direct browser reads fail
(e.g. cross-origin restrictions). It also supports the same account activities
and transaction-detail routes needed by the UI. Paths and query parameters are
allowlisted to prevent arbitrary URL proxying; pagination stays on the configured
middleware connection, responses are bounded, and reads are rate-limited. No
credentials or private wallet data are forwarded to the middleware.

## Run metadata

Every newly published run contains a JSON `run.meta` at the IPFS **report
root**, with stable fields: `status`, `feature_title`, `tags`, `public_key`,
`node_public_key`, `start_time_hires`, `execution_time_hires`, and the
pre-existing release/context proof fields. The additional fields are public
and do not include secrets or execution context. Older reports fall back to
reading public Gherkin and plain-text report evidence; an unavailable or
ambiguous result stays `unknown` rather than being reported as passed.

`GET /reports/:cid/run.meta` now serves the public root manifest directly on
the same origin as raw JSON (`Accept: application/json` or `text/html`). The
UI falls back to the IPFS gateway's `/<report-cid>/run.meta` for older nodes
that have not deployed the updated route.

Only **public runs represented by DAMAGE token spend transactions** are
indexed by this iteration. Unpaid/dry runs and locally retained runs with no
public transaction are **not** listed; they need a separate durable local or
published event index before being advertised as full execution history.
For large federated deployments, replace per-browser transaction scanning with
an indexed run-event service keyed by node, account, feature and tag.

## Configuration

Optional OTP `sys.config` setting, inside the `damage` application's tuple
list, if the normal `secrets:node_keypair/0` path cannot yield a public node
address during locked-node startup:

```erlang
{run_history_node_account, <<"ak_REPLACE_WITH_NODE_ACCOUNT">>}
```

Set the address to the **executing node account**, never to the logged-in
user's wallet. The dashboard does not need the node private key to display
its identity, although the current NodeRegistry read implementation uses it
for contract dry calls. The same-origin activity API is available while the
node's signing key is locked if the configured middleware is reachable.

## Validation

```sh
node --test apps/damage/test/scripts/run_history_model.test.mjs
node --experimental-vm-modules --test apps/damage/test/scripts/*.test.mjs
python apps/damage/test/scripts/run_history_browser_test.py
rebar3 compile
rebar3 eunit --module=damage_run_history_http_tests
```

The wider Node suite in the provided archive has one pre-existing test
(`quickstart_ui.test.mjs`) with a path assuming invocation from the repository
root; it cannot resolve its module when run from `apps/damage`. Run from the
monorepo root to exercise it there.
