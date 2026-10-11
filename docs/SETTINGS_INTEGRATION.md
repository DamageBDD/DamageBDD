# DamageBDD reloadable sys.config and per-app settings

This patch implements a node-admin-only, allowlisted configuration service and three
settings pages. It does **not** expose arbitrary Erlang terms, contract secrets,
private keys, Nostr nsecs, API keys, authentication policies or `node_admins`.

## Files included

| Path | Role |
| --- | --- |
| `apps/damage/src/damage_settings_schema.erl` | Explicit field/type/range/live-vs-restart schema |
| `apps/damage/src/damage_settings.erl` | Watched sys.config, atomic overrides, conflict detection, apply/rollback |
| `apps/damage/src/damage_settings_http.erl` | Admin-protected HTML and JSON routes |
| `apps/damage/priv/static/settings/index.html` | Standalone settings page, three app tabs |
| `apps/damage/priv/static/js/damage-config-editor.js` | Editor with validation, save, reset and reload |
| `apps/damage/priv/static/css/settings.css` | Responsive dashboard-style UI |
| `apps/damage/test/damage_settings*_tests.erl` | Unit and runtime regression tests |
| `apps/damage/src/damage_config.erl` | Adds `system_config_path/0` independently of run config |
| `sys.config.sample` | Documents optional poll/path configuration |

**The active `sys.config` is intentionally not included or modified.** It may
contain deployment secrets and is never returned by the API.

## Three existing source files need manual wiring

The uploaded sources did not include `damage_app.erl`, `damage_sup.erl`, or the
Mustache dashboard shell. The following integration is therefore provided as
exact insertion snippets rather than fabricated Git patch hunks.

### 1. `apps/damage/src/damage_app.erl`

Call the bootstrap immediately before starting the Damage supervisor, after
application configuration is loaded:

```erlang
ok = damage_settings:bootstrap(),
%% Existing start path, e.g. damage_sup:start_link(), follows.
```

Wherever `damage_app.erl` builds its Trails/Cowboy routes, append the new routes
**ahead of any wildcard/fallback route**:

```erlang
ExistingTrails ++ damage_settings_http:trails()
```

If your application uses `trails:store/1`, append at the `trails:store` call;
if it compiles `cowboy_router` routes directly, add the paths using the opts
returned in `damage_settings_http:trails/0`.

### 2. `apps/damage/src/damage_sup.erl`

Start settings under OTP supervision before other Damage children which read
settings:

```erlang
#{
    id => damage_settings,
    start => {damage_settings, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [damage_settings]
}
```

Insert the child map as the first item in the supervisor's children list.
Do **not** start a second settings service directly from the web handler.

### 3. `apps/damage/priv/templates/ui/dashboard/page_shell.mustache`

Place these navigation links under the respective application sections,
using the surrounding nav classes used by your existing shell:

```html
<a href="/dashboard/settings/damage">DamageBDD settings</a>
<a href="/dashboard/settings/ecai">ECAI settings</a>
<a href="/dashboard/settings/nosternity">Nosternity settings</a>
```

The generated standalone settings pages are on the server-side, behind admin
authorisation. They can later be embedded in the existing dashboard shell.
The JS/CSS assets are expected to resolve under `/js/` and `/css/`, consistent
with a `priv/static` mount; change the two references in `index.html` if your
static route uses `/static/js/` and `/static/css/` instead.

## Disk configuration and restart semantics

The runtime service finds the active sys.config in this order:

1. `DAMAGE_SYS_CONFIG` environment variable.
2. `{damage, [{settings_config_path, "/absolute/path/sys.config"}]}`.
3. First non-dashboard `-config` VM argument.
4. `config/sys.config` relative to process working directory.

Dashboard changes are written only to a sibling file named
`sys.dashboard.config` (or the explicitly configured `DAMAGE_SETTINGS_OVERLAY`
or `{settings_overlay_path, "..."}`). This is standard Erlang config syntax,
mode `0600`, and is replaced by an atomic same-directory rename. Existing
operator comments and unmanaged keys in `sys.config` remain untouched.

At runtime both files are monitored on a poll interval of 2000ms by default.
`POST /api/admin/settings/reload` also reloads immediately. If either file is
invalid, the last known good application environment is retained. Changes to
**allowlisted fields** are published with `application:set_env/3` transactionally
(with best-effort rollback on failure); changes to unrelated sys.config keys
must be applied by a normal service restart.

To ensure dashboard overrides are in OTP's application environment **before any
application starts**, add a second `-config` VM argument for the overlay file
once the file exists. This matters particularly for `ecai` and `nosternity`
if OTP starts them before `damage_app`:

```text
-config /etc/damage/sys
-config /etc/damage/sys.dashboard
```

Configure the same paths in the DamageBDD service environment:

```sh
DAMAGE_SYS_CONFIG=/etc/damage/sys.config
DAMAGE_SETTINGS_OVERLAY=/etc/damage/sys.dashboard.config
```

Provision an empty overlay for new installations, **before enabling the second
VM `-config` flag**:

```sh
printf '[].\n' > /tmp/damage-settings-empty.config
sudo install -m 0600 -o damage -g damage /tmp/damage-settings-empty.config /etc/damage/sys.dashboard.config
rm /tmp/damage-settings-empty.config
```

The service OS user needs write permissions on the parent directory to perform
the atomic rename. If `sys.config` is under a root-only directory, configure
`DAMAGE_SETTINGS_OVERLAY` in a separate service-writable private directory,
and use its absolute `-config` path on startup. Never make sys.config or its
parent directory world-writable.

Hot fields (the known request-time environment readers) can take effect
without restart. Fields marked `restart` are published to the application
environment, but existing listeners, workers or caches might have captured the
old value: the UI flags the corresponding app as restart-required. Automatic
application restarts are deliberately **not** performed.

## Routes

| Method | Path | Behaviour |
| --- | --- | --- |
| GET | `/dashboard/settings/damage` | DamageBDD settings page |
| GET | `/dashboard/settings/ecai` | ECAI settings page |
| GET | `/dashboard/settings/nosternity` | Nosternity settings page |
| GET | `/api/admin/settings/{damage,ecai,nosternity}` | Only allowlisted values plus metadata |
| POST | `/api/admin/settings/{damage,ecai,nosternity}` | Save/reset per-app settings |
| GET | `/api/admin/settings/status` | Load status and restart flags |
| POST | `/api/admin/settings/reload` | Force on-disk reload |

All routes require a validated identity via `damage_http:is_authorized/2` and
`steps_utils:is_admin/1`. Mutating requests also require JSON content type and
`X-Damage-Settings-Action: 1`; mismatched Origin values are rejected, and CORS
is not enabled. The API does not accept arbitrary keys, nested Erlang terms,
application names, paths, new atom names, or plaintext Erlang expressions.

### JSON example: inspect, then save

```sh
curl -fsS --cookie "sessionid=$SESSION_ID" \
  'http://127.0.0.1:8080/api/admin/settings/damage'

curl -fsS --cookie "sessionid=$SESSION_ID" \
  -H 'Content-Type: application/json' \
  -H 'X-Damage-Settings-Action: 1' \
  -X POST 'http://127.0.0.1:8080/api/admin/settings/damage' \
  --data '{"action":"save","version":"REPLACE_WITH_GET_VERSION", "changes":{"ae_fee_multiplier":4}}'
```

The version is a SHA-256 digest of both config files. If another admin changes
a value, the server returns `409 config_changed` rather than overwriting it.
Resetting an override from the UI returns the effective field to `sys.config`.

## Verification

```sh
rebar3 compile
rebar3 eunit --module=damage_settings_schema_tests
rebar3 eunit --module=damage_settings_tests

# After integrating the three missing host sources:
# 1. Confirm each settings URL is 403 to non-admin accounts.
# 2. Confirm dashboard saves do not change sys.config.
# 3. Confirm changes to source sys.config take effect for hot fields.
# 4. Verify invalid config leaves the old values running.
# 5. Confirm the overlay is 0600 and restart flags are shown.
# 6. Restart node and verify overlay values load before app supervisors.
```

An OTP compiler and complete monorepo are not available in the artifact
workspace; syntax and runtime tests must be executed in your checkout.
