# Native ERM development shell

Run from the same source checkout:

```sh
rebar3 as erm shell
```

The native `erm` profile selects `erm_user`, its own configuration and
`{script_file,"none"}`. No development launcher or bootstrap script is required.
Use `rebar3 shell` for the separate default Damage environment.

Both shells compile the same source; the ERM profile writes `_build/erm`.
Inside the ERM shell, use `r3:compile().` and `l(Module).` after changes.
External recompilation uses `rebar3 as erm compile`, without environment flags.

The default profile is non-distributed. The existing optional native GTK C-node
still needs the isolated cookie context of the userspace service; keep
`local_distribution=false` for this plain development profile. The safe local
Damage bridge is independent of distribution.

See `ERM-Dev-Shell.md` for configuration, prerequisites and migration details.
The earlier dev.sh/require-dev-context.sh/dev_shell.escript helpers are removed.
