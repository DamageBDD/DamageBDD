# Controlled hot code and runtime provenance

## Scope and deployment

Apply this patch after the latest reviewed hot-code/provenance changes. Deploy
through the normal build/release/restart path. Do not hot-load the loader or
journal over active sessions from the old implementation: old entries do not
contain the original BEAM bytes. Such entries are retained as uncertain and
rollback returns `base_beam_unavailable`, rather than silently clearing them.
Finish old overrides before deployment, or restart onto the packaged release.

This is a trusted operator maintenance interface, NOT a sandbox or remote
attestation. Allowed Erlang source and parse transforms execute with node
privileges. A malicious administrator, a remote shell with the node cookie, or
code directly calling OTP's loader can bypass this API. Do not expose that
shell, the node cookie, or arbitrary Erlang evaluation to ordinary BDD users.
Neither a matching Git SHA nor this journal proves the absence of changes made
outside the managed loader. A report snapshot is point-in-time metadata; it is
not proof that every step ran under a single immutable code generation.

The lightweight loader accepts explicitly allowlisted `steps_*` modules and
`text_formatter`/`html_formatter` only. `steps_hotcode` and `steps_utils` are
always blocked. All `damage_*` core modules, authentication, custody, provenance
and the runner are outside the permitted class, even when listed. Stateful
callbacks, process-state migration, dependency upgrades and NIF upgrades require
an appropriate OTP release upgrade/restart, not this helper. BEAMs with on_load
or nifs attributes, or missing abstract code, are rejected.

## Configuration

Merge these tuple entries into the existing `damage` application in sys.config:

```erlang
{damage, [
    {operator_hotcode, [
        {enabled, true},
        {allowed_modules, [steps_http, text_formatter, html_formatter]}
    ]},
    {operator_source_dir, "/var/lib/damage/overrides/src"}
]}.
```

The default is disabled with an empty allowlist. Module names must be exact
atoms in the configuration; strings, wildcards and an allow-all switch are not
accepted. They must also be declared in the loaded damage application's module
list. Restrict the source directory and its parent directories to trusted
operators and the Damage service account. They must not be writable by untrusted
run workloads. The filesystem checks are not a defence against a hostile
concurrent filesystem writer. No user-supplied path is accepted by the BDD API.

Retain the previously added `include_src=true` / `debug_info=keep` release
settings. The installed release needs the OTP compiler and include dependencies
used by the module being edited, including eunit headers where its source uses
those headers. Missing compile dependencies cause a reload error, not a change
to currently running code.

## Workflow

```erlang
{ok, copied, SourcePath} = damage_hotcode:prepare(steps_http).
%% Edit SourcePath outside the release tree. A second prepare returns exists
%% without replacing the file.
{ok, Metadata} = damage_hotcode:reload(steps_http).
damage_release:info().
damage_hotcode:rollback(steps_http).
```

An explicit admin check is made in the BDD adapter in addition to the runner's
`-damage_roles([node_admin])` early filter. The existing step phrases are unchanged.
Removing a module from the allowlist or disabling new loads does not prevent
rollback of an already-recorded override.

Source bytes are read once and compiled from a private staging copy. The
`source_sha256` covers that .erl file, not all header/parse-transform inputs;
`beam_sha256` covers the actual compiled BEAM. Content-addressed BEAM copies are
kept under the `beams` directory beside `src` so the existing strict runner can
inspect abstract code at `code:which(Module)`. That directory is never added to
the code path, and cached files are never automatically loaded on restart. Keep
cache files while their code is active; remove obsolete caches during stopped
maintenance, not while the strict runner may need to inspect them.

## Registry and consistency

All journal writers, managed load/rollback operations and snapshot readers use
one re-entrant node-local lock. There is no cross-node lock or state replication.
Compilation occurs outside the lock. Concurrent writers cannot lose entries,
and snapshot readers cannot observe the middle of a managed change.

The journal deliberately remains in persistent_term, not a newly introduced
unsupervised process/ETS owner that could die while its loaded code survives.
This storage is for rare administrative changes only: persistent_term updates
can trigger global garbage collection. Do not use it for per-step events or a
high-frequency code-reload loop. Ordinary reads do not rewrite the journal.
There is no additional supervisor child to install.

`damage_release:info/0` captures one journal snapshot. The runtime hash is a
pure function of its supplied snapshot; it never rereads the registry. It
includes both current and still-present old code hashes. The hash domain is now
`damagebdd-runtime-code-v2`; v1 and v2 digest values are not interchangeable.
Timestamps and the monotonically increasing revision are not code hash inputs.

A write-ahead transition is recorded before loading code. If the calling
process dies mid-operation, that entry survives and reports
`runtime_integrity_status=uncertain` and `runtime_code_hash=unknown` until an
explicit rollback reconciles it. Broken/unavailable registry reads return
`runtime_modified=null`, not a false assertion of a pristine runtime. `clear/0`
and `remove/1` refuse to erase entries while override code can still be loaded.

The original packaged BEAM bytes, path and SHA-256 are retained privately at the
first load. The loader checks their module identity against the running base.
Rollback reloads those captured bytes, not whatever `code:load_file/1` would find
on the current path. Captured BEAMs and filesystem paths are omitted from public
snapshot metadata. If an old override is still running, rollback returns:

```erlang
{error, rollback_loaded_but_override_still_in_use}
```

The base is already current, the override is still recorded as old code, and
processes are not killed. Let those processes exit their old code and retry
rollback. The retry only purges that old generation; it does not load the base
again. A third load while old code is in use is refused.

## Tests

Run the focused suite in an isolated test VM, not a live Damage node:

```sh
sh apps/damage/scripts/test-hotcode-hardening.sh
```

It compiles the changed Erlang modules with `TEST` and warnings-as-errors, then
runs EUnit using real compiled fixture modules and a synthetic damage application.
It does not start the full application or contact IPFS/chain/payment services.
It refuses to run its fixture against an already-started damage application.

Coverage includes concurrent writers, snapshot locking, pure snapshot hashes,
registry failure, caller death before/after a code load, policy restrictions,
unchanged-code rollback, changed disk/code-path rollback, lingering generations,
on_load rejection, module-name mismatch, safe prepare, non-erasing clear and
legacy metadata. Separate pure EUnit cases cover valid/build_mismatch/unverified
NFT build matching. The existing publication tests are left unchanged.
