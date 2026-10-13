# Native Piper responses for erm (Linux)

This adds an optional supervised `erm_tts` service to the existing voice-command
implementation. No Python interpreter, pip package, or Python server is used.
The C++ executable links to OHF-Voice's `libpiper`, loads the ONNX voice once,
and keeps it resident across normal responses. Each spoken response uses a
separate MPV process, with no connection to the music player's IPC or playlist.

## Build and configure

Prerequisites: Linux, C++17 compiler, make, CMake, git, the native libpiper build
dependencies and MPV. Follow the upstream native build instructions:
https://github.com/OHF-Voice/piper1-gpl/tree/main/libpiper

Example native install (choose a writable absolute prefix):

```sh
git clone https://github.com/OHF-Voice/piper1-gpl.git
cmake -S piper1-gpl/libpiper -B piper1-gpl/libpiper/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/piper \
  -DCMAKE_INSTALL_LIBDIR=lib
cmake --build piper1-gpl/libpiper/build --parallel
cmake --install piper1-gpl/libpiper/build
make -C apps/erm/c_src PIPER_PREFIX=/opt/piper
```

The upstream build supplies ONNX Runtime and eSpeak NG; these are native
runtime dependencies. This bundle does not redistribute them. libpiper is
GPL-3.0; check the selected voice's model card for its license. Record the
upstream revision used by your deployment.

Download a Piper `.onnx` voice plus its matching `.onnx.json`. A low-quality
voice is a reasonable starting point for short confirmations; measure latency
on your machine. Set the absolute paths in
`config/erm_voice.sys.config.example`, merging the `{tts, [...]}` entry into the
existing `erm` application configuration. The upstream CMake layout places
voice phonemizer data at `/opt/piper/share/espeak-ng-data`. Keep your existing
Whisper binary/model/capture settings.

Rebuild erm with your normal Erlang build, and restart it. If your application
resource has an explicitly maintained modules list, add `erm_tts` there.
TTS is disabled when its config is omitted. Invalid backend paths do not stop
the music application: the speech service reports an error and retries every
five seconds. A missing or non-executable player is reported on first speech.

```erlang
erm_tts:status().
erm_tts:say("Ready, Bob.").
erm_tts:cancel().
```

`status/0` reports readiness, speaking state, microphone suppression and the last
error. `say/1` accepts Unicode text up to 1,200 characters, rejects NULs and words
longer than 240 characters, and returns `ok`, `{error, busy}`, `{error, not_ready}`
or a validation error. Successful submission is asynchronous; check status for
playback failures. Responses split at word boundaries into at most 240-character
chunks, played sequentially. There is one response in flight and no stale
speech queue: overlapping automatic replies are dropped. Answers longer than
the cap remain in voice status but are not spoken. This does not stream Ollama
tokens; speech begins after the complete answer arrives.

## Command integration and listening boundary

Successful voice actions speak short confirmations, song selection speaks the
title, and Ollama/ECAI answers speak their answer text. Generic failures receive
a short failure response; busy/cancelled results are silent. Text is passed as
framed data, never a shell command. Native output is bounded to 16 MB per chunk.
Audio lives in an anonymous Linux memory file, with no temporary WAV files.

Listening is half duplex. The TTS service clears pending microphone context
before synthesis and suppresses both voice-command input and legacy trigger
callbacks until speech finishes plus a cooldown. The cooldown is at least the
configured Whisper `length_ms + keep_ms + step_ms`, or `echo_guard_ms` (default
6,000 ms), whichever is larger. This lets Whisper's rolling audio context drain.
Partial transcripts and duplicate history received during suppression are
cleared. A bounded suppression lease survives a TTS service crash, without
muting input permanently. Configure these durations to match the actual capture
window if you use custom Whisper arguments.

A spoken stop/cancel cannot interrupt TTS during this listening pause. Call
`erm_tts:cancel/0` from a button or Erlang control instead. Cancellation closes
the native port; the input reader immediately exits even during inference,
and Linux kills its dedicated player child. The next connection reloads the
model. Speech timeout has the same cleanup behavior. Closing the BEAM port on
shutdown also terminates the native process. Music continues independently;
audio ducking and acoustic echo cancellation are not implemented.

## Validation

```sh
sh verification/voice/run.sh
PIPER_INCLUDE=/opt/piper/include sh verification/tts/run.sh
```

The native lifecycle tests compile the actual worker against a fake Piper
implementation and the official header. They verify WAV framing, Unicode/text
bounds, readiness, overload rejection, speech suppression, inference and player
cancellation, synthesis errors, timeout cleanup, and reconnection. Existing
voice/media/Ollama/ECAI tests use their isolated fixtures. The supplied work was
compiled and tested under OTP 25 and g++; real Piper inference, actual speakers,
and target-machine latency still need a live smoke test with your chosen model.
