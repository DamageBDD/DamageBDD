# ATO tax evidence — node administration

The original tax provenance implementation is a prerequisite: the deployed
source must include `damage_tax_store`, `damage_tax_report`, `damage_tax`,
`damage_tax_cln`, `damage_tax_prices`, and `steps_tax`. This incremental patch
adds the report catalog, background import jobs, API and dashboard.

## Config

In the existing `{damage, [...]}` application tuple list, configure (replace
the account and directory; do not commit real secret tokens):

```erlang
{tax_enabled, true},
{tax_data_dir, "/var/lib/damage/tax"},
{tax_cln_owner, <<"ak_REPLACE_WITH_ACTUAL_NODE_OPERATOR">>},
{tax_backfill_on_start, false},
{tax_standard_utc_offset_minutes, 600},
{tax_max_prices_per_backfill, 200},
{tax_price_pause_ms, 250}
```

The tax journal is append-only and local; use a directory owned by the daemon
with restrictive filesystem permissions and private backups. **Do not share**
this single-writer journal across DamageBDD nodes. Source event classification,
AUD prices, CGT treatment, GST and ledger completeness must be reviewed before
any report is described as ATO compliant. Reports are drafts, not lodged returns.

`tax_cln_owner` represents the legal owner of the CLN transactions. Shared
node transaction history must be attributed separately before ingestion.
The service is enabled only after the next application start. Starting with
`tax_backfill_on_start=true` triggers asynchronous import; the default is false
so an operator can review ownership and funding first.

## Admin dashboard

The `Tax evidence` link appears under `Node administration` when
`tax_enabled=true` and the session has the `node_admin` role. The standalone
route is `/node/admin/tax`. Normal wallet-mode browser sessions are not admin
even when an account address appears in `node_admins`. Download endpoints
require the same admin authentication; they do not publish reports to IPFS.

Routes:

- `GET /node/admin/tax`
- `GET /api/node/tax/reports`
- `GET /api/node/tax/jobs`
- `POST /api/node/tax/backfill` JSON `{"scope":"all"}`
- `POST /api/node/tax/backfill` JSON `{"year":2026}`
- `POST /api/node/tax/backfill` JSON `{"scope":"all","source":"journal"}`
- `GET /api/node/tax/download/2026/<manifest_sha256>/csv`
- `GET /api/node/tax/download/2026/<manifest_sha256>/json`
- `GET /api/node/tax/download/2026/<manifest_sha256>/sha256`

For POST, include `Content-Type: application/json` and
`X-Damage-Tax-Request: 1` and use a valid administrator session.

In an Erlang shell (once enabled):

```erlang
{ok, started} = damage_tax_jobs:backfill(all).
damage_tax_jobs:status().
{ok, started} = damage_tax_jobs:backfill({existing, all}).
{ok, Reports} = damage_tax_catalog:list_reports(
    <<"ak_REPLACE_WITH_ACTUAL_NODE_OPERATOR">>).
```

The `existing` scope creates financial-year reports from events already in
this node's private tax journal and does not query CLN again. Running the
full backfill fetches settled CLN invoices/payments via `damage_cln`, archives
historical price evidence when available, and produces draft FY reports.

## Tests

```sh
rebar3 compile
rebar3 eunit --module=damage_tax_tests
node --check apps/damage/priv/static/js/tax-admin.js
```

A recompile and application restart is needed to register the HTTP handler
and optional supervised workers.
