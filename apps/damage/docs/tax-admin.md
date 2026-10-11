# ATO tax evidence — node and tax administration

The original tax provenance implementation is a prerequisite: the deployed
source must include `damage_tax_store`, `damage_tax_report`, `damage_tax`,
`damage_tax_cln`, `damage_tax_prices`, and `steps_tax`. This incremental patch
adds the report catalog, background import jobs, API and dashboard.

## Roles and configuring through the dashboard

Node administrators (configured by `node_admins`) and delegated tax administrators
(configured by a **separate operator-controlled allowlist**) may view private
tax evidence and edit the **seven** tax settings. Only node administrators can
access the general Node Settings API, node context, CLN administration, or
other privileged node controls.

To authorize a tax administrator, an operator must configure the following in
the `damage` application environment in `sys.config` (not the dashboard):

```erlang
{tax_admins, [<<"ak_DELEGATED_TAX_ADMIN_ACCOUNT">>]},
```

Use the actual AE account from a custodial authenticated identity. The list is
not editable using any dashboard tax or general settings endpoint, and changes
to operator configuration must be loaded by the node. Node administrators are
implicitly tax administrators; `tax_admins` does not grant `node_admin`.
Wallet-mode and L402 sessions are *never* granted tax-admin capabilities,
even when their AE address appears in an administrative allowlist.

Sign in with an appropriate admin session, then open **Dashboard → Tax reports
→ Tax module configuration** (`/#node-tax-reports-tab`). The form is available
even if tax reporting is currently disabled. The settings are stored in the
versioned XDG managed `damage.config` overlay by `damage_settings`; the editor
submits only tax-specific changes to `GET/POST /api/node/tax/settings`.

`GET` exposes only seven tax field records, an optimistic-concurrency version
and tax-only pending-restart metadata. `POST` requires
`Content-Type: application/json`, `X-Damage-Tax-Request: 1`, an authorized
session and a valid version. For example:

```json
{"action":"save","version":"<version from GET>","changes":{"tax_enabled":true,"tax_cln_owner":"ak_YOUR_REAL_OWNER_ACCOUNT"}}
```

The backend rejects attempts to change `node_admins`, `tax_admins`, CLN policy,
NWC policy or other non-tax fields, even if a client forges the UI or POST JSON.
Provider API keys remain protected and unavailable for reading or mutation.
A stale version returns HTTP 409 and requires the browser to reload settings.

Node administrators can **also** use the existing Node Settings interface at
`/dashboard/node/settings/damage#settings-feature-tax`. Tax-only administrators
cannot use `/api/admin/settings/damage` or that general settings page.

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

For node and delegated tax administrators, the main DamageBDD dashboard has **Tax reports** at `/#node-tax-reports-tab`. The panel appears even when the tax
service is disabled, in which case its built-in Tax module configuration form
can be used to enable reporting without leaving the dashboard. No report metadata is sent to non-admin sessions. Delegated tax admins see
only the Tax administration sidebar group, not node settings or CLN controls.

When enabled, the dashboard lists immutable financial-year revisions and provides:

- financial-year, review-status and report-revision filters, plus a manifest/evidence
  SHA-256 search; by default only the latest revision per financial year is listed
- paging (20 reports per page); summary counters always count latest revisions only
- per-report **Transactions CSV**, **Manifest JSON** and **SHA-256** downloads,
  served by the existing authenticated private tax API
- **Export filtered CSV index** and **Export filtered JSON index**; these browser-
  generated files include *catalog metadata only*, across all filtered pages,
  not transaction details or invoice secrets
- an admin-triggered CLN history backfill, journal-only regeneration, live job
  status and manual refresh

The standalone `/node/admin/tax` view remains available for compatibility, but
`/#node-tax-reports-tab` is the primary integrated admin reporting interface.
Wallet-mode browser sessions do not gain node-admin privileges merely because
an account address appears in `node_admins`. The backend still authorizes every
report/download and tax settings request; client-side filters are convenience features only.

Routes:

- `GET /node/admin/tax`
- `GET /api/node/tax/settings` (only scoped tax fields)
- `POST /api/node/tax/settings` (save/reset, optimistic concurrency)
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
node --test apps/damage/test/scripts/dashboard_tax_reports.test.mjs
python3 -m unittest discover -s apps/damage/test/scripts -p test_tax_dashboard_navigation.py
python3 -m unittest discover -s apps/damage/test/scripts -p test_tax_dashboard_browser.py
python3 apps/damage/test/scripts/dashboard_navigation_browser_test.py --out /tmp/damage-tax-nav
```

A recompile and application restart is needed to register the HTTP handler
and optional supervised workers.
