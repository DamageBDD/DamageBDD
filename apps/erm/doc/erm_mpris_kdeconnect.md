# ERM MPV: KDE Connect / MPRIS2 integration

ERM's managed MPV remains the only playback owner. `erm_mpv_proc` speaks MPV JSON
IPC; the `mpv-mpris` native C plugin speaks the standard MPRIS2 D-Bus interfaces:

- `org.mpris.MediaPlayer2`
- `org.mpris.MediaPlayer2.Player`

It handles playback/pause, next/previous, seek, position, volume, metadata and
change notifications directly from MPV events. Next/previous are available
when tracks are present in MPV's **own** playlist; an Erlang-only ERM queue
that is not mirrored into MPV will not appear as MPRIS tracks. No duplicate
polling/player state machine is introduced into Erlang. New instances appear in KDE Connect as
**ERM** (MPRIS bus names begin `org.mpris.MediaPlayer2.mpv.ERM.instance-`).

## Installation (Arch Linux)

```sh
sudo pacman -S mpv-mpris playerctl kdeconnect
```

The package installs `/etc/mpv/scripts/mpris.so`; MPV auto-loads it. The
`erm_mpris` module checks this location and the active user MPV config directory
before falling back to `/usr/lib/mpv-mpris/mpris.so` via `--script=...`. The
fallback is never used if an auto-load copy already exists, preventing duplicate
D-Bus names / multiple plugin initializations.

For a custom install without either default location, set the **absolute**
`MPV_MPRIS_SCRIPT=/path/to/mpris.so` for ERM's OS process before starting MPV.
Do not specify it if another copy is already auto-loaded.

## Session identity: the critical requirement

KDE Connect discovers MPRIS services on the **logged-in desktop user's session
bus**. Running MPV as a system `damage` account publishes it on the wrong bus,
or fails to acquire a session bus entirely, even if audio output works.

Run the MPV/ERM media component in a `systemd --user` service belonging to the
same account as `kdeconnectd` (a user-level ERM package is the recommended model).
Keep any privileged DamageBDD daemon in a separate service. Do **not** grant the
system daemon blanket access to another user's D-Bus or chmod MPV's IPC socket
world-writable. Avoid `dbus-run-session` here: it creates a separate bus that
KDE Connect does not discover.

A normal user service inherits `XDG_RUNTIME_DIR` and the user's session bus. If
ERM is launched from a custom X11 session/tmux, verify that its environment
contains the correct `DBUS_SESSION_BUS_ADDRESS` or `XDG_RUNTIME_DIR` before
starting the MPV subprocess.

## Apply and compile

```sh
rebar3 compile
rebar3 eunit --module=erm_mpris_tests
```

From an Erlang shell (note that these queries do **not** restart MPV):

```erlang
erm_mpris:status().
erm_mpv_proc:status().
```

`status()` reports plugin selection and a session-bus hint, but **not** proof
that D-Bus registration succeeded. On the **desktop user** shell:

```sh
playerctl --list-all
busctl --user --no-pager list | grep 'org.mpris.MediaPlayer2.mpv'
```

Choose the name reported by `playerctl --list-all` and test:

```sh
playerctl -p 'mpv.ERM.instance-XXXXXXXX' metadata title
playerctl -p 'mpv.ERM.instance-XXXXXXXX' play-pause
```

(The instance suffix is assigned dynamically; replace the example with the
actual value.) Open KDE Connect on the phone and select **Multimedia Control**.

## Existing detached MPV processes

The default `MPV_SURVIVE_BEAM` path deliberately leaves MPV alive through ERM
restarts. If MPV started *before* the MPRIS plugin was installed, restarting the
Erlang application does not load the new plugin into that already-running MPV.
When it is acceptable to interrupt playback, explicitly call:

```erlang
erm_mpv_proc:restart().
```

Normal app restarts/recompiles should **not** invoke this call. Future MPV
instances will load MPRIS at startup; their D-Bus ownership remains alive as
long as the OS MPV process does.

## Troubleshooting

- No `playerctl` entry: check package installation, MPV ownership with
  `ps -o user= -p <mpv-pid>`, and whether `kdeconnectd` uses the same account.
- `session_bus => not_configured`: start ERM from a desktop user session, not a
  system-level service. Also inspect the detached MPV process's environment.
- Installed plugin but no media entry: check detached MPV logs, and make sure it
  was restarted *once* after installation. No EUnit test can certify a running
  session bus; test live behavior using `playerctl`/KDE Connect.
- Duplicate players: remove an extra `mpris.so` copy from custom scripts dirs.

References:
- https://github.com/hoyon/mpv-mpris
- https://specifications.freedesktop.org/mpris/latest/
- https://community.kde.org/KDEConnect
