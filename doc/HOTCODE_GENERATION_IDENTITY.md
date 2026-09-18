# Hot-code generation identity and interruption recovery

This is a follow-up to the serialized hot-code journal. It changes generation
identification, not the reload allowlist or the NFT installation protocol.

## Why both filename and module MD5 are required

`beam_lib:md5/1` identifies module code, not every byte of the BEAM file. For
example, changing the compilation-info chunk can preserve module MD5 while
changing SHA-256 of the full BEAM. A pending candidate with the same MD5 as the
active override is therefore not evidence that the candidate was loaded.

Each managed entry now keeps private `loaded_filename` and
`candidate_filename` fields beside the corresponding MD5 and full-BEAM digest.
Before selecting a generation's digest, the loader and registry match the
journal against both `code:is_loaded/1` and the current module MD5. The managed
cache gives different full-BEAM digests different filenames. Resolution runs
under the existing node-local journal lock; duplicate references to the same
identity are accepted, but conflicting digest claims are not.

Filenames are not included in the public snapshot or runtime hash. Public
`loaded_beam_sha256` and `old_beam_sha256` still describe the current and any
lingering old managed generation. An interrupted transition remains uncertain
until rollback reconciles it.

The distinction is important when A is current and B is a prepared candidate:

- Interruption before loading B: rollback retains A's digest while A is old.
- Interruption after loading B: rollback retains B's digest while B is old.
- Interruption after restoring the base: retry only purges old code and retains
  the digest recorded before loading the base.

Unknown filenames produce `{error, {untracked_current_code, Module}}`.
Conflicting or invalid digest claims for the matching filename/MD5 produce
`{error, {ambiguous_current_generation, Module}}`. Neither condition authorizes
an automatic guess, code replacement, or journal removal. Snapshots report
`runtime_integrity_status => uncertain` and `runtime_code_hash => <<"unknown">>`.

These checks are operational provenance for cooperative managed loads. A
caller with unrestricted Erlang execution can forge filenames and journal
contents. This is not a hostile-code sandbox or remote attestation mechanism.
It also does not change when the BDD runner captures its release snapshot.

## Deployment and configuration

Deploy using the normal release/restart procedure. Existing VM-lived entries
may not have the new filename fields. They are not upgraded by guessing a
filename from module MD5: an unresolved live override remains uncertain and
rollback refuses to guess its full-BEAM identity. A controlled VM restart loses
both hot-loaded generations and the ephemeral journal; source files are not
automatically reloaded.

The distributed `sys.config.sample` now has `{enabled, false}`. Operators must
explicitly enable new reloads and supply the exact allowed modules. Disabling
reloads still does not prevent rollback of a resolvable recorded override.

## Regression tests

Run on a disposable local node:

```sh
sh apps/damage/scripts/test-hotcode-generations.sh
```

The runner compiles the loader, registry and new regression module, then starts
a fresh Erlang VM. It requires OTP compiler, crypto and EUnit applications but
not the rest of DamageBDD, IPFS, chain, or payment services.

The suite constructs two real BEAM binaries by changing only their compilation
information and explicitly checks equal module MD5 and unequal full-BEAM
SHA-256. A monitored writer is killed at the journal boundary before or after
`code:atomic_load/1`. A separate process keeps the selected generation alive
through rollback. Assertions cover exact old/current digests, uncertainty,
legacy entries, conflicting claims, private filenames, and purge-only retries.
The generator is enabled only by the standalone runner; an ordinary project
EUnit invocation does not activate the synthetic-application fixture. Even
when enabled, the fixture refuses to run when the Damage application is already
loaded. Use the isolated script rather than a live node console.

The older `damage_hotcode_tests.erl` fixture, when installed from the earlier
bundle, must also populate `loaded_filename` in synthetic entries and
`candidate_filename` in its simulated pending load. The separate optional
fixture patch does that; the new suite does not depend on that older file.

OTP reference documentation:

- https://www.erlang.org/doc/apps/stdlib/beam_lib.html#md5/1
- https://www.erlang.org/doc/apps/stdlib/beam_lib.html#build_module/1
- https://www.erlang.org/doc/apps/kernel/code.html#is_loaded/1
- https://www.erlang.org/doc/apps/kernel/code.html#atomic_load/1
