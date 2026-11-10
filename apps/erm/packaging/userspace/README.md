# ERM userspace release

The repository produces two independent OTP entry points. Damage remains the
system service. `erm_user` is the per-user desktop runtime and reuses the compiled
ERM modules without starting the Damage application locally.

Build the desktop release from the complete repository:

```sh
apps/erm/packaging/userspace/build.sh release
apps/erm/packaging/userspace/build.sh tar
```

The native build prerequisites remain the same as for the existing repository.
The optional `ERM_NATIVE_VOICE=0` setting skips the existing native voice build
when the corresponding speech SDKs are unavailable. This setting is unrelated
to bridge authentication.

The helper sets `ERM_USERSPACE_BUILD=1` for the isolated `prod+erm_user`
profile. `erm.app.src.script` removes the system Damage dependency from the
generated ERM `.app` resource before release dependency resolution. The ordinary
ERM `.app.src` and ordinary builds retain their existing dependency contract.
A pre-release guard rejects invocation of the userspace profile without the
helper's explicit build context. A post-release verifier inspects the actual
`.script` and allows only approved desktop/library applications to start; it
rejects accidental transitive system-service dependencies. The separate
`erm_user` application owns the constrained desktop supervisor.

Install the built release:

```sh
sudo _build/prod+erm_user/rel/erm_user/share/erm-user/install.sh
```

This copies the release to `/opt/erm-user` and installs the vendor unit at
`/usr/lib/systemd/user/erm-user.service`. It does not start a service, enable it
for every account or create access grants. Existing root/system Damage unit
settings are not changed.

As each desktop user, enable the unit once:

```sh
systemctl --user daemon-reload
systemctl --user enable erm-user.service
```

If a previous `erm.service` desktop unit is enabled, review it and disable it
before switching to `erm-user.service`; running both starts two desktop runtimes.
The installer leaves legacy units untouched.

After X login, the session owner must validate and publish `DISPLAY`,
`XAUTHORITY`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` before starting
`graphical-session.target`. The existing ERM session host already publishes the
session context and starts that target. For another X session manager, make the
same handoff from its login/session entry, and stop the target on session exit.
Do not start the target at machine boot or from every new shell.

Normal service control and logs use the user's manager:

```sh
systemctl --user start erm-user.service
systemctl --user status erm-user.service
journalctl --user -u erm-user.service -f
```

`bin/erm-user` provides the foreground service and fixed `credentials` and
`check` actions. It directly
boots the generated `start.boot` using the bundled ERTS. It clears inherited
VM flags and does not assign a distributed node name or Damage cookie. Relx's
generated `bin/erm_user` extended script requires distribution options; the
service never uses that script. This separation also avoids writing generated
configs, cookie files or release logs into the root-owned release directory.
The launcher bootstraps OTP with a fresh private home beneath the user
service's runtime directory. At the earliest application entry the runtime
restores the actual desktop `HOME` before reading user configuration or starting
workers; OTP's captured home remains private. Optional GTK distribution can
therefore initialize its own cookie without ever consulting the user's shared
`.erlang.cookie`.

The runtime reads the desktop user's `$XDG_CONFIG_HOME/erm/user.config` (default
`~/.config/erm/user.config`) and its own token file. It never reads the system
Damage startup config or Damage service account's XDG directory. Journal logging
and per-user XDG state keep desktop writes outside `/opt/erm-user`.

Damage communication uses the authenticated local bridge at
`/run/damage-erm/bridge.sock`. The default trusted service account is `damage`;
nonstandard installations must configure the correct service identity. Create
and authorize a separate per-user token before testing bridge calls:

```sh
/opt/erm-user/bin/erm-user credentials
```

This stores a private token in the user's config directory and prints only its
SHA-256 digest. Give the digest to the Damage administrator, who uses the shipped
`erm-bridge-grant` tool and bridge example config to authorize that principal.
Never copy the bearer token or either Erlang cookie to Damage. A running GUI alone grants no Damage
access. Bridge provisioning and allowed operations are described by the parent
ERM userspace integration documentation and the shipped bridge example config.

After the administrator grants this user's digest and enables the Damage
bridge, verify authorization from that desktop user's account:

```sh
/opt/erm-user/bin/erm-user check
```

This performs the fixed authenticated bridge status check in a fresh local VM
and exits with status 0 on success or 1 on failure. It does not open a remote
console, evaluate arbitrary code or disclose the token. The same socket-owner
and credential-file checks used by the running service apply.

GTK's existing local C-node uses Erlang distribution internally. GTK is disabled
by default in this userspace configuration. Enabling it requires the explicit
`local_distribution` option, which initializes a private local node; that cookie
must never be shared with Damage. Legacy modules which directly call Damage or
ECAI APIs are not made remote automatically; expose each required capability
through the bridge before enabling such a component.

The user service has its own process group and uses normal group termination.
Tmux servers requiring survival across ERM restarts must be owned by separate
user services; they must not be spawned as persistent descendants of this unit.
This build change does not rewrite existing nested tmux invocations.
