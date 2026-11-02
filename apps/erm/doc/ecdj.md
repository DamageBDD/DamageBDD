# ECDJ foundation for ERM

ECDJ fetches Creative Commons release metadata from Ektoplazm, preserves the
release's licence assertion and attribution, caches its audio, ranks cached
tracks, and plays them through the existing ERM playlist and MPV owner.

This is an integrated foundational implementation. The recommender is an
explainable deterministic metadata baseline in ECAI, with an existing ECAI term
pipeline bridge. It does not claim that content hashes encode musical similarity.

## Source baseline and installation

The patch targets the supplied ERM snapshot `latest-erm.tar(20261023-015241).gz`
and ECAI snapshot `latest-ecai-qwen-profiles.tar.gz`. Exact SHA-256 values are in
`apps/erm/doc/ecdj-baseline.json`. It is not based on a live checkout of your
current working tree. Both applications' changes are required.

From the DamageBDD repository root:

```sh
git apply --check /path/to/erm-ecdj-foundation.patch
git apply /path/to/erm-ecdj-foundation.patch
rebar3 compile
```

The existing JSX and Gun dependencies are used. Gun is now an explicit ERM
application dependency. No Python, downloader executable, native ECAI NIF,
cloud model, or new music-service API key is required by this core.
The installed MPV must support the fixed per-file options used by
`load_cached_audio`; unsupported options return a playback error without a
less restricted retry.

## Start and use

Within the running user ERM node:

```erlang
{ok, _} = erm_dj:start().
erm_dj:show().                         % optional native GTKGS controls
erm_dj:status().
```

The core is supervised by `erm_sup`. It starts idle and makes no network
requests until explicitly asked. The native window offers source discovery,
fetch, cache, tags/mood, recommendations, play/next, and local ratings, with
artist, source and licence attribution. GTK is optional; headless use works
through the same API. Display-manager greeter/session-host modes do not start
this service.

For optional startup at user-session boot, merge this into the existing
`sys.config` ERM entry (do not replace the rest of your configuration):

```erlang
{dj, #{enabled => true, commercial => false,
       data_dir => "/home/USER/.local/share/erm/ecdj"}}
```

The normal default is `enabled => false`; manual `erm_dj:start/0` starts it.
`erm_dj:stop/0` removes the supervised child and leaves MPV playback alone.

A complete explicit source-to-play workflow:

```erlang
{ok, [ReleaseURL | _]} = erm_dj:discover().
{ok, Release} = erm_dj:fetch(ReleaseURL).
maps:get(license, Release).            % inspect licence and source assertion
{ok, Cached} = erm_dj:cache_release(maps:get(id, Release)).
{ok, Recommendations} = erm_dj:recommend(
    #{tags => [<<"downtempo">>], mood => <<"ambient">>,
      time_of_day => <<"evening">>}, 10).
[Selection | _] = Recommendations.
maps:get(reasons, Selection).
{ok, _} = erm_dj:play(maps:get(id, Selection)).
ok = erm_dj:rate(maps:get(id, Selection), 1).
```

These examples require successful network responses and a nonempty catalogue;
production callers should handle `{error, Reason}` and empty lists. Discovery
returns release URLs; fetching retrieves metadata; caching is a separate explicit
album download. Ektoplazm player links are labelled previews and are not presented
as verified full recordings. Full cached album tracks come from the selected ZIP.

Other APIs:

- `releases/0`, `tracks/0`: stable ID-ordered catalogue snapshots.
- `rate/2`: private preference from -2 through +2.
- `set_policy/1`, `export_policy/0`, `import_policy/1`: declarative DJ policies.
- `status/0`: counts, current worker state and most recent error.

Only one network/archive job runs at once. Overlapping requests return
`{error,busy}`. Long jobs run in linked monitored workers, with absolute service
and transport deadlines; status, catalogue reads and local ratings stay available.
Playback preparation runs in the calling process, outside the service loop.

## Recommendation behaviour

The pure ECAI API is:

```erlang
 ecai_music_recommender:recommend(Tracks, Context, Policy, Feedback, Limit).
```

It scores contextual and preferred tags, requested mood, optional tempo,
local ratings, unplayed discovery, seed recordings, and recent repetition.
It excludes forbidden tags and uses a stable recording-ID tie break. Every
result includes score components. Missing BPM is neutral; no tempo or mood
classifier is fabricated from source genre tags. Context tags and mood must
match the available descriptors to influence the result.

`time_of_day` is an explicit coarse tag supplied by the caller in this release;
there is no hidden clock, location inference, microphone or biometric collection.
The ERM service supplies recent playback history. Private ratings, play counts,
recent IDs and the selected policy persist atomically across service restarts.

`index_record/1` and `index_terms/1` bridge music metadata to `ecai_terms`.
Version 1 scans the bounded local candidate set; geometric retrieval and
collaborative learning are future interchangeable ranking/retrieval layers.

## Share a recommender

```erlang
Policy = (ecai_dj_package:default())#{
    name => <<"Monsoon Debugger">>,
    preferred_tags => [<<"ambient">>, <<"downtempo">>],
    policy_license => <<"CC-BY-4.0">>},
ok = erm_dj:set_policy(Policy),
{ok, PackageJSON} = erm_dj:export_policy(),
{ok, PolicyDigest} = ecai_dj_package:digest(Policy).
```

Choose a policy licence that you are entitled to grant. The default is
`LicenseRef-Unspecified`, which does not silently dedicate your policy to the
public domain. This licence concerns the recommendation policy, separately from
music licences. Packages contain a closed, bounded declarative schema and no
executable code, audio, file paths, credentials or listening histories.

The canonical SHA-256 digest binds the policy and can be referenced by a future
IPFS/NFT publication layer. It establishes integrity, not authorship, ownership,
scarcity, music rights, or a signature. NFT minting, signatures, payment flows,
public social reviews and Nostr federation are not implemented in this release.
Local ratings and portable policy packages are the implemented foundations.

## Licence and playback boundaries

The adapter requires an explicit CC licensing paragraph inside the release
entry. Footer icons and site-wide assumptions cannot authorise a release.
Unknown or conflicting statements fail closed. It stores the canonical licence
URL, source release URL, and digest of the retrieved HTML as a source assertion;
this is not independent verification of the publisher's ownership.

The parser recognises the standard BY-family licences in versions 1.0, 2.0,
2.5, 3.0 and 4.0. This is an Ektoplazm adapter, not a universal CC/public-domain
crawler. `commercial => true` excludes NC audio at caching, recommendation and
playback. The default personal configuration must reflect the actual use;
changing a flag does not itself settle whether a use is legally commercial.

No remixing, audio redistribution, automatic seeding, stream extraction, public
rebroadcasting or music NFT sale is performed. SA/ND and attribution information
remain attached to the recordings. Paid DJ-policy publishing needs its own
review of music, metadata and provider rights for the actual intended use.

HTTPS requires trusted Ektoplazm hosts, TLS peer/hostname verification, limited
redirects, an absolute deadline and actual response-byte limits. Compressed HTTP
responses are rejected. The source and archive host policy is deliberately
closed; another source requires another reviewed adapter and host policy.

ZIP extraction checks central and local headers, CRC, names, types, counts,
claimed and actual inflated sizes, and compression ratios. It rejects traversal,
links, encrypted/ZIP64 archives and unsupported methods. Audio gets generated
cache filenames, private permissions, exact digests and a completion manifest.
Playback verifies manifest membership and bytes, then uses the ERM MPV owner
with fixed audio demuxing and nested reference/network restrictions. It adds the
track to the existing ERM playlist without clearing the rest of that playlist.

This boundary limits imported content; it does not sandbox the operating-system
media decoder. Keep MPV and its codecs maintained.

## Storage and operational limits

The default data directory is `$XDG_DATA_HOME/erm/ecdj`, otherwise
`$HOME/.local/share/erm/ecdj`. A custom directory must be private and writable.
The media cache rejects symlinked directory components.

Defaults: 2 MiB metadata, 256 MiB compressed archive, 64 MiB per archive entry,
256 MiB expanded release, 512 entries and 20:1 compression ratio. Archive limits
can be lowered in `dj` configuration; trusted operator limits cannot exceed
compiled ceilings. The catalogue caps at 500 releases, 10,000 cached tracks,
and 8 MiB state. Downloads beyond these limits return errors.

There is no automatic disk eviction yet. Normal failures remove staging files;
an untrappable process kill or host crash can leave `.part-*` directories.
Stop ECDJ and remove only such incomplete directories beneath its private cache
when reclaiming space. They never qualify as complete cached releases. Back up
`catalogue.term` and the matching audio cache together. Corrupt state is rejected
rather than silently overwritten. Concurrent VMs must use separate data dirs.

Refreshing a release invalidates its old playable catalogue rows until recached
against current source metadata; old cache files remain available for manual
cleanup. Shared packages never contain this private state.

## Verification and limits

From the repository root, with umbrella dependencies built:

```sh
ERL_LIBS=_build/default/lib apps/erm/test/dj_core/run.sh
```

The runner compiles the new modules, supervisor and MPV owner with warnings as
errors. It runs pure and integration suites. Service/HTTP fixtures are compiled
only into separate temporary directories, never a production application path.
The service suite uses the real service, cache, ranking and persistence code,
with simulated source/playback boundaries. The HTTP suite drives the real HTTP
client against a bounded Gun protocol fixture. Tests include TLS options,
redirect revalidation, response limits, cancellation, ZIP bombs/path/link checks,
cache tampering, policy tampering, context/rating effects and supervised restart.

This build was verified on OTP 25 with real JSX 3.1.0: 35 main tests, 11 isolated
HTTP tests and 4 service tests passed (50 total). The real MPV Unix-socket fixture
is included but skipped here because this host denies Unix socket binding.
Native GTK visual operation, actual audio playback, and a complete umbrella
build with its native dependencies were not exercised here.

Live Ektoplazm release metadata was fetched and parsed: Globular, Entangled
Everything, CC BY-NC-SA 4.0, ten player previews and two ZIP links. A real
1,163,476-byte source player preview passed cache extraction, MP3 identification,
manifest verification and hashing inside a test ZIP. This is explicitly a
preview-cache smoke check, not proof of full-album playback. Music and retrieved
HTML are not included in the patch or bundle. Native Gun internet transport was
validated through protocol fixtures; live retrieval used the host HTTPS client.

Primary protocol references:

- https://ektoplazm.com/free-music
- https://ektoplazm.com/free-music/globular-entangled-everything
- https://creativecommons.org/faq/
- https://ninenines.eu/docs/en/gun/2.2/manual/gun.get/
- https://mpv.io/manual/stable/#command-interface
- https://mpv.io/manual/stable/#options-access-references
