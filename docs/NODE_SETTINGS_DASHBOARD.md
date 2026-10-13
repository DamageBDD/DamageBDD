# Node administration: settings section

The **Node administration → Node settings** section is separate from any account
settings or wallet preferences. It configures this DamageBDD node's allowlisted
application environment for `damage`, `ecai`, and `nosternity` through the
previously installed reloadable settings service.

## Routes and permissions

| URL | Purpose | Required role |
| --- | --- | --- |
| `/dashboard/node/settings` | Open node settings (DamageBDD tab) | `node_admin` |
| `/dashboard/node/settings/damage` | DamageBDD configuration | `node_admin` |
| `/dashboard/node/settings/ecai` | ECAI configuration | `node_admin` |
| `/dashboard/node/settings/nosternity` | Nosternity configuration | `node_admin` |
| `/api/admin/settings/{damage,ecai,nosternity}` | Read/write per-app fields | `node_admin` |
| `/api/admin/settings/status` | Admin-only navigation check and status | `node_admin` |
| `/api/admin/settings/reload` | Explicit reload | `node_admin` |

The previous ambiguous `/dashboard/settings/{app}` pages are replaced by
`/dashboard/node/settings/{app}`. Existing account-settings routes and templates
are not modified. The `damage_settings_http` handler verifies a valid session
and calls `steps_utils:is_admin(PublicKey)` for **each** page/API request.
Hiding navigation is not relied upon for authorization.

The dashboard's shared page shell loads the small
`/static/js/damage-node-settings-nav.js` script. It verifies the node-admin
role through the protected `/api/admin/settings/status` endpoint and only then
creates a **separate** "Node administration" sidebar group. It does not add a
visible admin link for non-admins. It rechecks on browser focus and on the
`damage:auth-changed` event; existing account settings are untouched.

## Installation after the settings v2 patch

Run from the repository root:

```sh
git apply --check ~/Downloads/damage-node-settings-dashboard.patch
git apply ~/Downloads/damage-node-settings-dashboard.patch

# Inspect proposed changes to the THREE existing host files (no writes):
python3 scripts/integrate_damage_node_settings.py --check
# Wire supervisor, Trails and dashboard navigation once you have reviewed them:
python3 scripts/integrate_damage_node_settings.py --apply

rebar3 compile
rebar3 eunit --module=damage_settings_schema_tests
rebar3 eunit --module=damage_settings_tests
python3 -m unittest discover -s test/scripts -p 'test_integrate_damage_node_settings.py'
node --test test/scripts/node-settings-nav.test.mjs
```

The host integration script exists because the live versions of
`damage_app.erl`, `damage_sup.erl`, and `page_shell.mustache` were not in the
uploaded source set. It validates every change before writing and refuses
unexpected layout instead of overwriting newer dashboard changes. Run it
**after** applying the settings v2 patch. Do not apply the original v1 patch.

It adds:

- `damage_settings:bootstrap()` before `damage_sup:start_link()`;
- `damage_settings_http` to the HTTP handler list before `damage_dashboard`;
- `damage_settings` as the first supervised worker in `Core`/`Children`;
- the nav script in the existing dashboard shell before `</body>`.

The active `sys.config`, account settings, `settings.js`, wallet handlers, and
existing unrelated ECAI changes are not modified by this patch or the script.
The configuration service uses a separate, private `sys.dashboard.config`
overlay; see `docs/SETTINGS_INTEGRATION.md` for production `-config` ordering.

## Verification checks

1. As a regular user, load `/dashboard` and confirm the Node administration
   link is absent; direct GET on `/dashboard/node/settings` and
   `/api/admin/settings/status` must return **403**.
2. As a valid `node_admin`, reload `/dashboard` and confirm a distinct sidebar
   group with **Node settings** appears, without replacing Account settings.
3. Visit all three tabs, change an allowlisted value, then reload the page.
4. Confirm `sys.config` has not been rewritten and the overlay has mode `0600`.
5. Log out, focus the dashboard tab, and confirm the link disappears and direct
   page/API requests are denied.
6. Restart the node and confirm the overlay is loaded before dependent workers.

**Security:** The node-admin check remains server-side even when the browser
link is hidden. No secrets, `node_admins`, arbitrary terms, or account settings
are exposed through this service.
