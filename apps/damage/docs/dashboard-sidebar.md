# DamageBDD sidebar dashboard

## Patch baseline

The sidebar builds on the previously supplied `damagebdd-dashboard-ecai-rebased.patch`.
That composer patch targets the uploaded `latest-damage.tar.gz` with SHA-256:

```
d1b507eff0673f1cfdae60346b159754a99d0b1201a2e0db968d316f309012ed
```

Choose **one** delivery:

* `damagebdd-dashboard-sidebar.patch`: incremental, for a checkout that already
  contains the rebased ECAI composer.
* `damagebdd-dashboard-sidebar-from-latest.patch`: the composer and sidebar
  together, for the uploaded archive's code before either patch.

Apply from the umbrella repository root with `git apply --check`, then `git apply`.
These patches do not reset or discard unrelated working-tree changes. A failed
check means the checkout differs; resolve it rather than forcing the patch.

The available archive contains only `apps/damage`. ECAI's dashboard templates
were not present in it or found in the available file search. This implements
an ECAI-style left-sidebar navigation pattern while retaining DamageBDD's
existing colours and authoring workspace; it is not a verified pixel-for-pixel
copy of an ECAI screenshot.

## Layout and interaction

The desktop shell has a persistent left sidebar, a compact page/wallet header
and a separate content area. The sidebar groups Verification, Assets, optional
Node administration, and Settings. Install, sign-out and node-wallet controls
live at the bottom without changing their existing IDs or modal targets.

The header button collapses the desktop sidebar to an icon rail. The only new
stored value is the boolean `damage.dashboard.sidebar.collapsed.v1` preference.
Prompts, features, credentials, invoice records and run output are not stored by
the navigation module. Blocked storage simply disables preference persistence.

At 900 CSS pixels and below, the sidebar becomes an off-canvas drawer. Opening
it focuses the current navigation link, makes the main content inert and traps
Tab within the drawer. Escape, its close button, the backdrop or a panel choice
closes it. Dismissal restores opener focus; panel selection focuses the panel.
Resizing releases the drawer's focus/scroll locks and retains the independent
desktop preference. Sidebar modal actions release the drawer trap in capture
phase, before button handlers; MicroModal's onShow hook also releases it for
programmatically opened modals.

Arrow Up/Down and Home/End move between visible navigation links. Enter follows
the link. Links use `aria-current="page"`, not a fake ARIA menu or primary
Tabby tab list. Collapsed text is visually clipped but keeps accessible names.
The skip link targets the main content area. Reduced motion is respected.
No formal accessibility-conformance certification is claimed.

The content editor and output nodes stay mounted across section changes. Existing
section hashes are retained, so reloads and native Back/Forward navigation select
the expected section. Navigation never invokes feature execution. With JavaScript
disabled, ordinary server-rendered panels are shown and the navigation acts as
in-page anchors; the JS-dependent composer and service controls still need JS.

## Integration

`sidebar.mustache` replaces `tabs_bar.mustache`. `damage_dashboard` renders the
new partial with the existing footer. `?component=sidebar` returns it;
`?component=tabs` is retained as a rendering alias to the same sidebar.
Existing panel IDs such as `execution-tab`, `activity-tab` and `billing-tab`
remain unchanged.

`dashboard-navigation.js` initializes independently of wallet imports and owns
only primary panel visibility. It exposes an idempotent `initDashboardNavigation()`
and `window.dashboardNavigation` with `navigate()`, `openDrawer()`, `closeDrawer()`
and a read-only `activePanel`. Known hidden or omitted links are not selectable.
A URL fragment is decoded as a bounded local identifier and compared with the
server-rendered navigation; it is never interpolated into a CSS selector.

A changed section emits `damage:panelchange` on `document` with:

```javascript
{ id, panel, link, previousId, previousPanel }
```

The main controller listens for Run history and Schedules refreshes and handles
an initial deep link even when wallet imports settle after navigation setup.
`billing.js` listens to the same event for the invoice refresh. Tabby remains
loaded for nested authentication, token, node-setup and run-report tabs.
The feature picker is initialized once instead of on each workspace activation.

Invoice navigation stays hidden until the existing billing session code reveals
it. A deferred `#billing-tab` link can activate after that reveal. Hiding the active
invoice link returns to Workspace and repairs the URL/focus. These are UI rules,
not authorization: billing, node and execution permissions remain enforced by
the existing server endpoints. Authentication display changes hide/show the
whole shell, rather than leaving sidebar controls visible outside `#content`.

`dashboard-shell.css` is loaded after the workspace stylesheet. Obsolete primary
tab rules are removed from the workspace stylesheet and the primary-only
`slick-tabs.css` is no longer loaded by this dashboard. Modal styles remain.
Container-responsive editor/output columns account for the space taken by the
sidebar. Wide legacy tables remain scrollable within their own panel.

No model generation, validation, payment, invoice mutation or OTP supervision
logic changes in the incremental sidebar patch. The Erlang change is the
Mustache component composition in `damage_dashboard.erl`.

## Verification and deployment

Run from the repository root:

```bash
node --test apps/damage/test/scripts/bdd_composer_model.test.mjs \
  apps/damage/test/scripts/dashboard_navigation.test.mjs

python3 apps/damage/test/scripts/bdd_composer_browser_test.py \
  --out /tmp/damage-composer-preview
python3 apps/damage/test/scripts/dashboard_navigation_browser_test.py \
  --out /tmp/damage-sidebar-preview

rebar3 compile
```

The Python suites require Playwright and Chromium. `--chromium /path/to/chromium`
selects an existing browser. Fixtures render the actual Mustache shell, local
styles and panels, then execute the real navigation/composer controllers and
selected real `main.js` hooks with simulated service functions. The fixture
renderer implements the scalar/boolean Mustache subset used here; it does not
replace or validate the production renderer.

Navigation tests use `about:blank` and native same-document history, with all
network requests aborted. Successful Storage persistence/restoration uses an
explicit in-memory Storage fixture because that origin denies native Storage.
The blocked-storage test exercises that native denial. No production-origin
Storage persistence, live ECAI, billing authentication, payments, wallet signing
or complete application bootstrap has been tested by these fixtures.

The suites cover retained editor/output state, keyboard and mobile focus,
URL/history/deep links, hidden invoice reveal/revocation, administrator-only
markup, modal handoff, preference restoration and blocked storage. Width checks
cover 320, 390, 768, 900, 901, 1024 and 1440 pixels across ten ordinary/admin panels.
The screenshots and standalone preview are labelled as simulated API responses.

No Erlang/rebar3 toolchain was available for this delivery; compile the changed
renderer in the full umbrella before deploying. Deploy the renderer and assets
together and hard-refresh cached CSS/JS. On a running node, check login/logout,
wallet modals, history/schedule data refresh, invoice permissions and node-admin
navigation. Also verify Safari/Firefox and assistive technologies; the automated
browser checks here are Chromium-only.
