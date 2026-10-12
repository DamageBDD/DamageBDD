# Native TTS discovery and diagnostics

This patch is incremental to the existing native Piper `erm_tts` implementation.
It adds `erm_tts_paths` and replaces the generic startup catch with actionable,
per-setting diagnostics. It does not build/download Piper or choose a voice.

Merge this minimal configuration into the existing `erm` entry:

```erlang
{tts, [
    {enabled, true},
    {model, "/opt/piper/voices/en_US-lessac-low.onnx"}
]}
```

Use the path to your installed voice; the example does not create that file.
Restart the application/node after configuration changes. An existing supervisor
child's start arguments retain the old configuration even if application env is
updated and `supervisor:restart_child/2` is called. A full application restart or
replacing the supervisor child spec is required to change those arguments.

Defaults:

| Setting | Discovery |
| --- | --- |
| `binary` | `code:priv_dir(erm)/erm_tts_port`; if the app directory is unavailable, sibling `priv` of the loaded module's `ebin` |
| `model` | Explicit setting, otherwise `PIPER_MODEL` in the service environment |
| `config` | Model path with `.json` appended (e.g. `voice.onnx.json`) |
| `player` | `mpv` on the service's `PATH`; the port uses mpv-specific arguments |
| `espeak_data` | `piper_prefix` or `PIPER_PREFIX` + `/share/espeak-ng-data`, then user-local and standard locations |

The additional eSpeak search paths are `$HOME/.local/share/erm/piper/share/espeak-ng-data`,
`/opt/piper/share/espeak-ng-data`, `/usr/local/share/espeak-ng-data`, and
`/usr/share/espeak-ng-data`. Prefer the data installed by your Piper SDK; use
`piper_prefix` or `espeak_data` explicitly for a custom installation.

Explicit values always take precedence, including invalid ones: discovery never
hides a broken override. All resolved paths must be absolute. Executables must
be regular files with execute bits; models/configs must be readable regular
files. The eSpeak data directory must contain a readable `phontab`. This checks
presence, not model validity or data/library ABI compatibility. `open_port` and
the native backend still provide the final runtime permission/load checks.

Run:

```erlang
erm_tts:diagnostics().
erm_tts:status().
```

Diagnostics returns `#{paths => ResolvedPaths, errors => ErrorsBySetting}` using
the running service's options. Errors distinguish missing settings, invalid or
relative paths, missing files, wrong file types, permissions and missing execute
bits. `status().last_error` contains `{backend_configuration, Errors}` or
`{backend_start_failed, Details}` instead of the old `backend_unavailable`.
Native error packets and port exit statuses remain visible as before.

Identical configuration failures are logged once rather than every five seconds.
Discovery retries every five seconds, so fixing a file/permission issue does not
require restarting the service. Diagnostics is read-only and does not spawn a
second backend. `PIPER_*`, `PATH` and `HOME` refer to the service environment,
which can differ from the interactive shell.

If the native port is absent, from the project root:

```sh
PIPER_PREFIX=/opt/piper rebar3 as tts compile
```

Use the SDK's actual prefix and a `tts` release profile for deployment. The
executable searched here is `erm_tts_port`, not the unrelated system `piper`
command or a Python Piper executable. Missing shared libraries generally appear
as a port exit status; inspect the service stderr/journal for loader diagnostics.

Isolated tests live under the application, with fixture Erlang sources renamed
`.erl.src` to avoid accidental recursive compilation:

```sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
```

They compile the native port against a mock Piper implementation and verify
path precedence, defaults, model/config derivation, permissions/type checks,
automatic recovery, speech/cancellation, player cleanup and timeouts. They do
not validate a real installed voice model or audio device.
