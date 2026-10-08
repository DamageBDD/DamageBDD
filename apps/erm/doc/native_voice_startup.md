# Native voice startup

`erm_native_voice` is the microphone/Whisper/VAD/speaker worker. It is a separate
executable from `erm_tts_port`, which generates spoken responses. Native voice
requires both the worker and `arecord` on the runtime host.

## Build with rebar

From the project root:

```sh
rebar3 compile
```

On Linux, the per-app configuration in `apps/erm/rebar.config` and
`rebar.config.script` enables the native worker build and declares
`priv/erm_native_voice` as a required artifact. The normal compile command also
works when erm is part of the DamageBDD umbrella. No separate profile is needed.

The first compile builds missing SDKs using the revisions pinned in
`scripts/setup_native_voice.sh`, then builds the worker. Prerequisites are Git,
CMake, GNU Make, a C/C++ toolchain and `flock`; first-time SDK setup needs network
access. Setup runs as the build user and never installs OS packages with sudo.
The microphone runtime additionally needs `arecord` and access to the audio device.

Complete existing SDK installs are reused. Defaults are
`$HOME/.local/erm-voice/whisper` and `$HOME/.local/erm-voice/sherpa-onnx`; set
`WHISPER_PREFIX` and `SHERPA_PREFIX` for other absolute installation paths.
Subsequent compiles do not fetch SDKs. Source, build-script, SDK-file and compiler
option changes cause a relink. `rebar3 clean` removes the port and build metadata
while retaining the SDKs, so the next compile can rebuild offline.

Existing SDK installations are not automatically upgraded. To deliberately
rebuild SDKs at the revisions selected in the setup script, run that script
explicitly. Failed installations retain an incomplete-install marker and will
be retried instead of being accepted as a complete cache.

Build controls:

```sh
# Reuse installed SDKs and fail instead of downloading missing ones.
ERM_NATIVE_VOICE_AUTO_SETUP=0 rebar3 compile

# Explicitly omit native voice hooks and artifact requirements for this build.
ERM_NATIVE_VOICE=0 rebar3 compile

# Use system-installed SDKs.
WHISPER_PREFIX=/opt/whisper SHERPA_PREFIX=/opt/sherpa-onnx rebar3 compile
```

Disabling the build does not change runtime configuration or delete an older
binary; also disable the native backend in `sys.config` if it will not be shipped.
Non-Linux builds do not enable these hooks. The root `native_voice` profile is
retained as an empty compatibility profile for older build commands. Its former
`pc` target is removed so only the app hook builds this worker.

No Python runtime is required. Keep the SDK libraries at the selected paths on
the runtime host; the worker's rpath uses them. The hook builds executable code;
model downloads remain the responsibility of the Erlang model-pull service.

For a development build, check:

```sh
test -x _build/default/lib/erm/priv/erm_native_voice
ldd _build/default/lib/erm/priv/erm_native_voice
command -v arecord
```

All libraries in the `ldd` output must resolve.
For a release, the executable must be included in that release's `erm/priv`
directory. Checking the development build does not check an installed release.

## Inspect the running node

```erlang
code:priv_dir(erm).
erm_native_voice:status().
maps:get(speech, maps:get(checks, erm_voice_health:check())).
```

After deploying this change and restarting the service, status includes `binary`,
`arecord`, `error` and `retry_in_ms`. An explicit native `binary` setting overrides
the application's `priv` path. Model downloads do not install executables or SDKs.

Example missing-file error:

```erlang
{executable_unavailable, binary, "/path/to/erm/priv/erm_native_voice", enoent}
```

Startup also distinguishes non-executable files and directories. If `open_port`
still returns `enoent` for an existing executable, check its ELF loader or script
interpreter; the error now retains the executable path. Missing shared libraries
may instead cause the spawned worker to exit.

Identical backend failures are logged once while retries continue every five
seconds. A changed failure is logged immediately, and readiness clears the error.
Building/installing the worker at the configured path lets the next retry recover.
Set `{backend_retry_ms, 10000}` inside the existing native options proplist to
change the retry interval; the supported range is 1000–3600000 ms.

Restart `erm_native_voice` after deploying this Erlang change: its state record has
an additional timer field. Do not just load the new BEAM into the old process.

## Focused verification

Run these from the project root with Erlang and a C compiler available:

```sh
sh apps/erm/test/native_voice_isolated/run.sh
sh apps/erm/test/voice_health_isolated/run.sh
sh apps/erm/test/native_build_isolated/run.sh
```

The isolated suites exercise executable validation, retry recovery, log
suppression, native protocol handling and health diagnostics. They use the
existing fake port; they do not validate real SDK linking or microphone input.
The native-build suite evaluates the real per-app config script and runs its
hooks and Makefile against fixture SDK/compiler tools. It covers first setup,
cached/offline builds, relinking, clean, failed linking and incomplete SDK
installation. It does not run the full DamageBDD dependency build or download
the real SDKs.
