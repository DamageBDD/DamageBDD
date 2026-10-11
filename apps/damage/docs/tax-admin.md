# ATO tax evidence — node administration

The original tax provenance implementation is a prerequisite: the deployed
source must include `damage_tax_store`, `damage_tax_report`, `damage_tax`,
`damage_tax_cln`, `damage_tax_prices`, and `steps_tax`. This incremental patch
adds the report catalog, background import jobs, API and dashboard.

## Enable through DamageBDD Node Settings

Sign in with a **custodial node-admin session** (wallet-mode browser sessions
are not privileged), then open **Dashboard → Node administration → Node
settings → DamageBDD → Tax & provenance**. While disabled, the sidebar also
shows **Tax evidence setup**. The editing API is the existing authenticated
`/api/admin/settings/damage` endpoint; there is no separate unauthenticated
tax-config API.

Configure the **CLN tax owner (AE account)** (`ak_...`) and **Enable ATO tax
reporting** together, then Save changes. The service will not enable without
an explicit owner. The owner is stored as an Erlang **binary**; directory
paths are absolute Erlang strings, and every field is type-checked. Settings
are written to `$XDG_CONFIG_HOME/damage/damage.config` (usually
`/var/lib/damage/.config/damage/damage.config` for packaged nodes), without
modifying the operator's `-config` file. A tax API key is never editable or
shown in Settings.

| Setting | Default | Apply |
| --- | --- | --- |
| `tax_enabled` | `false` | Restart |
| `tax_cln_owner` | **Required to enable**; no default | Restart |
| `tax_data_dir` | `/var/lib/damage/tax` | Restart |
| `tax_backfill_on_start` | `false` | Restart |
| `tax_standard_utc_offset_minutes` | `600` (AEST, +10h) | Live for next report |
| `tax_max_prices_per_backfill` | `200` | Live for next backfill |
| `tax_price_pause_ms` | `250` | Live for subsequent requests |

The **Restart** label is intentional: `damage_sup` selects the tax journal
and job children at supervisor initialization. A Save persists lifecycle
settings but intentionally does **not** hot-publish `tax_enabled`,
`tax_cln_owner`, `tax_data_dir` or `tax_backfill_on_start` into the running
application environment; this avoids changing tenant/storage bindings during
an active backfill. **Restart the DamageBDD node after
turning tax reporting on/off, changing its owner/directory, or changing the
auto-backfill option.** Until then the Settings UI shows *Restart required*.
Do not confuse an accepted setting with a running tax service.

The equivalent manual `sys.config` tuples (for unattended provisioning) are:

```erlang
{tax_enabled, true},
{tax_data_dir, "/var/lib/damage/tax"},
{tax_cln_owner, <<"ak_REPLACE_WITH_ACTUAL_NODE_OPERATOR">>},
{tax_backfill_on_start, false},
{tax_standard_utc_offset_minutes, 600},
{tax_max_prices_per_backfill, 200},
{tax_price_pause_ms, 250}
```

Use a real, correctly attributed account, not the placeholder. A private,
service-owned directory and private backups are required. Changing the owner
must not silently reassign previous transactions; the report catalog partitions
tenants by owner hash. Tax classification, GST, AUD pricing, CGT and transaction
completeness require accounting review. Reports are **drafts**, not lodged
returns. The standard-time offset controls FY boundaries, not civil timezone
rendering; it deliberately uses AEST (no summer daylight saving).

`tax_backfill_on_start=true` triggers an asynchronous import on the *next*
start. Manual backfill remains available on the private tax dashboard when
running.

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
