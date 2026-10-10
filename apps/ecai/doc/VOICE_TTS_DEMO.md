# ECAI/ERM: One human + one TTS speaker (interactive Erlang demo)

For operators with **one human speaker only**, use **TTS as an explicitly
synthetic second speaker**. The test is a controlled two-source pipeline check,
not validation of two human identities, human diarization, anti-spoofing, or
unknown-voice rejection.

## Shell commands

Apply the TTS add-on patch after the existing ECAI/ERM voice and calibration
fixes. Compile and hot-load the new and changed modules from the repository root:

```erlang
c("apps/ecai/src/ecai_voice_tts.erl").
c("apps/ecai/src/ecai_voice_session.erl").
c("apps/erm/src/erm_voice_loop.erl").

%% One command: consent, microphone human enrollment, generated TTS
%% enrollment, separate calibration, then a continuous *interactive* test loop.
erm_voice_loop:tts_demo().
```

You need the original `ecai_voice`, `ecai_voice_loop`, `ecai_voice_wav`, and
feature/curve support modules compiled and visible on the same Erlang node.
Run this from an interactive Erlang shell attached to a machine with working
`espeak-ng`, `aplay`, `arecord`, microphone, and playback. Use headphones.

The default session is separate from a previous all-microphone session:
`$XDG_STATE_HOME/ecai/voice-tts-demo`, or
`$HOME/.local/state/ecai/voice-tts-demo`.
The original `~/.local/state/ecai/voice` session and its `steven`/`steve`
labels are not reused or modified.

To name the human explicitly or change the TTS voice:

```erlang
erm_voice_loop:tts_demo(#{
    speakers => [<<"steven">>, <<"tts_demo">>],
    tts_speaker => <<"tts_demo">>,
    tts_voice => "en+f3",
    tts_speed => 155,
    seconds => 8,
    enroll_takes => 2,
    calibrate_takes => 2,
    unknown_calibration => no
}).
```

The TTS voice ID and speaker/source mode are pinned in a private session
manifest; attempts to resume with a different voice ID or replace that
synthetic label with microphone captures are rejected. For a different voice,
create a new session path. If you already started a demo with the default
`human` label, do not switch it to `steven` at the same session path.

## How the loop runs

1. A consent prompt appears. Only continue with consenting speakers.
2. `human`: display a short reading passage; press Enter to record your real
   microphone, then listen/retry/accept.
3. `tts_demo`: automatically synthesize a *different* short text at `en+f3`
   into a WAV. **No sound-card loopback is used.** Erlang performs deterministic
   PCM resampling/padding to 16 kHz mono/PCM16, and checks the same acoustic
   frontend as human recordings.
4. Repeat separate development recordings for `calibrate`; no training test
   samples are reused in calibration.
5. Calibration must be separable. Failure remains a visible failure and does
   not silently relax thresholds. If successful, a persisted profile is saved.
6. At `Expected speaker [human,tts_demo/unknown]`, type `human` to record the
   microphone, or `tts_demo` to **synthesize and classify a fresh held-out
   synthetic utterance**. Type `q` to quit; rerun `tts_demo()` to resume.

Because TTS is synthesized directly into a valid WAV, it cannot be captured
accidentally through the system's microphone when labeling a synthetic test.
It exercises the waveform decoder, acoustic descriptor, elliptic comparison,
calibration and identity assignment. It does **not** exercise the microphone
capture chain for the synthetic branch.

With no third independent voice, default `unknown_calibration => no` is used;
unknown rejection has not been independently validated.

## Reading script (printed during capture)

Read at a natural volume, use a consistent microphone position, and wait until
the TTS *instruction* stops before speaking. **Do not play the synthetic TTS
sample into your microphone.**

**Enrollment, take 1:**

> I am reading this sentence clearly, using my usual speaking voice.

**Enrollment, take 2:**

> The small garden behind the house looks peaceful in the morning.

**Calibration, take 1:**

> This different sentence checks how my voice sounds on another recording.

**Calibration, take 2:**

> Blue morning light slowly appeared above the roofs across the street.

**Interactive test, first human prompt:**

> The afternoon sunshine reached the steps beside my front door.

The prompt sequence is implemented in `ecai_voice_tts:script/3`; further
rounds use alternate passages. A `.script.txt` sidecar accompanies each
accepted development take. TTS syntheses use *different* phrases from human
recordings and never share byte-identical enrollment and calibration WAVs.

## Troubleshooting

- `invalid_tts_voice`: pass an eSpeak-compatible voice name; see
  `espeak-ng --voices` (e.g., `en+f3`).
- `tts_audio_too_long`: shorten the passage or increase `seconds` (up to 30),
  **in a new session** if you are changing saved recordings.
- `unusable_synthetic_audio`: the same quality rules reject silent, clipped,
  too-short or out-of-range synthetic audio.
- `calibration_not_separable`: inspect the displayed distances or run
  `erm_voice_loop:diagnose(SessionDirectory)` if you have the optional
  diagnostics patch. This is an acoustic-front-end limitation, not permission
  to widen the matching threshold.
- `session_source_mode_mismatch`: use the voice and speaker source originally
  chosen for this session, or start a new directory.
- `session_speakers_mismatch`: a different speaker set cannot reuse the old
  profile; choose another session path.

## Tests

```bash
bash apps/ecai/test/run_voice_poc.sh test
```

The new `ecai_voice_tts_tests` verify script uniqueness, 22.05 kHz-to-16 kHz
normalization, padding, invalid formats, overflow rejection, and options.
No physical microphone or eSpeak command is needed for these pure tests.

The Erlang-native tests must be run on your Erlang node; they were not run by
the authoring environment when this patch was produced. The synthetic audio
alone is not evidence of real-world speaker recognition accuracy.
