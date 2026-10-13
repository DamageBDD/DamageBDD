# ERM-managed native voice

This optional Linux backend replaces `whisper_trigger_srv` microphone capture with
`erm_native_voice`, a supervised Erlang service owning a persistent C++ port.
The port loads whisper.cpp, Silero VAD and a sherpa-onnx speaker embedding model
once. It owns an `arecord` subprocess for 16 kHz mono capture. There is no Python
runtime, HTTP service, or external Whisper daemon to manage.

The same VAD-delimited PCM segment supplies both the transcript and the speaker
embedding. Only a verified, addressed utterance reaches `erm_voice:command/1`,
so the existing fast media actions and ECAI/Ollama planning remain in use.
The legacy backend remains the default unless `backend` is explicitly `native`.

## Build and configure

Apply the accompanying incremental patch from the DamageBDD project root. It
expects the preceding voice/boundary/Piper integration. It only adds a native
branch in `erm_sup` and an optional profile in `rebar.config`; keep newer local
changes if either hunk needs rebasing.

Install `git`, CMake, make, a C++17 compiler and ALSA `arecord` (`alsa-utils` on
Arch). Build the SDKs as a normal user, using identical prefixes when compiling
the port. For example:

```sh
export WHISPER_PREFIX="$HOME/.local/erm-voice/whisper"
export SHERPA_PREFIX="$HOME/.local/erm-voice/sherpa-onnx"
sh apps/erm/scripts/setup_native_voice.sh
rebar3 as native_voice compile
# With existing Piper TTS enabled:
# PIPER_PREFIX=/opt/piper rebar3 as prod,tts,native_voice release
```

The SDK installer pins upstream source commits, retains its build directory on
failure, and disables discovery of a system ONNX Runtime. Sherpa's own dependency
build selects its matching runtime. Keep these libraries separate from Piper's
SDK, and do not inject another ONNX library through `LD_LIBRARY_PATH`. The binary
embeds the chosen library paths; those paths must exist on the runtime host.
The script installs into the selected prefixes; use fresh prefixes for upgrades.
It does not download models or change your system packages.

Obtain these three compatible model files:

* A whisper.cpp GGML model, e.g. `ggml-base.en.bin` for English. See
  https://github.com/ggml-org/whisper.cpp/tree/master/models .
* Silero VAD ONNX model supported by sherpa-onnx. See
  https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html .
* A sherpa-onnx-compatible speaker identification embedding model. An arbitrary
  ONNX file is not sufficient. See
  https://k2-fsa.github.io/sherpa/onnx/speaker-identification/index.html .

Merge `config/sys.config.native_voice.fragment.config` into the existing `erm`
entry in `sys.config`. Preserve your current `voice` options for Ollama and media
routing. Set absolute model paths, a microphone device, a writable profile path,
and ensure the service user can read models/SDKs and access the microphone.
`binary` defaults to the executable in ERM's installed `priv` directory.

The example starts in `observe_only` mode: it measures verification but dispatches
no commands. `speaker_threshold = 0.7` is a provisional example, **not a calibrated
security threshold**. Config changes require restarting this service/application;
it does not hot-reload environment values.

## Enrol and calibrate

From a trusted local Erlang shell:

```erlang
erm_native_voice:status().
erm_native_voice:enrol("steven", 5).
%% Speak five separate phrases, each roughly 2–4 seconds long, with pauses.
erm_native_voice:status().
%% To abandon enrolment:
%% erm_native_voice:cancel_enrol().
```

Enrolment accepts 3–10 samples within two minutes. It rejects short audio and
samples inconsistent with earlier samples. Only the locally requested enrolment
session can replace the stored profile; recognition never updates it. Samples
are normalised and averaged. The profile is written atomically with mode 0600
and includes the embedding model SHA-256. A changed model or embedding dimension
invalidates the profile and requires enrolment again. Only one speaker profile
is supported in this initial backend.

With `observe_only = true`, collect scores from your voice at normal distances,
background sound, and other consenting speakers. `status()` reports the last
verification/observation or rejection; debug logs include mismatched scores.
Choose a threshold that separates these measurements. If distributions overlap,
improve capture/model choice instead of assuming a threshold can fix it. Then
set `observe_only = false` and restart. `require_speaker = false` explicitly
bypasses verification, so leave it true for the enrolled-speaker workflow.

Say **“Hey Bob, stop music” as one utterance**. A wake-only segment followed by a
separate command is rejected: speaker permission is never carried over between
segments. A pause longer than `silence_ms` (default 700 ms) ends the segment.
`min_speaker_ms` defaults to 1200 ms; very short commands can be rejected because
they contain too little audio for verification. Tune using measured results.

## Lifecycle and diagnostics

`erm_native_voice:status()` reports readiness, mute/busy state, enrolment progress,
last result, and backend errors. Native events use logger domain
`[erm, voice, native]`, which can share your existing voice handler's parent-domain
filter. Verify that the handler accepts subdomains if its filter is exact-match.
Native library stderr goes to the application's stderr/journal; it is kept out of
the framed protocol. Set `debug_utterances = true` only when transcript text is
needed for diagnostics. Raw audio and embeddings are never logged or saved.

On a port crash or watchdog timeout the service closes the port, rejects pending
work, and reconnects after five seconds. Startup allows 120 seconds by default;
inference allows 30 seconds. Tune `startup_timeout_ms`/`inference_timeout_ms` for
your machine. The capture child is killed by Linux when its native parent exits.
Stopping the Erlang service closes the port; EOF terminates the native process.

TTS suppression reuses `{erm_tts, suppress_until}`. Mute transitions invalidate
in-flight utterances through an epoch counter, reset VAD, and discard captured
speech while TTS plays. Results received during suppression are also rejected.
There is no queued transcription backlog: segments arriving while inference is
busy are dropped with a diagnostic. Commands longer than `max_segment_ms`
(default 8 seconds) are discarded. This backend does not invoke the legacy
speech-trigger callback or supply the old Whisper UI status API.

Speaker embeddings are a convenience filter, not replay protection. Recordings
of an enrolled speaker can match. This first version does not perform speaker
turn segmentation or detect overlapping speakers, and should not authorise
sensitive actions solely on a matching voice. Use a separate confirmation factor
for such actions. Neither Whisper text nor Ollama establishes speaker identity.

## Verification

```sh
sh apps/erm/test/native_voice_isolated/run.sh
```

Tests run in a fresh VM with a C packet-protocol peer and an isolated coordinator
fixture. They check protocol validation, enrolment, persisted profiles, mismatches,
short audio, wake boundaries, epoch/mute rejection, deduplication and port failure.
Fixture modules have `.erl.src` extensions to keep them out of rebar's recursive
production/test compilation. Existing voice tests remain separate.

The delivered implementation was syntax-checked against upstream native headers
and exercised with deterministic protocol fixtures. SDK linking, microphone/VAD
behaviour, transcription accuracy and speaker thresholds still need a live test
on the target host. Source pins used by the installer are recorded in that script.
