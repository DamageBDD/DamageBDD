# Enrolled native phrase commands

Experimental, speaker-specific recognition of a small fixed command vocabulary.
This is an optional `backend = phrases` for erm, not general dictation and not a
claim of a new elliptic-curve speech decoder. Phrase matching uses native MFCC
sequences and bounded dynamic time warping (DTW). No Whisper model is loaded or
invoked in this mode. Existing Whisper mode remains available without changing
its protocol-4 behavior.

## Scope and source basis

This edition is rebased onto the supplied `latest-erm.tar(9).gz` source
archive. The current supervisor's voice-router and model-pull startup order,
optional services, display-manager separation and share-bridge configuration
are retained. Only the shared C++ microphone worker, the phrase backend selection
and the related build/test integration change; the existing
`erm_native_voice.erl`, voice guide, enrollment/tuning UI and MPV code are not
replaced.

The combined delivery is `erm-voice-rebased.patch`. Its two ordered component
patches are an alternative, not additional patches to apply afterwards. Use
`git apply --check` against your working tree and never force rejected hunks.

This version deliberately chooses one microphone owner. Switching between
`native` and `phrases` requires restarting the erm application/release using your
normal deployment process. There is no simultaneous second capture stream, no
unreviewed Whisper/Ollama fallback, and no UI patch in this increment.

## Commands

| Action ID | Suggested full enrolled phrase | Local media action |
| --- | --- | --- |
| `stop_music` | Bob stop music | Stop |
| `pause_music` | Bob pause music | Pause |
| `play_music` | Bob play music | Play/resume |
| `next_track` | Bob next track | Next playlist track |
| `previous_track` | Bob previous track | Previous playlist track |

Exactly one configured wake phrase is used as the enrollment prompt prefix.
The recognizer matches the WHOLE recorded utterance; it does not independently
transcribe or verify that you said "Bob" or the displayed words. Labeling an
enrollment sample is a trusted local-user operation. Record the requested phrase
consistently, including its prefix. Speaker embeddings are used only to verify
the same speaker, never to recognize the command content.

Nothing maps microphone input into a function name, atom, shell command or
model-generated action. Successful matches select one of the five fixed command
IDs. Before calling `erm_voice:command/1`, the adapter checks that the installed
`erm_voice_intent` parses its canonical text as the expected local media action.
A missing/changed intent route fails instead of sending unfamiliar text to a model.

## Install

From the project root, with your current voice SDKs already installed:

```sh
git apply --check ~/Downloads/erm-voice-rebased.patch
git apply ~/Downloads/erm-voice-rebased.patch

sh apps/erm/test/phrase_voice_isolated/run_native.sh
sh apps/erm/test/phrase_voice_isolated/run_erlang.sh

# This is your existing native voice build hook; retain your actual SDK prefixes.
ERM_NATIVE_VOICE_AUTO_SETUP=0 sh apps/erm/scripts/build_native_voice.sh compile
rebar3 compile
```

Stop if any check fails. Native tests require a C/C++ toolchain and Python 3;
Erlang tests require OTP with EUnit and crypto. Python is only a test harness;
there is no added Python runtime service.

The shared executable still links the existing Whisper SDK. Phrase-only mode
skips Whisper initialization and inference and does not require a Whisper model
file. Silero VAD and the sherpa-onnx speaker model are still required and are still
learned models. This is not a wholly model-free audio stack.

Before enabling the phrase backend, finish speaker enrollment/calibration under
the existing native backend. Preserve its `profile_file`, `speaker_model`, device
and measured `speaker_threshold`. Phrase mode refuses `require_speaker = false`
and refuses a missing, stale or non-private owner profile. It does not download
models or lower the speaker threshold automatically.

Merge `config/sys.config.phrase_voice.fragment.config` into your EXISTING erm
configuration. Preserve voice/media/TTS settings. The example's `0.7` speaker
threshold is a placeholder, not a measured security threshold. The new phrase
thresholds are also provisional; begin with `observe_only = true`.

The important configuration change is:

```erlang
{backend, phrases}
```

After the normal application/release restart:

```erlang
erm_phrase_voice:status().
```

Wait for `ready => true`, `phase => ready`, and `listening => true`. The backend
requires the new protocol-5 phrase handshake; an older native binary fails closed.
`erm_native_voice:status()` is not the status API while the phrase backend owns
capture. Existing Piper playback can remain enabled.

## Enroll phrases

Pause music and other playback. In a trusted local Erlang shell:

```erlang
erm_phrase_voice:enrol(stop_music, 3).
```

It returns the phrase prompt and requested sample count. Speak that complete
phrase three separate times, waiting for `listening => true` and an increased
`enrolment.collected` count between takes:

```erlang
erm_phrase_voice:status().
```

There are no newly added spoken prompts or beeps in this version; use the returned
prompt and status. Samples are captured only after enrollment is requested and
must pass speaker, duration and quality checks. All normal command execution is
blocked during enrollment. The timeout is three minutes. Three to five samples
are supported per command. Exact duplicate serialized feature samples are
rejected, but this does not establish liveness or stop a varied replay.

After the last accepted sample, the complete command template set is atomically
saved and loaded into the native worker under a new profile revision. A failed
save leaves the previous templates intact. A failed worker load after a successful
save retains the committed revision for reconnect. Incomplete enrollment never
replaces an existing command profile. Recognition does not learn from itself.

Enroll the remaining actions one at a time:

```erlang
erm_phrase_voice:enrol(pause_music, 3).
% Complete those three takes before starting the next action.
erm_phrase_voice:enrol(play_music, 3).
erm_phrase_voice:enrol(next_track, 3).
erm_phrase_voice:enrol(previous_track, 3).
```

Operational controls:

```erlang
erm_phrase_voice:cancel_enrol(). % Preserve all previously saved templates.
erm_phrase_voice:pause().        % Invalidate capture; no phrase actions.
erm_phrase_voice:resume().
erm_phrase_voice:forget(previous_track). % Persistently remove just that command.
```

The native speaker duration floor is preserved. A quickly spoken phrase may be
rejected as too short; read `last` and `audio_ms` before changing thresholds. Do
not relax speaker verification merely to make a short command pass.

## Observe and calibrate before dispatch

Keep `observe_only = true` and try held-out recordings/takes, not just enrollment
samples. Read `last.reason`, `distance`, `margin`, `speaker_score`, `quality` and
`outcome` in `status()`. Distances are dissimilarities, not calibrated confidence
probabilities; lower distance is better. Margin is the runner-up distance minus
the winning distance. With only one eligible action, there is no runner-up and
margin is represented by the sentinel `1000.0`; that is NOT extra evidence.

Test each command across several sessions, microphone distances, speaking rates,
background fan noise and normal room conditions. Explicitly test silence, music,
unrelated speech, someone else speaking, wake-only utterances, commands without
the prefix and negations such as "Bob, do not stop music". Acoustic matching does
not understand negation. A nearby wrong phrase may still match; unknown-speech
rejection is a threshold mechanism, not a guarantee against every unseen input.
A small positive-only template bank needs negative testing before activation.

Only after these tests are satisfactory, enable dispatch from the trusted shell:

```erlang
erm_phrase_voice:observe_only(false).
```

This changes runtime state, not `sys.config`. Keeping the configuration default
in observation mode makes a supervisor process restart return to observation.
To return immediately:

```erlang
erm_phrase_voice:observe_only(true).
```

Every mode, pause and enrollment transition invalidates the capture epoch.
Commands also require the current port, utterance ID, profile revision and a
speaker verification result from that same segment. TTS suppression is checked
again before dispatch. Results are one-shot; there is no queued transcription
backlog or automatic retry after an uncertain command delivery. A cooldown limits
repeated accepted actions. The existing voice coordinator still owns media
permissions, busy handling, priorities and speech feedback.

## Storage and bounds

Only MFCC feature sequences are persisted, not raw PCM or transcripts. Treat
these templates and the existing owner embedding as sensitive biometric-derived
data; no claim of anonymity or irreversibility is made. They are not published to
IPFS, Nostr, ECAI indices or remote services.

The new template file is private (0600) inside a private directory (0700). It is
versioned and bound to the speaker profile/model hash, capture device identifier,
wake prefix and feature version. A changed binding fails closed and requires
re-enrollment. A checksum detects corruption; it is not an authentication MAC
against someone who can rewrite local files. Parent directories and the local
Erlang administration boundary must be trusted. Voice alone does not authorize
payments, credentials, destructive operations or other sensitive actions; none
are in this command vocabulary. Recorded owner speech can pass the speaker gate.

Capture is fixed at 16 kHz mono. Completed segments are limited to eight seconds;
MFCC sequences are capped at 160 frames of 13 float32 coefficients. At most five
commands times five templates are stored. The maximum serialized native profile
is under 210 kB, excluding speaker/VAD models and runtime memory. The algorithm
uses whole-sequence endpoint-constrained, slope-banded DTW and the two best
eligible templates per action. It requires an absolute distance threshold and a
runner-up margin. An unknown or ambiguous result causes no action. There is no
Whisper fallback in this increment.

## Validation and remaining acceptance work

Executed in the build environment:

- 16 native feature/classifier/profile tests passed, including 1,000 randomized
  malformed profile payloads within one test case.
- 6 native-worker protocol tests passed against synthetic capture and fake
  external model SDKs. A fixture aborts if phrase mode initializes or calls Whisper.
- Feature tests also passed with AddressSanitizer and UndefinedBehaviorSanitizer.
- The actual modified C++ worker compiled with `-Wall -Wextra -Werror` against
  the SDK fixtures. These are boundary tests, not real model linking tests.

Erlang compilation and EUnit were NOT RUN here because `erl` and `erlc` were not
available. The runner reports this explicitly and exits 127. Its tests cover the
codec/private profile boundary and coordinator observation, dispatch, speaker
mismatch, short audio, ambiguity, stale epochs, TTS suppression, enrollment,
duplicate samples, cancellation and malformed-worker responses. The native
speaker math is the production module; command/intent delivery is a fixture.

Before deployment, run both suites and `rebar3 compile` against the current tree,
then build with the real SDKs and perform live acoustic acceptance. No measured
recognition accuracy, Steam Deck latency, power use, or battery improvement is
claimed by this patch. Re-run the existing native-voice tests to protect guided
speaker enrollment/tuning behavior in your installed version.
