# Unified node administration dashboard

This v2 patch is rebased against `latest-damage.tar.gz` uploaded on 11 October
2026 **after** the reloadable-settings and node-settings patches. It preserves
the browser test's newer layout checks (compact button dimensions, background,
and responsive grid) that were missing from the original patch's context.

The dashboard has **one** server-rendered `Node administration` group under
`{{#node_admin}}` in `sidebar.mustache`, with:

- **Node settings** — `/dashboard/node/settings` (DamageBDD / ECAI / Nosternity)
- **Node context** — `/#node-context-tab` (node-wide runtime context)
- **Transactions** — `/#node-transactions-tab`
- **CLN channels** — `/#node-channels-tab`
- **CLN admin** — `/#node-cln-admin-tab`

Account settings remain under **Manage → Settings**, without the former
node-context editor. Node context is now its own node-admin dashboard panel.
The context editor retains its existing IDs and `/node/context` API. The editor
is loaded upon opening its panel, and its controls no longer incorrectly depend
on the unrelated `account_context` capability.

`damage-node-settings-nav.js` and its stylesheet have been removed: the old
client-side navigation injection created a duplicate admin group. The existing
`dashboard-navigation.js` supports the internal tabs and the external Node
settings link via keyboard navigation. Dashboard SSR only renders node panels
for authenticated identities with `node_admin`; existing server-side checks in
`damage_settings_http` and `damage_context` remain mandatory for all requests.

## Apply from repository root

```sh
git apply --check ~/Downloads/damage-unified-node-administration-v2.patch
git apply ~/Downloads/damage-unified-node-administration-v2.patch
rebar3 compile
python3 -m unittest discover -s apps/damage/test/scripts -p test_node_admin_navigation.py
node --test apps/damage/test/scripts/dashboard_navigation.test.mjs
# Optional, requires Playwright and Chromium:
python3 apps/damage/test/scripts/dashboard_navigation_browser_test.py --out /tmp/damage-sidebar
```

The patch is scoped to the original dashboard files plus one new node-context
fragment, a small contract test and this guide. The browser test polls for the
first painted grid layout to avoid a Chromium timing race rather than dropping
its multi-column assertion. It does **not** touch
`sys.config`, `sys.dashboard.config`, account data, wallet settings or
unrelated ECAI changes. No full BEAM toolchain was available here; the
`rebar3` verification is required in the repo checkout.
