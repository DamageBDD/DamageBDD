# Nosternity durable storage

Relay events and dashboard accounts now share a storage resolver. By default:

| Store | Resolved path |
| --- | --- |
| Relay events and deletion tombstones | `<damage.state_dir>/dets/nosternity/search.dets` |
| Accounts and preferences (plus admin settings/branding when installed) | `<damage.state_dir>/dets/nosternity/accounts.dets` |

The shared root comes from `damage_config:state_dir()`: `damage.state_dir`, then
the compatibility setting `damage.secrets_state_dir`, then absolute
`$XDG_STATE_HOME/damage`, then `$HOME/.local/state/damage`. Without a home
directory the fallback is `/var/lib/damage`. `damage.data_dir` and `runs_dir`
do not control Nosternity's durable stores.

`nosternity.data_dir` overrides the Nosternity directory. `search_store_file`
and `auth_store_file` override their individual files. Paths accept strings or
UTF-8 binaries; `~` and `~/` use the BEAM service account's home. Relative
overrides retain their working-directory meaning and resolve to absolute paths.
Empty, malformed UTF-8 and NUL-containing paths are rejected.

Older release configurations explicitly set
`{search_store_file, "data/nosternity/search.dets"}` explicitly. **Remove that
entry** to inherit the state directory. The separately supplied updated `sys.config`
and `sys.config.sample` remove it; this source archive contains only example
configs, so merge this change into your deployed config too. To override the root, use this entry inside
the existing `nosternity` application block:

```erlang
{data_dir, "~/.local/state/damage/dets/nosternity"}
```

Usually omit this override too, so changing `damage.state_dir` changes both
store defaults consistently. Explicit file overrides always take precedence.

## Initialization and permission failures

Before opening each DETS table, Nosternity recursively creates its parent
directory and checks that the service process can create and remove a file
there. DETS may require directory writes during repair/compaction even when an
existing database itself is writable. Successful opens are logged with their
absolute paths; both database files are restricted to mode `0600`.

Failures stop startup with `nosternity_store_unavailable`, the configuration
key, absolute file/directory, operation and underlying error (`eacces`,
`erofs`, a corrupt DETS file, etc.). Relay replay/index initialization failures
close the DETS table before returning a path-bearing startup error. Accounts
retain `repair=false`; relay events retain the existing `repair=true` policy.

An `eacces` error still requires the host's service account to have traversal
and write access to its chosen state directory and ownership/access to existing
database files. Provision that directory for the actual service account if
needed. Changing a development user's home or running the service as root is
not a directory migration. No deployment ownership is changed automatically.

## Existing databases

Stop Nosternity before copying or moving DETS files. Back up and preserve both
`search.dets` (including deletion tombstones) and `accounts.dets` (including any stored
preferences or settings). Move them to the resolved target directory, retaining service-user
ownership and mode `0600`, then restart.

When using a default file path, startup detects an existing
`<working-directory>/data/nosternity/<filename>` if the new target is absent
and stops with `legacy_store_requires_migration`. An existing new-layout
database takes precedence. The check cannot discover databases from a different
old working directory or custom path; migrate those explicitly. Alternatively,
keep explicit absolute per-file overrides pointing at the original databases.
No database is silently moved, deleted or replaced with a temporary store.

## Applying and checking the patch

This patch is rebased directly onto `latest-nosternity.tar(4).gz`. It needs
no earlier Nosternity settings or storage patch, and preserves the archive's
operator branding and OTP compatibility code. It includes the storage fix
only; dashboard admin/account settings remain a separate feature patch.
Apply from the Damage umbrella repository root:

```sh
git apply --check nosternity-storage-init-v4.patch
git apply nosternity-storage-init-v4.patch
bash apps/nosternity/test/storage/run.sh
```

The storage suite compiles with warnings as errors and uses real DETS and
filesystem calls. Run it as a user without root DAC override privileges so
read-only test directories actually return `eacces`. It covers path precedence,
tilde/UTF-8 paths, validation, recursive creation, restart persistence, migration
guards, corrupt stores, failed replay cleanup and permission failures. The
account worker is also started and restarted against the default path. The
suite runs the existing branding configuration tests to verify the
rebased configuration keeps text, URL and color normalization intact.

Build/redeploy the updated application and use the corrected configuration at
the deployment's existing config location. The source patch itself does not
include private `sys.config` contents. The full native ECAI/umbrella startup
still needs validation on the target node.
