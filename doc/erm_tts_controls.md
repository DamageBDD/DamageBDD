# Runtime voices, playful replies and speech volume

This rebased patch applies directly to the uploaded `latest-erm.tar(1).gz`
snapshot. Use it **instead of** `erm_tts_controls.patch`; no separate modern-catch
patch is needed. The snapshot already contains the native final-chunk fix.

The rebase preserves the current 120% speech volume as the runtime and legacy
native-protocol default, replaces the hard-coded player gain with runtime
control, and modernises the two remaining deprecated `catch` expressions.
It does not require a Python runtime.

## Install

From the DamageBDD project root:

```sh
git apply --check ~/Downloads/erm_tts_controls_rebased.patch
git apply ~/Downloads/erm_tts_controls_rebased.patch
PIPER_PREFIX=/opt/piper rebar3 as tts compile
```

Use your actual Piper SDK prefix. If the native build is already enabled in
another profile, use that profile. Rebuild **both Erlang and the native port**:
this patch adds per-request volume to the port protocol. Restart the application
once after installing it, because `erm_tts` gains record fields. After that,
changing voices or settings needs no application restart.

The existing hard-coded `--volume=120` edit is handled by this patch.
Do not remove it manually before applying.

## Persistent defaults

Merge this `tts` proplist into the existing `erm` application entry in sys.config:

```erlang
{tts, [
    {enabled, true},
    {auto_pull, true},
    {model_source, catalog},
    {voice, cori_medium},
    {personality, playful},
    {volume, 110},
    {volume_step, 10},
    {volume_max, 150}
]}
```

Preserve your existing binary, espeak-data and player settings if needed.
`model_source=catalog` uses the selected managed model even when old `model`,
`config`, or `PIPER_MODEL` settings exist. The backward-compatible default
`model_source=auto` honours explicit model files and `PIPER_MODEL`.

Defaults without new settings remain Lessac low, plain replies, volume 120,
step 10 and maximum 150. `volume` is an integer from 0 to `volume_max`;
`volume_max` is 100–200; `volume_step` is 1–100. Louder/quieter clamp at the
limits. Explicit out-of-range settings return an error without changing state.

Volume applies to the private speech playback subprocess. It never calls the
music player's volume API. The native worker supplies `--volume` and
`--volume-max=200` to its own mpv process. 100 is unity gain; above 100 amplifies
speech and may clip. A volume change applies to the next complete response;
all chunks of a response retain the volume with which that response began.

## Runtime API

```erlang
erm_tts:voices().
% [alba_medium,amy_medium,cori_medium,lessac_low,lessac_medium,ljspeech_high]

erm_tts:set_voice(cori_medium).             % select, pull if needed, reload
erm_tts:set_voice("Amy").                  % short alias for amy_medium
erm_tts:reload().                          % reopen with current runtime settings
erm_tts:reload([{voice,alba_medium}, {volume,120}, {personality,playful}]).
erm_tts:set_personality(playful).           % or plain
erm_tts:set_volume(120).
erm_tts:louder().
erm_tts:quieter().
erm_tts:say("Hello Steven. The voice system is ready.").
erm_tts:repeat().
erm_tts:repeat(louder).
erm_tts:status().
erm_tts:diagnostics().
erm_model_pull:status().
```

`set_voice/1` accepts a listed atom, its string/binary name, or Amy, Cori, Alba,
Lessac and LJSpeech aliases. Spoken names can replace underscores with spaces.
Custom atom IDs from the running model pull catalog also work. Unknown names
are rejected before changing the current backend; text never creates atoms
or supplies download URLs.

Selecting a catalog voice explicitly clears old model/config overrides and
uses the managed downloader. All six built-in manifests are pinned to upstream
revision `c10ece1aade47bb51c153c893d14e5bf8e5b7117`, with byte counts and SHA-256
verification for ONNX, JSON and the model card. Existing Lessac cache identity
is unchanged. Downloads happen on demand; they do not all run at startup.
Read each downloaded MODEL_CARD for the voice's source and licensing details.

| ID | Language | Quality | Short name |
| --- | --- | --- | --- |
| lessac_low | US English | low | Lessac |
| lessac_medium | US English | medium | Lessac medium |
| amy_medium | US English | medium | Amy |
| cori_medium | British English | medium | Cori |
| alba_medium | British English | medium | Alba |
| ljspeech_high | US English | high | LJSpeech |

Reload and voice selection stop current speech, clear queued chunks, and
return `ok` when the request is accepted. They do not wait for a model download
or native readiness. Check `ready` and `last_error` in status. A download may
also wait for an existing model pull to finish. Failed downloads retain the
pipeline's explicit retry policy:

```erlang
erm_model_pull:retry(cori_medium).
erm_tts:reload().
```

`reload/0` reopens the current runtime options. It does not reread sys.config
from disk. To apply a changed application environment, use
`erm_tts:reload(application:get_env(erm,tts,[]))`. Changes made through runtime
APIs last until the TTS service restarts; put desired defaults in sys.config.
To return to an explicit file, use `reload/1` with `model` and `config` paths
(and `model_source=auto` if passing a full configuration).

## Spoken controls

Use the configured wake word and normal listening boundaries:

| Say | Effect |
| --- | --- |
| Hey Bob, repeat louder | Increase speech volume one step and replay the last completed response |
| Hey Bob, repeat | Replay the last completed response at current speech volume |
| Hey Bob, repeat quieter | Decrease speech volume one step and replay |
| Hey Bob, speak louder | Increase volume for subsequent speech |
| Hey Bob, speak quieter | Decrease volume for subsequent speech |
| Hey Bob, voice volume 120 | Set speech volume to 120 |
| Hey Bob, change voice to Amy | Select/download/reload Amy medium |
| Hey Bob, reload voice | Reopen the current voice backend |
| Hey Bob, be playful | Enable playful replies |
| Hey Bob, be plain | Restore plain replies |

These are deterministic commands: no model classification or network call is
needed to parse them. Music commands such as `volume 50` retain their existing
meaning. Controls do not generate an extra “Done” response, so they do not
replace the response being repeated. Voice readiness is logged once when the
backend starts. A normal subsequent reply demonstrates the selected voice.

Replay stores at most the existing 1200-character response limit in memory,
only after **every** chunk has played successfully. It synthesizes that same
text in the currently selected voice. It never re-executes the original media
or custom action, and never asks Ollama to regenerate the answer. Failed or
cancelled speech preserves the previous completed response. Replay is rejected
while busy/not ready; a rejected replay does not increase volume. Restarting
TTS clears the remembered response; reloading a voice preserves it.

Wait for playback and the existing echo guard to finish before using the wake
word again. This patch retains microphone suppression during speech; it does
not add barge-in. A spoken command is also subject to existing wake/dedupe rules.

## Personality

Playful mode uses short deterministic acknowledgements for successful media
commands, for example “Stopped. Peace at last.” Failures remain failures.
Ollama/ECAI answers get a brief playful style instruction while retaining the
original factual, source and action constraints. Classification prompts are
unchanged. `say/1` speaks exactly the text supplied; it does not rewrite it.
Piper still uses its voice model's normal synthesis settings; this adds wording
style, not an emotional/sarcasm control to the acoustic model.

## Verification

From the project root:

```sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
sh apps/erm/test/model_pull_isolated/run.sh
sh apps/erm/test/voice/run.sh
sh apps/erm/test/ollama_pull/run.sh
```

The isolated TTS suite builds the actual C++ worker against the official
`piper.h` with a fake inference engine and WAV-checking player. It verifies
final-chunk handling, protocol limits, player gain, complete replay, failed
playback, busy rejection, reload, catalog precedence, and real Erlang voice
routing. The model pull suite uses real OTP HTTPS against a local test server.
The voice and Ollama suites cover existing wake, media and pull behavior.

No live microphone, installed Piper SDK/model inference, or physical speaker
playback was available here; audition the chosen voice on the target host.

Upstream references: [mpv audio options](https://mpv.io/manual/stable/#audio),
[Piper voice catalog](https://huggingface.co/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117),
and [voice samples](https://rhasspy.github.io/piper-samples/).
