# ERM display manager

The implementation deliberately separates three lifetimes:

1. **greetd** owns PAM, account policy and the login handoff.
2. **erm-greeter** is an unprivileged OTP runtime. `erm_dm_greeter_host` owns only the temporary greeter Xorg.
3. **erm-session** is a minimal authenticated OTP runtime. `erm_dm_session_host` owns Xorg + the window manager and publishes the graphical environment to `systemd --user`.
4. Normal **erm.service** is a user service under `graphical-session.target`. It does not own Xorg or the WM.

This gives the required restart invariant: restarting or crashing normal ERM cannot terminate the X session.

## Erlang boundary

All orchestration and diagnostics are Erlang APIs:

- `erm_dm:users/0`
- `erm_dm:sessions/0`
- `erm_dm:select_user/1`
- `erm_dm:select_session/1`
- `erm_dm:login/0`
- `erm_dm:cancel/0`
- `erm_dm:status/0`
- `erm_dm:diagnostics/0`
- `erm_dm:restart_erm/0`
- `erm_dm:logout/0`
- `erm_dm:poweroff/0`
- `erm_dm:reboot/0`
- `erm_dm:suspend/0`

Operational commands use `spawn_executable` with fixed argv. There are no `sh -c` paths and no caller-provided command strings.

## Secret boundary

`erm_greetd_auth` is the only component allowed to see authentication responses. It owns `GREETD_SOCK` and GTK native password/visible prompt widgets. OTP sends only username + validated session id and receives only fixed state tokens such as `state:accepted` or `error:auth_failed`.

Passwords therefore never enter:

- an Erlang term or process mailbox;
- logger metadata;
- gtkgs events / Erlang distribution;
- environment variables;
- argv;
- crash dumps.

The helper disables core dumps and process dumpability and clears response buffers after framing the greetd response.

## Session handoff

On successful `start_session`, greetd does not launch the authenticated command until the greeter terminates. `erm_dm_auth` therefore calls `init:stop(0)` after `state:accepted` when `exit_on_accept=true`.

The authenticated command is fixed in the helper:

```
/usr/lib/erm-session/bin/erm_session foreground
```

Only `ERM_SESSION_ID=<validated-id>` is supplied as selection metadata. The session host independently resolves that id through `erm_dm_sessions`; UI text can never become an executable command.

## X11 lifecycle

`erm_dm_xorg` replaces `startx`/`xinit` scripting. It:

- generates a random MIT-MAGIC-COOKIE through `crypto:strong_rand_bytes/1`;
- creates an Xauthority file under `XDG_RUNTIME_DIR` with mode 0600;
- invokes `xauth` and `Xorg` directly;
- always passes `-nolisten tcp`;
- uses `XDG_VTNR` when supplied by the PAM/logind session;
- waits for `/tmp/.X11-unix/XN` before publishing the display.

The session host then imports DISPLAY/XAUTHORITY and desktop variables using direct `systemctl --user import-environment`, starts `graphical-session.target`, and finally starts the configured WM with `spawn_executable`.

## Packaging

Build the native helper:

```
make -C apps/erm/c_src -f Makefile.dm
```

It requires GTK4 development headers. Install the same ERM sources into three release profiles:

- `erm_greeter`: `greeter.config`
- `erm_session`: `session-host.config`
- normal `erm`: ordinary desktop configuration

Only the release profile differs; the source tree remains unified.

`/etc/greetd/config.toml` can be installed from `packaging/greetd/config.toml`. No custom shell wrapper is required.

## Diagnostics

`erm_dm:diagnostics/0` intentionally reports only presence/state for security-sensitive fields. It never reads Xauthority contents, GREETD_SOCK contents or authentication responses.

Useful checks from an Erlang shell:

```
erm_dm:status().
erm_dm:diagnostics().
erm_dm_session_host:status().
erm_display:status().
```
