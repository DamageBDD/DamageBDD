# Node settings: feature grouping and discovery

Scope: five uploaded OTP application source snapshots plus the supplied `sys.config` and `sys.config.sample`. **Only configuration names and source references** are inventoried; no values, credentials or plaintext secrets are extracted or published.

The catalog is a static snapshot, not an assertion that every key is currently active or safe to modify. Four original dashboard-allowlisted keys have no direct source/config reference in these snapshots and are retained for compatibility; they should be reviewed for obsolete behavior. Computed keys and external environment variables may not be captured by the static scanner. Re-run the discovery script after adding new apps or config consumers.

## Coverage

| OTP application | Names discovered | Editable, validated | Names-only, not editable |
|---|---:|---:|---:|
| DamageBDD (`damage`) | 237 | 36 | 201 |
| ECAI (`ecai`) | 199 | 42 | 157 |
| Nosternity (`nosternity`) | 50 | 36 | 14 |
| ERM (`erm`) | 39 | 10 | 29 |
| BOP (`bop`) | 5 | 1 | 4 |

**Total: 530 inventoried settings; 125 explicitly typed, editable controls.**

## Feature-first dashboard

Node administration → Node settings → app tab → feature group → settings. The existing account settings and node context navigation are untouched.

- **DamageBDD:** BDD & execution; Aeternity & contracts; Lightning & payments; Nostr & identities; IPFS, Blossom & NIP-96; builds & releases; integrations & messaging; HTTP & network; observability & lifecycle; security & access policies.
- **ECAI:** indexing & ingestion; code learning & repair; models & inference; chat & retrieval; content & publishing; marketplace & rewards; HTTP & node services; security & permissions.
- **Nosternity:** listeners & connections; relays & subscriptions; search & LLM; Aeternity event store; identity & authentication.
- **ERM:** node services; display & GTK; media & playback; voice & TTS; lens, maps & anatomy; logging & diagnostics.
- **BOP:** HTTP & node services; Nostr & identity.

Every feature section shows editable typed controls and a collapsible **Other discovered configuration** listing names and restrictions. These read-only entries carry no runtime values and cannot be submitted to the save endpoint.

## Security and reload behaviour

- Authorization remains on `damage_settings_http` via `damage_http:is_authorized/2` and `steps_utils:is_admin/1`; no account user can access node settings.
- Editing is limited to `damage_settings_schema:fields/1`. Catalog membership never grants read-value or write access.
- Secrets, signing materials, admin allowlists, execution commands, nested unvalidated maps and private policies are not editable and their values are never rendered.
- Controls are tagged **Live** only where the implementation reads runtime application environment. All other changes are **Restart** (no automatic service restart).
- The dashboard persists approved changes in **`$XDG_CONFIG_HOME/damage/damage.config`** (fallback `$HOME/.config/damage/damage.config`; packaged service: `/var/lib/damage/.config/damage/damage.config`). The operator-managed `-config` file remains read-only. An explicit `DAMAGE_CONFIG_FILE` or legacy `DAMAGE_SETTINGS_OVERLAY` / `settings_overlay_path` override takes precedence.
- An existing adjacent `sys.dashboard.config` is imported once into the XDG file on first launch (only if the new file is absent), after the same schema/combination checks. The legacy file is preserved. Future edits target the XDG file.
- First launch also creates an empty secure `damage.config` in the XDG directory when none exists; package post-install initializes it before service startup. Files use 0600 permissions and the application directory is 0700. The file contains allowlisted Erlang tuple proplists, not arbitrary application settings.
- There are two files called `damage.config` on packaged Linux nodes: `/etc/damage/damage.config` is the operator-managed VM startup config, while the XDG path is the node-admin dashboard overlay. Do not edit or symlink either to the other.
- Nosternity numeric bounds now mirror `nosternity_config.erl`, and search default/max combinations are rejected before persistence.

## Inventory regeneration

```sh
python3 apps/damage/scripts/discover_node_settings.py --report /tmp/node-settings-evidence.csv
```
To also include an external live configuration file, pass `--config /path/to/sys.config`. The script reads keys only, not values, and writes `apps/damage/priv/config/node-settings-catalog.json`.

## Validate

```sh
git apply --check ~/Downloads/damage-node-settings-by-feature.patch
git apply ~/Downloads/damage-node-settings-by-feature.patch
rebar3 compile
rebar3 eunit --module=damage_settings_schema_tests
rebar3 eunit --module=damage_settings_tests
python3 -m unittest apps/damage/test/scripts/test_node_settings_feature_browser.py
node --check apps/damage/priv/static/js/damage-config-editor.js
```

A full Erlang toolchain was not available for independent compilation in the patch-building environment. Browser fixture tests cover UI grouping/search without bypassing server authorization, but real HTTP authorization must be checked in the deployed node.
