# Node administration: persistent XDG configuration

The **Node administration → Node settings** dashboard (all five apps and all feature groups) saves only `damage_settings_schema`-approved values to a separate XDG configuration file. It does **not** rewrite the operator-managed Erlang VM `-config` file or user account settings.

| Node | Operator startup config | Dashboard-managed, writable config |
| --- | --- | --- |
| Packaged Linux systemd | `/etc/damage/damage.config` | `/var/lib/damage/.config/damage/damage.config` |
| Desktop/dev | `config/sys.config` or explicit `-config` | `$XDG_CONFIG_HOME/damage/damage.config`, otherwise `$HOME/.config/damage/damage.config` |
| No `HOME` or XDG config env | as configured | `/var/lib/damage/.config/damage/damage.config` |

These are different files, even where they share the name `damage.config`. The XDG config is a **dashboard override**; Erlang reads the operator's startup config normally. The settings service validates and applies only allowlisted entries in the override, with restart-required changes reported in the dashboard. Arbitrary settings, signing identities, credentials, node-admin allowlists, and other sensitive entries cannot be written via this endpoint.

**Precedence:** `DAMAGE_CONFIG_FILE` (absolute recommended) > legacy `DAMAGE_SETTINGS_OVERLAY` > `damage.settings_overlay_path` > the XDG default above. Relative `XDG_CONFIG_HOME` is ignored in favour of `$HOME/.config`. The `DAMAGE_SYS_CONFIG` variable or the Erlang `-config` argument continues to identify the *operator* file.

The Linux package scripts ignore any `HOME`, `XDG_CONFIG_HOME` or `DAMAGE_CONFIG_FILE` inherited from the package installer, always provisioning the XDG location for the `damage` systemd service user. Set an explicit service override only when deploying a custom service and corresponding config directory.

New packages initialize the XDG file **before** starting the node. The post-install hook creates a mode `0700` directory and a mode `0600` file owned by the `damage` service user; it **never overwrites** a previously created `damage.config`. First startup in non-packaged/dev mode also initializes the file when absent. An old `sys.dashboard.config` beside the operator startup config is migrated only when the XDG file is absent, and remains untouched after migration. The package post-install hook imports a legacy overlay before creating the new file; the Erlang loader rejects invalid legacy syntax or fields rather than ignoring them.

The managed config is an Erlang application list of **tuple proplists**, not a JSON file. The initialized file contains empty entries (defaults continue to come from `sys.config` and application env):

```erlang
[
    {damage, []},
    {ecai, []},
    {nosternity, []},
    {erm, []},
    {bop, []}
].
```

Each save is type/range-checked, checks the effective configuration for incompatible combinations, writes to a restrictive temporary file, fsyncs and atomically renames it, and then reloads effective settings. `config_file` is shown in the node-admin-only dashboard response so operators can confirm the exact destination. An incompatible concurrent browser/disk edit results in `409 config_changed` and must be reloaded before retry.

## Verify

```sh
rebar3 compile
rebar3 eunit --module=damage_settings_tests
rebar3 eunit --module=damage_settings_schema_tests
python3 -m unittest apps/damage/test/scripts/test_node_config_package.py
sh -n apps/damage/priv/pkg/postinst.d/10-setup-users.sh
sh -n apps/damage/priv/pkg/postinst.d/20-systemd.sh
```

> On a production upgrade, preserve backups of `/etc/damage/damage.config`, the old adjacent `*.dashboard.config` (if present), and the new XDG `damage.config`. The new file contains node-wide settings, **not** account preferences.
