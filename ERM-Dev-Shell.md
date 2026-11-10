# Native Rebar ERM profile

The ERM development shell uses native Rebar configuration:

```sh
# Damage development environment
rebar3 shell

# ERM development environment, in another terminal
rebar3 as erm shell
```

Both commands use the same source checkout. The ordinary shell uses
`_build/default`; the ERM profile uses `_build/erm`. ERM needs no launcher,
environment flags, development startup script or profile-specific compile hook.
The standard repository build hooks and native prerequisites still apply.

The `erm` profile is:

```erlang
{erm, [
    {shell, [
        {apps, [erm_user]},
        {config, "config/erm-user.sys.config"},
        {script_file, "none"}
    ]}
]}
```

The string `"none"` explicitly suppresses the inherited Damage dev script.
Omitting the key inherits that script; atom `none` and `undefined` are not the
supported skip values.

`erm_user` starts the constrained ERM supervisor directly. Its own dependency
list contains libraries, not the legacy `erm` application. Loading `erm`'s
metadata makes its code available without starting its application dependencies.
The shell therefore requires no metadata rewrite or `ERM_USERSPACE_BUILD` flag.
The separately packaged release still has its existing release build mechanism.

The default Damage startup list still excludes `erm`. Its existing development
marker continues to suppress legacy ERM workers/HTTP if configuration is reloaded.
That script belongs to the default Damage environment and is not run by the ERM
profile.

If the installed `erm-user.service` is running, stop it before starting the ERM
dev shell to avoid duplicate desktop workers:

```sh
systemctl --user stop erm-user.service
```

## Development workflow

Inside the ERM shell:

```erlang
application:which_applications().
whereis(erm_user_sup).
erm_user_bridge:status().
erm_user_bridge:request(status).
r3:compile().
l(erm_mpv).
```

From another terminal, the same profile can compile without any bootstrap flags:

```sh
rebar3 as erm compile
```

Reload changed modules in the running shell with `l(Module).`. Restart the shell
for supervisor/application startup changes. ERM reads its own user configuration
and independently authorized Damage bridge credential as before.

## Native GTK transport

The plain profile starts non-distributed. Its userspace supervisor and local
Damage bridge work without a distributed node or shared Erlang cookie.

The existing optional GTK C-node transport still requires the separately
isolated distribution bootstrap supplied by the installed userspace service.
This change does not weaken that cookie isolation or enable GTK automatically.
If user configuration enables `local_distribution` for the plain dev shell, the
current application will reject startup without the isolated cookie context;
leave it false for this profile. A future native transport change is needed to
remove that existing GTK bootstrap requirement entirely. Media/voice retain
their individual configuration/prerequisites.

## Apply

`erm-pure-rebar-profile.patch` applies after both earlier patches:
`erm-userspace-service.patch` and `erm-dev-shell.patch`. It replaces the `erm_dev`
profile with `erm` and removes the superseded development helpers and their tests.

The profile was checked using real Rebar3 3.23.0, including startup applications,
profile config, inherited-script suppression, unchanged legacy dependency
metadata, and native recompilation with no helper environment.
Full native builds and live X11/Unix-socket operation remain host checks.
