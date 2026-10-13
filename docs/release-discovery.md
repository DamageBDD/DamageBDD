# Building and serving installation releases

The installer reads `/api/releases/latest?platform=ubuntu-noble-amd64&format=install`.
The release reader selects `latest_release_value_for(platform)` from ONE configured
build-release NFT. It then reads that token's metadata CID using the serving node's
local validating Kubo daemon. It never substitutes a generic platform, scans another
account's registry, or falls back to an older package when validation fails.

`/api/releases/current` describes the node's running software. It is not the build
registry and must not be used as an installer fallback.

## Shared configuration

Merge these tuples into the existing `damage` application entry in `sys.config` on
both the build authority and every serving node. Substitute real encoded public
identifiers; the following placeholders are intentionally not valid addresses.
Do not deploy a fresh NFT per build. Use the existing contract that the public API
is meant to serve. Its administrator must authorize the account signing the mint.

```erlang
{damage, [
    {ae_network_id, "ae_mainnet"},
    {build_release_nft_contract, "ct_REPLACE_WITH_SHARED_RELEASE_CONTRACT"},
    {build_release_reader_account, "ak_REPLACE_WITH_READER_PUBLIC_ACCOUNT"},
    {build_release_require_installation, true},
    {build_release_announce_oracle, false},
    {build_release_ipfs_gateway, "https://ipfs.io/ipfs"},
    {build_release_query_timeout, 10000},
    {build_release_publish_timeout, 300000},
    {ipfs_runtime, [
        {ipfs_api, "http://127.0.0.1:5001"},
        {request_timeout_ms, 10000}
    ]}
]}.
```

Preserve any other `ipfs_runtime` options already used by your node. The reader
account needs no private key for discovery; GET uses a public-key-only dry run.
The actual configured AE node/client must be connected to the same network as
`ae_network_id`: this identifier is not itself a network switch.

`run.damagebdd.com` and `run.dev.damagebdd.com` are different serving targets.
A working development registry does not configure or update the production one.
Production and development may use different registries intentionally; each build
must target the registry of the endpoint against which it will be verified.

## Build flow

Run the updated `features/devops/docker_build_ubuntu.feature` for the failing Noble
amd64 installer target. The three features share this order:

1. Validate the public reader configuration before an expensive build.
2. Lock the workspace, preserve `rebar.lock`, build and package with `as prod`.
3. Stage one main package, its SHA-256, Git SHA and `installation.json`.
4. Upload that directory; read and hash the exact package through local Kubo.
5. Add the verified `installation` object to `meta`, upload it, then mint.
6. Read platform-specific latest using the public resolver and compare the full
   minted identity and installation fields. A mismatch fails the build assertion.

The Ubuntu and Mint outputs use `ubuntu-noble-amd64`, `deb`, `amd64`, and the fixed
path `damage.deb`. The supplied Mint workflow intentionally targets the Noble ABI;
the updated script checks the builder's Noble base and amd64 architecture rather
than assuming compatibility from the image tag alone.

Arch uses `archlinux-x86_64`, `pkg.tar.zst`, `x86_64`, and
`damage.pkg.tar.zst`. It checks `.PKGINFO` and excludes any debug package. Both
package types must contain bundled `erts-*/bin/beam.smp`.

The scripts retain the supplied Dockerfile CIDs, workspace paths and packaging
output paths. They require the builder to have `flock`, `erl`, the packaging tools,
and the repository's `bin/check-beam-sources.sh`. They read exactly one assembled
`_build/*/rel/damage/releases/*/damage.rel` after cleaning `_build`. A differently
configured release layout must be updated explicitly; do not guess a version.

## Release identity is the packaged version

New manifests include `release`, read from the assembled OTP `.rel` file. The
preparation step puts it in the `build_release` context variable and binds it into
NFT-linked metadata. The mint step uses `{{build_release}}` and `{{git_sha}}`.

Do not use `install-{{meta_hash}}` or an artifact CID as the version. The install
sidecar is later compared with the running OTP release. A CID-as-version makes
that provenance comparison fail even when the package is otherwise correct.

The contract's release/platform pair is immutable. A different package or metadata
CID for an already minted version must not silently reuse the old token. Bump the
packaged application version (and rebuild), or deliberately re-use the exact old
artifacts for an idempotent retry. Mint and Ubuntu share one target, so choose one
canonical publisher for each version/platform pair. Do not run both for the same
version expecting two different builds to replace each other.

The contract's `latest` is its most recently minted pointer, not a semantic-version
sort. Reusing a historical token does not promote it to latest. The new final BDD
assertion catches this instead of reporting a misleading publication success.

## Verification and diagnosis

On the serving node, evaluate these read-only calls in the Erlang shell:

```erlang
damage_release_nft:discovery_config().
damage_release_nft:latest(<<"ubuntu-noble-amd64">>).
```

The first reports missing/invalid reader configuration without needing private
keys. The second also exercises the contract getter and local Kubo metadata read.
The HTTP response intentionally remains generic for backend failures; the node's
OTP logger now records a bounded reason such as a missing config key, invalid
release option, metadata mismatch or IPFS error. No raw contract payload or
private key is added to the public response.

```bash
BASE=https://run.damagebdd.com
curl -sS -i --get \
  --data-urlencode 'platform=ubuntu-noble-amd64' \
  --data-urlencode 'format=install' \
  "$BASE/api/releases/latest"
```

Expected success is HTTP 200 with `Content-Type: text/plain; charset=utf-8` and the
11-line `damagebdd-install-v2` manifest. An empty Git SHA/path, where permitted, is
still a field; never collapse empty lines or execute/source the manifest.

After a successful local post-mint assertion, the build context contains:

- `build_release_mint_result`: the immutable NFT identity.
- `build_release_install_result`: the verified discovery record, including the
  exact asset URL, package path and checksum.
- `build_release_install_manifest`: the canonical 11-line installer response.

Save `build_release_install_manifest` from the trusted build as `expected.install`,
then verify the actual deployed/proxied endpoint without installing anything:

```bash
bin/verify-release-endpoint.sh \
  https://run.damagebdd.com ubuntu-noble-amd64 expected.install
```

This compares the entire manifest byte-for-byte, including network, contract,
token, release, platform, Git SHA, both CIDs, package path and SHA-256. It refuses
HTTP errors, redirects, malformed replies and a different latest token. It never
falls back or treats any arbitrary HTTP 200 as proof of the expected release.
The local BDD assertion alone does not prove reverse-proxy routing or a remote
server's configuration; use this check for every public serving target.

Status meanings remain distinct:

- 404 `release_not_found`: the selected contract has no release for this selector.
- 422 `installation_manifest_missing`: the selected NFT metadata lacks installation data.
- 503 `release_unavailable`: configuration, chain, metadata/IPFS or backend failure.
- 400 `invalid_release_request`: malformed query only; backend exceptions no longer
  get mislabeled as client errors.

A proxy-generated 404 is separate from the JSON 404 above. Check routing/deployment
when the body is not the handler's JSON error. A legacy NFT with no installation
metadata cannot be repaired by inventing a checksum in the HTTP handler. Publish a
new valid version through the corrected feature and keep validation fail-closed.

## Tests

```bash
rebar3 compile
rebar3 eunit --module=damage_release_discovery_tests,damage_release_nft_tests,damage_releases_http_tests,damage_release_return_tests,damage_release_publication_tests,steps_release_nft_install_flow_tests,steps_release_nft_dry_tests
```

The new orchestration tests provide explicit query/metadata callbacks and exercise
the actual HTTP response helper. Publication integration tests use the supplied
loopback Kubo fixture and the real `damage_ipfs` implementation in the repository.
They do not contact mainnet or mint tokens. They require the normal project
Erlang dependencies, including JSX, the AE encoder and Gun/Kubo helpers.
