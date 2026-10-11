# Multi-jurisdiction tax evidence — node and tax administration

The tax service includes `damage_tax_store`, `damage_tax_report`,
`damage_tax_cln`, `damage_tax_prices`, `damage_tax_catalog`, `damage_tax_jobs`,
`damage_tax_http` and `steps_tax`. Multi-jurisdiction reporting adds
`damage_tax_regions` and `damage_tax_workpapers`, and extends the existing
private admin dashboard.

## Roles and configuring through the dashboard

Node administrators (configured by `node_admins`) and delegated tax administrators
(configured by a **separate operator-controlled allowlist**) may view private
tax evidence and edit the **eight** tax settings. Only node administrators can
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

`GET` exposes only eight tax field records, an optimistic-concurrency version
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

Configure the **CLN tax owner (AE account)** (`ak_...`) and **Enable private tax
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
| `tax_jurisdiction` | `AU` (choose country in Tax settings) | Live for subsequent reports |
| `tax_standard_utc_offset_minutes` | `600` (legacy AU default; country runs override) | Live for next report |
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
{tax_jurisdiction, <<"AU">>},
{tax_standard_utc_offset_minutes, 600},
{tax_max_prices_per_backfill, 200},
{tax_price_pause_ms, 250}
```

Use a real, correctly attributed account, not the placeholder. A private,
service-owned directory and private backups are required. Changing the owner
must not silently reassign previous transactions; the report catalog partitions
tenants by owner hash. Classification, GST/VAT, gains, expenses and transaction
completeness require accounting review. Reports are **drafts**, not lodged
returns. Reports use a configured *fixed* UTC offset for financial-period
boundaries, not a civil timezone database; the AU default is AEST (+10h, no DST).

`tax_backfill_on_start=true` triggers an asynchronous import on the *next*
start. Manual backfill remains available on the private tax dashboard when
running.

## Admin dashboard

For node and delegated tax administrators, the main DamageBDD dashboard has **Tax reports** at `/#node-tax-reports-tab`. The panel appears even when the tax
service is disabled, in which case its built-in Tax module configuration form
can be used to enable reporting without leaving the dashboard. No report metadata is sent to non-admin sessions. Delegated tax admins see
only the Tax administration sidebar group, not node settings or CLN controls.

When enabled, the dashboard lists immutable financial-year revisions and provides:

- jurisdiction, financial-year, review-status and report-revision filters, plus
  manifest/evidence SHA-256 search; by default only the latest revision for each
  distinct jurisdiction and time window is listed
- paging (20 reports per page); summary counters always count latest revisions only
- per-report **Transactions CSV**, **Regional workpaper CSV**, **Manifest JSON**
  and **SHA-256** downloads,
  served by the existing authenticated private tax API
- **Export filtered CSV index** and **Export filtered JSON index**; these browser-
  generated files include *catalog metadata only*, across all filtered pages,
  not transaction details or invoice secrets
- a selectable report country, local fixed UTC offset, financial-year start month
  (for custom-period profiles), admin-triggered CLN backfill, journal-only
  regeneration, live job status and manual refresh

The standalone `/node/admin/tax` view remains available for compatibility, but
`/#node-tax-reports-tab` is the primary integrated admin reporting interface.
Wallet-mode browser sessions do not gain node-admin privileges merely because
an account address appears in `node_admins`. The backend still authorizes every
report/download and tax settings request; client-side filters are convenience features only.

Routes:

- `GET /node/admin/tax`
- `GET /api/node/tax/settings` (only scoped tax fields)
- `GET /api/node/tax/jurisdictions` (authenticated ISO country profiles)
- `POST /api/node/tax/settings` (save/reset, optimistic concurrency)
- `GET /api/node/tax/reports`
- `GET /api/node/tax/jobs`
- `POST /api/node/tax/backfill` JSON `{"scope":"all"}`
- `POST /api/node/tax/backfill` JSON `{"year":2026}`
- `POST /api/node/tax/backfill` JSON `{"scope":"all","source":"journal"}`
- `GET /api/node/tax/download/2026/<manifest_sha256>/csv`
- `GET /api/node/tax/download/2026/<manifest_sha256>/worksheet`
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

## Country profiles and accountant workpapers

Tax reporting is a private accounting workflow. Selecting a country changes **the
financial-year boundary**, **fiat quote currency** and **workpaper columns** for
that report run; it does not establish the legal tax residence of an individual
or business and does not decide tax liability. **Backfill API calls** without a
country use the configured `tax_jurisdiction` (AU by default); low-level
`damage_tax_report:build/5` remains AU/AUD for existing integrations.
Previously saved Australian reports remain addressable by the same year and
SHA-256 digest.

Supported initial profiles (ISO country codes):

| Country | ISO | Fiat | Standard report start | Workpaper emphasis |
|---|---|---|---|---|
| Australia | `AU` | AUD | 1 July | Income and CGT review |
| United States | `US` | USD | 1 January | Form 8949 *supporting* worksheet |
| New Zealand | `NZ` | NZD | 1 April | Cryptoasset business income |
| India | `IN` | INR | 1 April | Schedule VDA *supporting* worksheet |
| Singapore | `SG` | SGD | 1 January | Digital-token business records |
| United Arab Emirates | `AE` | AED | 1 January (configurable) | Corporate-tax accounting records |
| United Kingdom | `GB` | GBP | 6 April (configurable) | Income / capital-gain records |
| Switzerland | `CH` | CHF | 1 January (configurable) | Income / holdings |
| Hong Kong | `HK` | HKD | 1 January (configurable) | Profits-tax records |
| Canada | `CA` | CAD | 1 January (configurable) | Income / capital gains |
| Portugal | `PT` | EUR | 1 January (configurable) | Crypto income and disposals |
| Japan | `JP` | JPY | 1 January (configurable) | Whole-yen valuation |
| Germany | `DE` | EUR | 1 January (configurable) | Income and disposals |

These are **report presets**, not definitive accounting year rules for every
entity. For profiles supporting a custom period, the dashboard lets an operator
set the **start month**, with day 1 for overridden months. The GB default remains
6 April when using April. AU, NZ and IN currently fix the preset start month;
entity-specific exceptions must be handled separately. The UAE profile permits
selecting the actual corporate reporting period.

To start a country-specific report, select a country under
**Dashboard → Tax reports → Generate or refresh reports**, verify its fixed
UTC offset, choose the reporting year and submit. The authenticated endpoint is:

```http
POST /api/node/tax/backfill
Content-Type: application/json
X-Damage-Tax-Request: 1

{"jurisdiction":"US","standard_utc_offset_minutes":-300,"period_start_month":1,"year":2026,"source":"journal"}
```

`source:"journal"` reuses the private, already-imported records and does not
query CLN. Remove `source` to import settled CLN history. `scope:"all"` is an
alternative to `year`. Inputs are validated against the fixed server registry;
unknown ISO codes, unsupported financial-year changes and invalid offsets are
rejected. A **tax-admin** (or node-admin) session is required for this endpoint,
for listing reports and for every file download; there are no public exports.

Each report manifest includes the country, fiat currency, minor-unit precision,
year/period bounds, fixed offset, evidence hashes and review reasons. Historical
prices must be fetched in **the selected fiat currency**; an AUD price quote is
never renamed USD or INR. Archived price keys include the currency, so separate
jurisdictions can use the same source transaction without overwriting each
other's historical valuation evidence. Japan's JPY report uses zero minor
fractional digits, while other current profiles use two.

The `worksheet` endpoint returns a jurisdiction-oriented **draft** CSV,
including classification, evidence, and transaction-reference columns. US and
India workpapers have relevant Form 8949 / Schedule VDA headings, but **are not
those official forms**, and do not calculate TDS, corporate income tax, VAT,
GST, tax rates or automatically file returns. Transfer treatment, missing lots,
price availability and jurisdiction-specific rules require accountant review.

### Compatibility and privacy

- The existing `build/5`, `fy_bounds/2`, `required_prices/2,3`, `aud_cents/2`
  and default `fetch_and_archive_quote/3` interfaces remain Australian/AUD.
- New country-aware exports have **schema version 2**; historical schema v1
  manifests can still be downloaded. The report digest changes when the country,
  year period or price evidence changes.
- Only administrative sessions with `tax_admin` permission see the country
  picker and per-report workpapers; no tax private journal records are published
  to IPFS by the report service. On-chain attestations remain separate.
- Country reports operate at a national workpaper level. Sub-national US state,
  Canadian provincial, Indian state GST and similar local tax calculation is
  not included in this release.

## Tests

```sh
rebar3 compile
rebar3 eunit --module=damage_tax_tests
rebar3 eunit --module=damage_tax_access_tests
rebar3 eunit --module=damage_settings_schema_tests
node --check apps/damage/priv/static/js/tax-admin.js
node --test apps/damage/test/scripts/dashboard_tax_reports.test.mjs apps/damage/test/scripts/dashboard_tax_settings.test.mjs
python3 -m unittest discover -s apps/damage/test/scripts -p test_tax_dashboard_navigation.py
python3 -m unittest discover -s apps/damage/test/scripts -p test_tax_dashboard_browser.py
python3 apps/damage/test/scripts/dashboard_navigation_browser_test.py --out /tmp/damage-tax-nav
```

A recompile and application restart is needed to register the HTTP handler
and optional supervised workers.
