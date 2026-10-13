# Share to ECAI

Receive completed AirDrop and KDE Connect deliveries in an erm inbox, review them
in gtkgs, then explicitly index supported text into an ECAI private corpus.
The existing private LLM bridge can answer questions over accepted material.

## What this implements

- `erm_share`: optional OTP worker with a persistent review queue, immutable
  content snapshots, restart recovery, explicit accept/reject, limits and status.
- `erm_share_ui`: native gtkgs inbox with selection, private indexing, rejection
  and local-copy removal. Window class/instance: `erm_share`.
- `erm_kdeconnect_share`: small C/GIO session-bus adapter. KDE Connect owns
  discovery, peer pairing, TLS and payload transfer. The adapter listens to
  `org.kde.kdeconnect.device.share.shareReceived`, checks `isPaired` against the
  unique D-Bus sender, and writes atomic completion manifests. Erlang additionally
  checks the configured device allowlist and receive-directory boundaries.
- omdrop completion hook: after successful upload extraction, or receipt of a
  shared link, emits an atomic manifest in the dedicated receive directory.
  This does not use file-size stability or raw directory changes as a proxy for
  completion. No protocol implementation is copied into the BEAM.
- `ecai_share`: bounded Unicode text chunking and `ecai_private_index:index/4`
  integration. Retry verifies the existing batch's source identity if append
  succeeded before the inbox could record success. No public indexing fallback.

The app does not automatically fetch shared URLs, execute received content,
extract archives, run an LLM, publish to Nostr, or upload to IPFS/Blossom.
Receiving files over the two transports remains the job of their existing apps.

## Supported material

| Input | Inbox | Indexing |
| --- | --- | --- |
| KDE file share | Completed-file event | UTF-8 text formats below |
| KDE HTTP(S) link | URL text; no fetch | URL itself |
| KDE explicit text share | Companion signal patch required | Text |
| AirDrop files/photos | Completed-file manifest | Text files; binary originals retained |
| AirDrop web link | omdrop `.url`/`.webloc` file | Shortcut text; no page fetch |
| Photos, audio, PDF, office files, archives | Original retained | `unsupported_content`; OCR, transcription and document extraction are not implemented here |

Text extensions: `.txt`, `.md`, `.org`, `.json`, `.csv`, `.tsv`, `.feature`,
`.erl`, `.hrl`, `.log`, `.xml`, `.html`, `.url`, `.webloc`, `.yaml`, `.yml`, `.rst`.
They must contain valid UTF-8 without NUL bytes. Empty documents cannot be indexed.
Indexing caps text at 4 MiB; receiving defaults to 16 MiB per file, 512 MiB of
inbox snapshots and 1,000 items. A configured per-file limit may not exceed 64 MiB.
Native bridge events cap text/URI values at 64 KiB. Each completion spool caps
metadata at 1,024 entries. Upstream receive folders are separate and need their
own retention policy; deleting an inbox copy never deletes the sender's original.

## Source baseline and upstream versions

This patch targets the supplied 11 October 2026 snapshots:

- `latest-erm.tar(8).gz`, SHA-256
  `ae2c20d4efa6826794171ef76e55aba7b149e09baf3c88e716030179bb41a335`
- `latest-ecai.tar.gz`, SHA-256
  `bf881051fd6051a714508dd636d6cda222322b3ba24fb5e0cdc6ca975307e176`

Upstream source inspected on 12 October UTC / 13 October Sydney:

- [omdrop 0.16.1](https://github.com/brentkearney/omdrop-plugin), commit
  `6af4908310a4fcd1ba7800fcc7b83156bbd7ee77`.
- [omdrop-owl](https://github.com/t4t5/omdrop-owl), radio backend for non-Apple
  Wi-Fi hardware. Check its current supported-hardware table before setup.
- [KDE Connect](https://github.com/KDE/kdeconnect-kde), commit
  `38aa8faf2638ce984bec5b8d04f68db8aeace441`.
- [KDE protocol schema](https://github.com/KDE/kdeconnect-meta/blob/work/protocol-schemas/protocol.md).
- [opendrop-rs](https://github.com/ayourtch-llm/opendrop-rs) was also evaluated.
  Its documented receiver/link limitations and different completion interface
  mean it is not an implemented adapter in this patch.

AirDrop itself was not open-sourced by Apple. omdrop/OWL and OpenDrop are
independent implementations. AWDL requires supported radio hardware and the
upstream privileged radio helper. Some adapters lose their regular Wi-Fi
connection while AirDrop is enabled. erm never elevates the BEAM or configures
wireless interfaces itself. Test against the actual device/OS versions.

## Build and configuration

Run this in the DamageBDD repository after applying the patch:

```sh
# Arch: the build needs base-devel, pkgconf and glib2; transport needs kdeconnect.
# Debian/Ubuntu: build-essential, pkg-config, libglib2.0-dev, kdeconnect.
make -C apps/erm/c_src/share
rebar3 compile
```

For repeatable release builds, set `ERM_SHARE_BRIDGE=1 rebar3 compile` to add the
native helper to the app's pre-hook and artifacts. It is off by default and
preserves existing native-voice hooks. `priv/erm_kdeconnect_share` must be present
in the installed erm release. No new Python dependency is added to erm; omdrop
already uses Python, and its optional hook runs in that existing process.

Merge `apps/erm/priv/share/share.example.config` into `sys.config`, adjusting all
paths, the paired device IDs and the private corpus principal. The supplied
paths use `/home/steven` as an example, not an inferred account home. Use absolute
paths. `kdeconnect` and `airdrop` are maps, even if the top-level `share` setting
is a proplist. Keep the two receive directories distinct from the inbox directory.

The share principal is local operator configuration, not a value supplied by a
phone or packet. Configure/provision the target corpus first using
`apps/ecai/priv/config/private_index.example.config` and its existing private-key
setup. Missing keys/permissions produce a visible failed item, never a public
write. This first version binds one desktop inbox to one configured principal
and corpus. It is not a multi-user HTTP upload service.

Run erm as the logged-in desktop user, with that user's session bus and display
environment. Do not run this in the privileged display-manager greeter or session
host. The existing optional-services bootstrap starts it only in normal erm mode.
After changing configuration, restart this subsystem:

```erlang
erm_share:stop().
erm_share:sync().
erm_share:status().
erm_share:show().
```

`sync/0` starts enabled configuration under `erm_sup`; `stop/0` stops it without
deleting the inbox. `show/0` requires the existing gtknode4 configuration enabled.

## KDE Connect setup

1. Install and start KDE Connect in the desktop session. Pair the phone in KDE
   Connect's normal UI. `kdeconnect-cli -l` lists device IDs.
2. Configure its Share/Receive plugin to save into a dedicated folder, e.g.
   `/home/steven/.local/share/erm/kdeconnect`. Create it with mode 0700 and list
   that exact folder in `kdeconnect.roots`.
3. Add the paired device's ID as a binary in `device_ids`. Restart the share
   worker after changing configuration.
4. Share a file/link from the phone through KDE Connect to this computer. It
   should appear as `pending` in erm. Select it and choose **Index privately**.

Stock KDE Connect emits file completion and URL events. It copies explicit text
shares to the clipboard but does not emit a text payload completion signal.
For text support, apply the optional upstream patch to a KDE Connect checkout
matching the inspected commit and rebuild/install it using upstream instructions:

```sh
# Set these to the actual checkouts.
DAMAGE_REPO=/path/to/DamageBDD
KDE_REPO=/path/to/kdeconnect-kde

git -C "$KDE_REPO" apply --check "$DAMAGE_REPO/apps/erm/priv/share/kdeconnect-text-signal.patch"
git -C "$KDE_REPO" apply "$DAMAGE_REPO/apps/erm/priv/share/kdeconnect-text-signal.patch"
```

Restart kdeconnectd after installing that build. The companion patch emits
`shareTextReceived` only for an explicit `kdeconnect.share.request` text packet;
it does not change or monitor clipboard synchronization. Files and links work
without that patch. KDE Connect's own URL auto-opening behavior is unchanged.

The adapter listens while erm is running. Signals emitted while it is stopped
are not replayed by D-Bus; files still remain in the KDE receive directory.
It reconnects after helper/session-bus failure. `bridge => listening` means a
session-bus subscription exists, not that a phone is connected or a radio works.

## AirDrop setup with omdrop-owl

Install the radio backend appropriate to the machine using its upstream
instructions, then omdrop 0.16.1 or the inspected commit. Do not install both
omdrop-owl and omdrop-awdl on the same machine. This patch assumes the receiver
is already working; it does not silently install privileged radio software.

Apply the companion patch to the actual omdrop checkout used by its command,
and copy the hook beside `airdrop-serve.py`:

```sh
DAMAGE_REPO=/path/to/DamageBDD
OMDROP_REPO=/path/to/omdrop-plugin

git -C "$OMDROP_REPO" apply --check "$DAMAGE_REPO/apps/erm/priv/share/omdrop-completion.patch"
git -C "$OMDROP_REPO" apply "$DAMAGE_REPO/apps/erm/priv/share/omdrop-completion.patch"
install -m 644 "$DAMAGE_REPO/apps/erm/priv/share/omdrop_ecai_hook.py" "$OMDROP_REPO/bin/omdrop_ecai_hook.py"
```

Start the enabled erm share worker first. It creates the configured AirDrop
folder and its private `.ecai-events` subdirectory. The existence of that
subdirectory explicitly enables completion events; other omdrop destinations
remain unaffected. Then, in the logged-in desktop session:

```sh
omdrop dir /home/steven/.local/share/erm/airdrop
omdrop name "Share to ECAI"
omdrop on 10
# When finished:
omdrop off
```

Use the Apple share sheet → AirDrop → **Share to ECAI**. The receive window is ten
minutes. Configure omdrop's Contacts Only/known-sender controls if wanted; erm
records AirDrop as a transport, not as an authenticated Apple/account identity.
An upstream update can replace the patched receiver: recheck the integration
patch before updating, and keep the hook with the receiver. Restart receiving
after applying it. The Rust luftlift receiver is not interchangeable here.

A hook failure logs a fixed diagnostic and preserves the delivered original.
The sender's transfer is not reported failed just because ECAI notification
failed. Reshare once capacity/storage is restored. Batch events commit one per
file after the upload succeeds; if notification stops part-way, originals remain.

## Erlang API

```erlang
erm_share:items().
{ok, Id} = erm_share:submit(text, <<"A note for my private corpus">>, <<"Note">>).
erm_share:accept(Id).             % {ok, indexing}; state changes asynchronously
erm_share:items().                % indexed, failed, pending, rejected
erm_share:reject(Id).             % refuses indexed/busy items
erm_share:forget(Id).             % remove inbox record/snapshot, not private index
erm_share:ask(<<"What does my note say?">>, <<"local-ollama">>).
```

`ask/2` uses the existing private LLM bridge and corpus destination policy; it
must be called explicitly. Uploaded content has no authority to select a model,
endpoint, account, command or tool. Local callers are trusted BEAM code.

An accepted item uses a deterministic batch ID and immutable private-index
append. If a retry finds an existing batch, identity verification requires read
permission as well as write permission. Corpus owners already have both. Changing
the configured target after an attempt gives `target_changed`; use the original
target or reshare deliberately. Private segments do not have a delete API in this
change, so removal from the inbox is not a promise to remove indexed knowledge.

## Storage and diagnostics

The inbox directory, snapshots and DETS metadata are protected by Unix permissions
(0700 directories, 0600 files). They are plaintext local staging, not encrypted
storage. Encryption applies to accepted records inside the existing ECAI private
index. Use encrypted disks if the original received files need protection at rest.
Other code running as the same Unix user, trusted BEAM code and root remain in the
trust boundary. Read checks reject symlinks, traversal, out-of-root paths,
non-regular files, oversize data and changes observed across a read. They are not
an isolation boundary against a hostile process with the same UID.

Inbox duplicates are keyed by transport, device, kind, filename and content hash.
Repeated delivery does not bypass rejection or create repeated private batches.
Full-inbox and storage-failure manifests stay queued for retry; invalid/untrusted
manifests are discarded, with a fixed `last_error` available via `status/0`.
The original receive files are never opened in applications by erm. Size limits
here apply after upstream transport reception, not to upstream disk usage.

Useful checks:

```erlang
erm_share:status().       % count, snapshot bytes, busy, bridge and last error
erm_share:items().        % review state and fixed error code per item
erm_sup:optional_status().
```

## Validation

`apps/erm/test/share_isolated/run.sh` runs isolated tests against the real inbox,
ECAI share facade and existing gtkgs fake backend. It uses a test-only private
index double to avoid real user keys or persistence. Set `JSX_EBIN` if JSX is not
under `_build/default/lib/jsx/ebin`.

```sh
apps/erm/test/share_isolated/run.sh
```

Coverage includes restart persistence, manual acceptance, deduplication, limits
and queued retries, Unicode filenames/chunking, spoofed transport manifests,
disallowed devices/URI schemes, symlink/traversal boundaries, tampered snapshots,
unsupported binaries, recovery after immutable append, and UI selection/action.
The completion-hook tests exercise atomic private events, disabled mode, bad
permissions, symlinks, traversal and queue limits.

The Erlang sources compile with warnings treated as errors on OTP 25, and the
C/GIO helper builds with `-Wall -Wextra -Werror`. The optional rebar build toggle
is evaluated in both states. Companion patches are checked against their pinned
upstream source. Full umbrella compilation, a visual GTK session, live KDE
Connect D-Bus delivery and actual AirDrop/phone transfers require validation on
the target desktop; this environment has no radio and cannot create a D-Bus
session socket. Existing ECAI encryption/LLM internals are reused, not retested
against live private keys or a model in this change.
