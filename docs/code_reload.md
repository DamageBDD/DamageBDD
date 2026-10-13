# Node-local source reload with fs

`damage_reload` replaces Sync's startup hook. It is supervised under `damage_sup`.
Configuration is a tuple proplist in the existing `damage` application entry.
There is no HTTP/BDD API for enabling it or choosing paths.

## Apply and resolve dependencies

From the repository root, apply the supplied patch and then run:

```sh
rebar3 unlock sync,fs
rebar3 compile
rebar3 eunit --module=damage_reload_tests
```

Review and commit the resulting `rebar.lock`. It was not supplied with this patch,
so no lockfile revision or checksum is fabricated. Rebuild/redeploy the release
once before using post-release compilation: this patch explicitly includes `fs`
and the OTP `compiler` application in the release with the `load` start type.
That makes the code available without starting fs's default filesystem watcher.

Check for old application dependency declarations:

```sh
git grep -n -w sync -- 'apps/*/src/*.app.src'
```

Remove `sync` from an `applications`/`included_applications` list if it appears.
The application resource and supervisor source were not supplied. The existing
`start_sync` phase is retained only as an alias to `start_code_reload`, so its
current declaration can remain without invoking Sync. Renaming that phase in
`damage.app.src` is optional; the new callback handles either name.

On Linux install `inotify-tools`. An unavailable watcher does not abort Damage
startup. Periodic content reconciliation also covers dropped filesystem events.

## Ordinary checkout development

Keep using:

```sh
rebar3 shell
```

The new shell script records the checkout root before Damage changes its working
directory. The default `{enabled, dev}` enables reload only when that shell script
has run. A release console or `remote_console` does not enable it.

An explicit checkout configuration, merged into the existing application entry:

```erlang
{code_reload, [
    {enabled, dev},
    {mode, rebar},
    {apps, [damage, nosternity, erm, ecai, bop]},
    {profile, "default"},
    {debounce_ms, 300},
    {retry_ms, 1000},
    {rescan_ms, 5000},
    {build_timeout_ms, 300000},
    {load_on_start, false}
]}
```

Without `apps`, existing directories from `[damage, nosternity, erm, ecai,
vanillae, bop]` are selected. Explicitly configured apps must exist below
`ROOT/apps/APP` with a `src` directory. This patch targets that supplied umbrella
layout. Add external shared-header directories via `include_dirs`.

`rebar` mode runs an external Rebar process through erlexec using an argv list,
not a concatenated shell command. It preserves Rebar's compilation, dependencies,
and hooks. It does not call `r3:compile()`, `c:c/1`, or Sync.

Each coordinator has its own staging directory below
`ROOT/_build/damage_reload/`. `REBAR_BASE_DIR` redirects Rebar there. That staging
path is never added to the running VM's code path. The `.app` module manifests
select BEAMs from successful builds; orphan output is not blindly glob-loaded.
Content changes to `.erl` and `.hrl` trigger builds, including shared headers in
configured include directories. Generated `damage_build_info.erl` is excluded
from input snapshots to prevent rebuild loops.

The first staged build needs its dependencies/artifacts built independently of
the shell's normal `_build/default`; later builds in the same session are
incremental. Inactive staging directories can be removed when no reloader build
uses them. Native builds and hooks may still write outside the staging directory;
BEAM staging is not a sandbox for build scripts or native artifacts.

The default compiler profile is `default`. For `rebar3 as dev shell`, explicitly
set `{profile, "dev"}`. This patch supports one named build profile; composite
profile strings such as `prod,cuda` are intentionally rejected. It does not infer
profiles by parsing the launch arguments. Profiles, dependencies, build config,
parse-transform infrastructure, application resources, and native changes should
be handled with a controlled rebuild/restart, not an automatic module reload.

`{enabled, false}` overrides shell activation. No configuration maps are accepted.

## Custom modules on an installed release

Create operator-controlled source/header directories before enabling the feature.
Do not put these directories under upload, report, or user-job work directories.
The node user needs read access; it does not need write access to release `ebin`.

Merge this key into the existing `damage` entry in the node's active sys.config:

```erlang
{code_reload, [
    {enabled, true},
    {mode, sources},
    {source_dirs, ["/var/lib/damage/custom/src"]},
    {include_dirs, ["/var/lib/damage/custom/include", {app, damage, include}]},
    {modules, [steps_local]},
    {erl_opts, [debug_info]},
    {reuse_compile_opts, true},
    {load_on_start, true},
    {debounce_ms, 300},
    {retry_ms, 1000},
    {rescan_ms, 5000}
]}
```

All directories must exist. Remove an include directory from configuration when
it is not needed/present. A module's filename must match its configured atom, for
example `steps_local.erl` must declare `-module(steps_local).`. Every listed
module must have exactly one matching source file. The allowlist is not an OTP
application/step registration list: it authorizes compilation and loading only.

`load_on_start = true` recompiles and loads the allowlisted sources on each boot.
With `false`, startup records the existing sources and waits for an edit or
`damage_reload:reload()`. No custom BEAM is persisted and no installed BEAM is
overwritten. Runtime-only overrides disappear after restart unless startup
compilation is enabled again. Deleting a source does not unload its module;
restore it or restart the node to remove the in-memory override.

Source mode uses `compile:noenv_file/2` with binary output. It recompiles the
entire allowlist when an input/header changes and publishes no part of a batch
whose compilation fails. Existing loaded-module compile options are reused where
available, with build-host/output paths filtered; explicit `erl_opts` and include
directories supply the local environment. Set `reuse_compile_opts = false` for
a completely explicit compiler configuration. Only absolute, existing recorded
include paths are retained. `include_lib` resolves through the running release.

Source mode is intended for standalone trusted Erlang modules. It does **not**
run Rebar hooks, fetch dependencies, regenerate scanners, compile native code,
or establish ordering for new/changed parse transforms. Use checkout/Rebar mode
or a rebuild for those workflows. Referenced libraries and parse transforms must
already be available on the node.

## Editing a packaged application source

Use an application-relative path to avoid hard-coding its versioned directory:

```erlang
{code_reload, [
    {enabled, true},
    {mode, sources},
    {source_dirs, [{app, damage, src}]},
    {include_dirs, [{app, damage, include}]},
    {modules, [steps_http]},
    {reuse_compile_opts, true},
    {erl_opts, [debug_info]},
    {load_on_start, false}
]}
```

`{app, damage, src}` resolves from `code:lib_dir(damage)`, not the build machine's
compile-info source path. Only `steps_http` can be published by this configuration,
although changes to other inputs inside that watched tree trigger reconciliation.
New helpers must be added explicitly to `modules` and the configuration reapplied.

For durable local customisation, prefer a source copy under `/var/lib/damage/custom`
over editing package-owned files that an upgrade may replace.

## Live operator controls

From a trusted shell on the running node:

```erlang
damage_reload:status().
damage_reload:reload().   % queued build; observe last_result for the outcome
damage_reload:pause().    % compilation may finish, but publication is disabled
damage_reload:resume().   % build current inputs and resume publication
damage_reload:stop().     % stops its watchers, not already-loaded custom code
```

To enable or change paths without restarting an already-patched node:

```erlang
application:set_env(damage, code_reload, [
    {enabled, true},
    {mode, sources},
    {source_dirs, ["/var/lib/damage/custom/src"]},
    {modules, [steps_local]},
    {erl_opts, [debug_info]},
    {load_on_start, true}
]),
damage_reload:reconfigure().
```

`set_env` changes only this VM. Put the same settings in the active sys.config for
subsequent boots. Editing sys.config by itself does not dynamically reconfigure
this worker. `reconfigure/0` validates the new settings before stopping the old
worker. Status includes configured paths, watcher liveness, compilation state,
pending modules, and the last error/publication result.

## Safety boundaries

The loader prepares the whole changed batch first, uses only `code:soft_purge/1`,
and finishes with `code:finish_loading/1`. It never calls `code:purge/1` or deletes
application code. Busy old code defers the batch and is retried automatically.
A newer source snapshot supersedes a deferred batch. Compile/load failures are
reported rather than logged as successful reloads.

NIF-loading modules, `-on_load` modules, sticky modules, and the reloader/startup
modules require a restart. `damage_app`, `damage_sup`, `damage_build_info`, and
`damage_reload*` are excluded by default and cannot be explicitly enabled by
removing them from `exclude_modules`. Extra exclusions can be configured.
Excluded modules in checkout mode are deliberately not published; restart after
changing them. No automatic loader should run alongside this one. Do not use
Sync, shell `c/1`, or `r3:compile()` to bypass its publication policy.

This is not a state-migration or release-upgrade mechanism. A new callback's
state layout must remain compatible with existing processes. It does not drain
BDD executions, pause the scheduler, migrate gen_servers, refresh HTTP routes,
refresh cached step registries, or pin a running verification to one code version.
Pause reload before reproducibility-sensitive runs; drain/restart explicitly
when changing process state, supervision, routes, or registration metadata.
New BDD step discovery still uses the existing project mechanism; no change to
`damage_utils:loaded_steps/0` is included because that implementation was not
provided. Direct module calls work once the module is loaded.

Watch roots are canonicalized and must be absolute paths (or the supported
application-path tuples). Symlink files inside roots are rejected and symlink
subdirectories are not recursively followed. Watch-root characters are restricted
to a conservative printable set because fs backends build platform-specific
watch commands. These checks are operational safeguards, **not a hostile-filesystem
or Erlang security sandbox**. Source and parse transforms run with node privileges;
anyone who can edit the watched sources is effectively a node administrator.

## Tests and verification status

`damage_reload_tests.erl` contains EUnit cases for defaults and tuple config,
allowlists, path boundaries and symlinks, compile-failure rollback, header changes,
no on_load execution, atomic deferral while old code is busy, newer-source
supersession, and source deletion. Tests operate on temporary standalone modules.
They do not start the full node or exercise fs/erlexec integration.

The patch was prepared against the supplied `damage_app.erl` and `rebar.config`.
Patch applicability and whitespace can be checked locally. No Erlang runtime or
Rebar executable was available in the authoring environment, so compilation,
EUnit, fs integration, and release assembly have not been executed there.

After applying, run the EUnit command above, check `damage_reload:status()` in a
shell, edit a non-stateful test module, and verify both a successful update and a
syntax-error save while the old implementation remains callable. Build a release
and verify that an unconfigured node has no `damage_reload` worker, then verify
an explicit source-mode configuration on a test node before using it operationally.
