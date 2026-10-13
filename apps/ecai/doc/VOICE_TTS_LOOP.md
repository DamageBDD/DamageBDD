# ECAI voice: interactive TTS / microphone loop

A local, turn-based test harness around the existing Erlang voice POC:

```text
consent -> enroll separate people -> collect separate calibration takes
        -> build a profile ONLY if calibration separates the voices
        -> spoken prompt -> playback finishes -> silence guard
        -> finite microphone recording -> Erlang matching -> spoken result
        -> repeat until q, Ctrl-C, the round limit, or the capture budget
```

Recognition remains in Erlang. Bash only coordinates the terminal, local TTS,
ALSA audio tools, subprocess deadlines, and session files. No Python, neural
model, cloud service, microphone subscription, or DamageBDD application startup
is used at runtime. Python is optional tooling for the **mock** orchestration tests.

**Validation:** 20 orchestration tests passed using mocked `erl`, `erlc`, TTS,
playback and capture commands. Real offline eSpeak WAV synthesis also passed.
The environment has no `erl`/`erlc` or physical audio access: native compilation,
EUnit, physical playback and microphone recording have NOT been run here. Read
`VOICE_TTS_LOOP_VALIDATION.md`; mocks do not validate acoustic recognition.

## Install the follow-up

The incremental `ecai-voice-tts-loop.patch` is for a tree with the preceding
`ecai-voice-erlang.patch` applied. From your DamageBDD repository root:

```bash
git apply --check ~/Downloads/ecai-voice-tts-loop.patch
git apply ~/Downloads/ecai-voice-tts-loop.patch

# On Debian/Ubuntu, assuming your Erlang compiler/crypto/EUnit are installed:
sudo apt-get install espeak-ng alsa-utils

# Native compiler/EUnit check, now including ecai_voice_loop_tests:
bash apps/ecai/test/run_voice_poc.sh test
```

For the original uploaded archive with **neither** voice patch applied, use
`ecai-voice-tts-loop-complete.patch` instead. Do not apply both patches. The source
ZIP contains the complete voice POC plus this loop, not the rest of DamageBDD.

Dependencies: Bash, Erlang/OTP 25+ (intended, not tested here), `erlc`, `crypto`,
EUnit, eSpeak NG (or eSpeak fallback), ALSA `arecord`/`aplay`, GNU `timeout`,
`flock`, and ordinary GNU file utilities. No added rebar dependencies. Run as
an ordinary desktop user with permission to access the sound devices, not root.

## Start a new recording session

List the microphone and playback devices first:

```bash
bash apps/ecai/test/run_voice_loop.sh --devices
```

Then:

```bash
bash apps/ecai/test/run_voice_loop.sh \
  --session _build/voice_live_01 \
  --speakers alice,bob \
  --device default \
  --playback default \
  --seconds 6
```

Use **two different people**, not two labels for yourself. Labels are 1–32 ASCII
letters/digits/underscores/hyphens, start with a letter/digit, and are case-sensitive.
`unknown` is reserved. Two to ten known people are supported by this harness.

The loop asks for recording/retention consent, then guides one enrollment and
one independent calibration take per person. At each take:

1. Press Enter when the named person is ready.
2. Listen to the instruction. The enrollment/calibration reading text is printed on screen, not spoken
   as a reference recording. Speak in your normal voice at `RECORDING`, for the
   full interval; continue naturally in your own words after finishing the text.
3. Inspect the quality result. Press Enter to keep, `r` to retry, `p` to replay the
   recording, or `q` to quit. Unusable audio is never accepted for development.

Enrollment/calibration phrases differ; all known people receive the same phrase
for a given phase/take number. This avoids deliberately encoding the speaker label
in the words being read. It does not establish text-independent accuracy.

A third, **unenrolled person** can provide an optional unknown calibration take.
Do not use silence, TTS playback, or a known person pretending to be another voice
as evidence of unknown-human rejection. A different unenrolled person is preferable
for later unknown testing.

For more reference observations, choose the counts when creating the session:

```bash
bash apps/ecai/test/run_voice_loop.sh \
  --session _build/voice_live_more_takes \
  --speakers alice,bob --enroll-takes 2 --calibrate-takes 2
```

Accepted development recordings and the take counts are retained. Interrupted
collection resumes without replacing accepted takes. To redo the experiment with
new reference recordings, use a new session directory. Do not tune against live
results and then describe those same takes as a held-out evaluation.

## Test, listen to the result, repeat

After successful calibration, the profile is frozen. The test prompt is:

```text
[test 1] Expected speaker / unknown / Enter / q:
```

Type a known label or `unknown` **before** capture to log your expected result;
press Enter for an unlabelled diagnostic. The loop speaks a question (for example,
"Describe something you did yesterday"), gives the recording-duration instruction, waits
for playback to finish, waits the silence guard, captures the WAV, runs the
Erlang matcher, prints the result and speaks `Voice match`, `Unknown voice`, or
`Insufficient usable speech`. Then it prompts for the next sample.

The result terms include distance, margin, thresholds, ranking, backend, the
curve/integer invariant check, expected label and diagnostic outcome where
available. These are **not confidence probabilities**. A reused development WAV
is flagged `development_audio_not_a_test`, not counted as a successful test.

All test WAVs are retained, including poor-quality samples; insufficient speech
is a result, not an instruction to enroll that sample. No test result is fed into
`build/1`, and no profile thresholds or templates are updated by this loop.

Resume with the existing profile:

```bash
bash apps/ecai/test/run_voice_loop.sh --session _build/voice_live_01
```

Automatically run ten test captures after the initial consent prompt:

```bash
bash apps/ecai/test/run_voice_loop.sh \
  --session _build/voice_live_01 --auto --rounds 10
```

`--auto` applies only to the TEST loop, never to enrollment acceptance. It requires
an explicit finite limit (1–100). Automatic takes have no expected-speaker label.
`--consent` explicitly acknowledges participant consent on the command line for
an operator-controlled unattended run; otherwise consent is requested each launch.
Ctrl-C cancels the loop and active external command. EOF or `q` at a prompt exits
without deleting anything. A session permits at most 200 recording attempts,
including rejected/partial attempts, before requiring a new session.

## Use an existing profile or the integer control

Import an existing compatible profile into a **new** session:

```bash
bash apps/ecai/test/run_voice_loop.sh \
  --session _build/voice_from_existing \
  --profile _build/my_voices.ecv
```

The source profile is validated and copied; it is not changed. Profiles requiring
stereo channel 1 or labels outside the loop's ASCII label format are rejected.
Synthetic-demo profiles are useful for exercising the workflow, not as reference
identities for human voices.

Use the integer matcher as a live control:

```bash
bash apps/ecai/test/run_voice_loop.sh \
  --session _build/voice_live_01 --backend integer
```

A new microphone take is not an exact backend comparison. To compare precisely
the same saved WAV, use the Erlang bridge with both backends:

```erlang
code:add_patha(filename:absname("_build/ecai_voice_poc/ebin")).
{ok, _} = application:ensure_all_started(crypto).

{ok, Curve} = ecai_voice_loop:score(
    "_build/voice_live_01",
    "_build/voice_live_01/tests/take-REPLACE.wav", <<"alice">>, curve).
{ok, Integer} = ecai_voice_loop:score(
    "_build/voice_live_01",
    "_build/voice_live_01/tests/take-REPLACE.wav", <<"alice">>, integer).

maps:get(best_distance, Curve) =:= maps:get(best_distance, Integer).
```

**Do not call `ecai_voice_loop:main/0` in your running application node:** it is a
CLI entry point and halts its VM. Use the ordinary API functions instead.

The direct `score/4` API returns a result; the CLI writes `.result.term` and
`.feedback.txt`. The existing `ecai_voice` curve backend already checks equality
against integer distances on every successful acoustic comparison. Insufficient
samples have no distance and no completed invariant check.

## Session files

```text
_build/voice_live_01/
  session.version                 Session marker, not executable configuration
  speakers.txt                    Plain-text known labels
  development-counts.txt          Enrollment/calibration take counts
  accepted.tsv                    Accepted filename -> original attempt mapping
  develop/                        Accepted development WAV hardlinks
  takes/                          All development attempts + metadata/quality logs
  voices.ecv                      Frozen profile; created only on successful build
  dataset.term                    Development-only manifest
  build.result.term               Profile-build result, including calibration failure
  tests/
    take-XXXXXXXX.wav              Newly captured raw evidence
    take-XXXXXXXX.wav.phrase.txt   Prompt shown on screen
    take-XXXXXXXX.wav.capture.txt  Expected label and recording configuration
    take-XXXXXXXX.wav.capture.log  arecord diagnostics, separate from WAV bytes
    take-XXXXXXXX.wav.result.term  Erlang result/error
    take-XXXXXXXX.wav.feedback.txt Spoken result text on successful scoring
    take-XXXXXXXX.wav.score.log    Native command output
  logs/                           Compiler, TTS, playback and profile diagnostics
  prompt/current.txt              Latest instruction/feedback text
  prompt/current.wav              Latest TTS output, NEVER used as an enrollment take
```

New session directories are owner-only (0700), and new files owner-only (0600).
Accepted development files are hardlinks to the kept original attempts, not
additional audio copies. Editing either link changes the other: treat captured
files as evidence and do not edit them. `accepted.tsv` records the relationship.
Reports are flushed to a temporary file and renamed into place. WAVs are closed
before matching; abrupt power loss can still leave partial audio or lose recent
filesystem changes. This is not a transactional audio archive.

The profile payload SHA-256 in each result identifies the deterministic serialized
profile used for that match; it is not the checksum of the enclosing `.ecv` file.
Hashes are provenance aids, not encryption. Protect the entire session as sensitive
voice data. No automatic deletion, publication or synchronization is performed.

## Safety boundaries and troubleshooting

**Use headphones and a real microphone, not a monitor/system-output source.** TTS
is first rendered to its own WAV, then played through `aplay`. Recording starts
only after playback succeeds and the silence guard elapses (default 750 ms,
configurable 250–5000 ms). This is software ordering, **not acoustic echo
cancellation** or proof that a room is silent. Increase `--settle-ms 1500` in a
reverberant room; avoid other audio sources during recordings.

Capture is finite `arecord` PCM16 little-endian, 16,000 Hz, mono, with fatal audio
errors enabled. Format and duration are checked by Erlang, including an early
zero-exit recording. The ALSA device may provide conversion; the matcher does not
silently accept a different WAV rate. `--device plughw:CARD=...,DEV=...` can be used
when appropriate; inspect `--devices` rather than guessing hardware identifiers.

TTS/ALSA/backend commands have separate deadlines, use literal argument arrays,
and cannot read the terminal input. A failed prompt, playback, capture, compiler,
profile validation or scorer stops the run rather than producing a guessed match.
GNU `timeout` forwards termination and applies a two-second kill escalation. The
session lock is not inherited by children. An uninterruptible kernel/device I/O
failure can still require operating-system intervention; no application can
promise immediate cancellation of that state.

A concurrent `ecai_mic_stream` or another recorder may already own the device.
This harness does not stop or alter those services automatically. Free the device
or select a separate capture PCM before retrying. It does not subscribe to
hash-only audio events or pretend to reconstruct raw speech from them.

If build returns `calibration_not_separable`, no matching profile is enabled.
Inspect `build.result.term` and the accepted WAVs. The acoustic representation is
still experimental; successful orchestration does not repair its demonstrated
human-speech limitations. A same-session interactive run is not a robust speaker
benchmark, and TTS challenge phrases are not liveness or anti-replay checks.
There is no transcription, precise diarization, overlap separation, or unknown
speaker clustering in this loop.

## Tests and source references

```bash
# Real OTP compilation and EUnit; run on your ECAI machine:
bash apps/ecai/test/run_voice_poc.sh test

# Real Bash orchestration, deliberately fake Erlang/audio commands; no microphone:
python3 apps/ecai/test/voice_loop/test_orchestration.py
```

The new EUnit module exercises labels, capture-duration rejection, development
manifest isolation, synthetic build/match, integer/curve agreement, reused-audio
flags, profile immutability and profile import. It remains unrun in this delivery.

Tool interfaces were checked against primary documentation:

- ALSA `arecord`/`aplay` manual: https://github.com/alsa-project/alsa-utils/blob/master/aplay/aplay.1
- eSpeak NG guide: https://github.com/espeak-ng/espeak-ng/blob/master/docs/guide.md

These references document the external tools, not ECAI recognition accuracy.
