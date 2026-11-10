# Separate userspace ERM service

This change adds a separate `erm_user` OTP entry point in the existing umbrella.
Damage continues as the system service. The user entry loads ERM's compiled
code and starts a constrained desktop supervisor; it does not start the Damage
or ECAI applications, read their service configuration, or share their Erlang
cookie. Production Damage now loads ERM code without starting the desktop app.

The current nested tmux launcher, arguments and socket conventions are unchanged.
This patch does not migrate tmux orchestration or forward existing direct
Damage/ECAI calls automatically.

## Apply and build

Apply from the complete DamageBDD repository, after reviewing local changes:

```sh
git apply --check erm-userspace-service.patch
git apply erm-userspace-service.patch

# Existing system release/package build remains available.
rebar3 as prod release

# New isolated desktop release and optional archive.
apps/erm/packaging/userspace/build.sh release
apps/erm/packaging/userspace/build.sh tar
```

The desktop build helper is required. It selects a separate `prod+erm_user`
profile and removes the legacy ERM -> Damage application dependency from the
**generated** ERM application resource before relx resolves the desktop release.
The ordinary source application resource and ordinary build retain their legacy
contract. A build guard and a generated-boot allowlist reject unintended service
startup in the desktop release.

Native GTK/X11/voice prerequisites still belong to the complete repository's
build. The patch introduces no Python runtime dependency.

## Install the desktop release

```sh
sudo _build/prod+erm_user/rel/erm_user/share/erm-user/install.sh
systemctl --user daemon-reload
systemctl --user enable erm-user.service
```

The installer copies the built release to `/opt/erm-user` and installs
`/usr/lib/systemd/user/erm-user.service`. It does not enable other accounts or
start services automatically. If an earlier user `erm.service` is enabled,
review and disable that older desktop unit before enabling this replacement.

At login, the X session owner must validate and import `DISPLAY`, `XAUTHORITY`,
`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` before starting
`graphical-session.target`; it must stop that target on logout. The recovered
ERM session host already publishes context and starts the target, though its
WM readiness sequencing remains a separate improvement. A herbstluftwm reload
must not launch another ERM VM.

The new user runtime starts the existing HLWM monitor independently of wx.
Media, speech, GTK, Lens and Share are disabled by default and can be configured
per user. The user entry always disables the embedded HTTP listener and the
login/display-manager host. Local components that call Damage/ECAI directly
require a dedicated bridge capability before being enabled remotely.

## Enable the Damage bridge

Update the canonical Damage system unit from this patch (included by the
existing package build). It creates `/run/damage-erm` as the service account,
mode 0755, outside the service's private temporary directory. The package
prepares an empty `/etc/damage/erm-users.config`, owned root:damage, mode 0640.
Existing grants are preserved on upgrades.

Merge the entry from `apps/damage/priv/config/erm_bridge.example.config` into
the existing Damage configuration, preserving its other options:

```erlang
{erm_bridge, #{
    enabled => true,
    socket => "/run/damage-erm/bridge.sock",
    grants_file => "/etc/damage/erm-users.config",
    max_clients => 8,
    request_timeout_ms => 3000
}}
```

The bridge is disabled until explicitly configured. After installing the updated
Damage release and unit, reload the system manager and restart Damage during
your normal deployment:

```sh
sudo systemctl daemon-reload
sudo systemctl restart damage.service
```

A source-only/manual installation must create the empty grants registry in an
administrator-owned directory before enabling the bridge. Do not overwrite an
existing grants file.

## Authorize each desktop user

Run as the desktop user:

```sh
/opt/erm-user/bin/erm-user credentials
```

This creates a 0600 token under `$XDG_CONFIG_HOME/erm/damage.token`, defaulting to
`~/.config/erm/damage.token`, and prints only its SHA-256 digest. Repeating it
returns the existing private token's digest. The bearer token stays with the user.

The Damage administrator authorizes the printed digest:

```sh
sudo /opt/damage/bin/erm-bridge-grant \
  --id steven \
  --sha256 REPLACE_WITH_PRINTED_64_CHARACTER_DIGEST \
  --gid "$(id -g damage)" \
  --ops ping,status,capabilities
```

Use a distinct credential for each user. The grants registry stores only hashes.
The digest is SHA-256 of the 64 ASCII hexadecimal token characters, excluding
any final newline. Replacing a grant updates that principal without deleting
other users; duplicate digests and concurrent writers are rejected.

Remove a user's entry from the protected grants file to revoke access. Every
request rereads the registry, so revocation requires no service restart. Rotate
by moving aside the user's token, generating a new one and replacing their grant.
The provisioning tool takes a short directory lock; inspect any lock left by a
crashed provisioner before removing it.

## User configuration and API

`~/.config/erm/user.config` may contain settings only for `erm` and `erm_user`.
Files must be owned by the user and not writable by group/others. Defaults are
in `config/erm-user.sys.config`. For a nonstandard Damage service account, set
`bridge_server_user` to that local account or `bridge_server_uid` to its UID.
The client validates the socket and trusted filesystem ancestry before sending
its token.

In the user's ERM VM:

```erlang
erm_user_bridge:status().
erm_user_bridge:request(ping).
erm_user_bridge:request(status).
erm_user_bridge:request(capabilities).
```

The initial protocol is intentionally read-only: connectivity, minimal service
status, and the caller's granted operations. It does not expose remote evaluation,
arbitrary module calls, shell execution, wallets, configuration edits or feature
execution. New operations need explicit schemas and server-side authorization.

The bridge uses a local Unix socket, versioned JSON and 4-byte length framing.
Frames are capped at 64 KiB; acceptors and client jobs are bounded; reads and
writes time out. Invalid messages cannot execute Erlang terms or create atoms.
Damage outages leave the user's ERM runtime running with bounded reconnects.

GTK's existing native C-node requires optional local Erlang distribution.
Enabling `local_distribution` uses a fresh private cookie home and a loopback
listener for that user's C-node. This is separate from bridge authentication;
no Damage cookie is copied or accepted.

```sh
systemctl --user start erm-user.service
/opt/erm-user/bin/erm-user check
journalctl --user -u erm-user.service -f
```

The fixed `check` action opens a fresh, non-distributed client VM, reads only
the user configuration and tests the authorized status operation. It provides
a host check without a remote shell or arbitrary evaluation.

Systemd owns the foreground VM. Persistent tmux servers should have their own
user-service lifetime so stopping ERM does not kill their panes.

## Validation and source scope

The implementation uses the supplied November 6 Damage/ECAI archives and
`rebar(8).config`. The ERM edits are based on the recovered October 23 ERM
snapshot; only small changes to its supervisor and a new application-resource
script are supplied, avoiding replacement of newer ERM features.

All 51 isolated automated tests pass: 35 EUnit protocol/configuration tests,
7 grant-write tests and 9 launcher tests. Production modules compile with
`-Werror`, and test-only protocol exports are absent from the production build.
Real Rebar/relx fixture builds also validate the release mechanism.

Run the isolated suite after the normal build has compiled JSX:

```sh
JSX_EBIN="$PWD/_build/default/lib/jsx/ebin" \
  apps/damage/scripts/test_erm_userspace.sh
```
The fixture boots the separate userspace entry without starting Damage.
The full production/native release cannot be assembled from these partial
archives alone: the complete repository and native build dependencies remain
required. This environment denies AF_UNIX socket creation and has no live X
session/systemd user manager, so Unix-socket and desktop/service startup need
host validation. Production has no TCP fallback.
