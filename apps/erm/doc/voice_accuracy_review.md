# Voice enrolment and recognition review

Source basis: the supplied ERM source with the motion, training, profiles and
explicit-enrolment patches, and `latest-ecai.tar(3).gz`. This is a source review
and a workflow regression fix, not a measured live-microphone accuracy result.

## What the reported screen means

The screen shows an active `steven (2)` enrolment draft: one of five samples
accepted, one rejected. Start enrolment and Re-enrol are unavailable while that
draft exists; Record sample is enabled. Start opens the workflow. Each Record
sample click opens one capture; wait for Speak now before speaking.

The second sample passed duration (2886 ms), loudness (−26.4 dBFS) and clipping
(0%). It failed new-sample consistency: cosine similarity 0.654, required 0.700.
This is a comparison with the first accepted sample, not the old saved voice
and not a 65.4% probability of identity. Passing those audio checks does not
establish a clean or well-segmented speaker embedding.

The first accepted unit embedding anchors the draft. Subsequent embeddings
must agree with the preceding mean and all accepted samples must agree with
the proposed combined mean. Rejected samples do not modify the reference.
That prevents a candidate from making itself pass by being included in the
mean before comparison, but makes a poor first sample difficult to recover from.

## This patch

- Adds Restart samples to the active draft. It discards only that draft's
  unsaved samples, preserves its name and target, and returns to the first
  prompt. It does not delete saved voices, change thresholds or record audio
  automatically.
- Cancels the current owned capture before restarting, changes the draft ID,
  and rejects stale requests, timers and native results.
- Keeps the active enrolment name and progress visible after a rejection.
- Explains an empty phrase bank and distinguishes recorded takes from committed
  templates. Three or more recorded takes still require Train phrase.
- Shows the closest command, distance, margin and configured phrase limits for
  distance/ambiguity failures. Speaker verification is shown separately from
  phrase recognition.
- Regression-tests the existing first-sample display. Its missing prior score
  was already handled in the previous patch; it was not a confirmed bug.

The draft still has a three-minute deadline from Start or Restart. Save after
five accepted samples. If consistency failures persist after a fresh reference,
inspect the input device, model and captured speech; repeatedly restarting is
not a substitute for calibration.

## Which recognizer is running?

| Stage | ERM GTK phrase widget | Separate ECAI voice experiment |
| --- | --- | --- |
| Capture | Native 16 kHz mono capture, Silero VAD, one microphone owner | Bounded 16 kHz PCM/WAV; shell/live wrappers record local takes |
| Speaker features | Configured sherpa-onnx neural embedding model | Hand-crafted MFCC and pitch statistics |
| Speaker matching | Normalized embeddings, cosine gate | Nearest enrolled speaker template by quantized L1 distance |
| Command content | Whole-utterance MFCC/DTW matching of five fixed actions | No transcription or command recognizer |
| Wake phrase | Prefix within each full command template | No independent wake-word recognizer in this experiment |
| Learning | Explicit speaker references and human phrase templates | Explicit enrolment and separate calibration records |

`erm_native_voice.cpp` skips Whisper initialization in phrase-only mode. It
extracts speaker embeddings and phrase features from the VAD segment.
`erm_phrase_voice.erl` gates accepted commands on quality, identity, phrase
distance, margin, current profile revision, playback/echo state and dispatch
mode. The model catalogue defaults to NeMo Speakernet, but the screenshot's
256-dimensional embedding alone does not identify the configured model.
Enrolment averages extracted embeddings; it does not retrain model weights.

The general voice/intent and ECAI query routes are separate. An ECAI-branded
widget does not mean the elliptic-curve experiment is decoding its commands.

## Why previously recorded phrases may not match

1. **No templates in the active context.** The screenshot shows zero takes and
   zero trained templates. Templates/corpus are bound to the full speaker
   profile (including model identity), device and wake phrase. Saving a newly
   enrolled voice creates a different bank. Select the previous voice and the
   same wake to recover its bank, or train commands for the new voice.
2. **Recording is not committing.** Record 3–5 accepted, distinct human takes
   of the displayed full phrase, then Train phrase. Speaker enrolment sentences
   never become command templates.
3. **Speaker rejection is independent.** A phrase can have a good acoustic
   match and still fail the speaker check. Ambient `accept/2` currently records
   a speaker-rejection tuple instead of retaining native phrase details; the
   lab's verification result exposes both for diagnosis.
4. **Duration eligibility precedes DTW.** A query/template duration ratio must
   be 0.60–1.67, with at least two eligible templates for an action. Otherwise
   even a trained bank can yield `no_eligible_templates`.
5. **Distance and ambiguity gates.** Classification averages the two nearest
   eligible DTW distances per action. It requires a small enough best distance
   and a large enough gap to the competing action. The example defaults 0.35
   and 0.08 are not measurements of this microphone/user. With only one eligible
   action, the large margin sentinel is not evidence of broad discrimination.
6. **Recognition and dispatch differ.** A lab session pauses command dispatch.
   Ending it does not automatically resume ambient commands or disable
   observe-only mode. Inspect status before interpreting silence as no match.

The current frontend uses 25 ms Hamming windows, 20 ms hops, 26 mel filters,
13 MFCC coefficients excluding energy, and at most 160 time frames. It has no
cepstral normalization or delta features. It matches the complete sound pattern,
not the lexical meaning of the label, negation, or a separately verified wake
word. The user assigning a training label is responsible for saying that phrase.

## What the ECAI curve implementation does

`ecai_voice_features.erl` builds 30 coordinates: 13 MFCC medians, 13 MFCC
interquartile ranges, three log-pitch quantiles and voiced-frame fraction.
Its frontend uses 40 ms frames with 10 ms hops and an energy/periodicity gate.
Coordinates are multiplied by 32, rounded and clamped to ±255.

`ecai_voice_curve.erl` maps each integer coordinate to a secp256k1 point `q_i G`.
For comparison it subtracts points, recovers the bounded integer difference
through lookup, and sums absolute differences:

```
curve_distance(q, r) = sum(abs(q_i - r_i)) = integer_L1_distance(q, r)
```

`ecai_voice:compare/4` explicitly checks that equality. The two backends must
therefore produce the same ranking and decisions for the same features,
templates and thresholds. The curve layer currently provides an arithmetic
representation experiment, not additional acoustic discrimination or encryption.
Changing curve arithmetic cannot recover information absent from the features.

Each speaker is scored by its single nearest template. Separate calibration
recordings determine radius and margin, and non-separable calibration fails.
Held-out test recordings are excluded from building and calibration. These are
useful evaluation boundaries. However, the interactive defaults of one enrolment
and one calibration take per speaker provide little coverage of real variation.
Pooled statistics also remove temporal word order, so this representation is a
speaker-matching baseline rather than a phrase recognizer.

## Accuracy work, in order

1. **Measure the actual failure stage.** Keep quality, speaker consistency,
   speaker verification, phrase eligibility/distance/margin and dispatch status
   separate. Expose model identifier, selected input and context/template counts.
   The diagnostic UI changes here address part of this first step.
2. **Collect real calibration and held-out recordings.** Use consistent device
   settings initially, then include other distances and separate sessions. Include
   other speakers, unrelated speech, near-confusable commands and playback/noise.
   Evaluate false accepts, false rejects, per-command confusion and latency;
   measure wake false activations per hour on continuous negative audio.
3. **Calibrate speaker checks separately.** A universal cosine threshold is not
   justified. `erm_phrase_lab:calibrate/0` currently proposes phrase distance and
   margin only; it does not tune speaker identity or enrolment consistency. A
   robust batch enrolment that collects quality-valid samples, identifies an
   internally consistent group and shows outliers is worth evaluating. Do not
   silently lower 0.7 or replace the initial reference with a rejected sample.
4. **Evaluate improvements to the small DTW recognizer.** Compare endpoint
   trimming, cepstral normalization, temporal features, better varied templates
   and per-command thresholds on the same held-out data. Short commands sharing
   a large common prefix can be hard to separate. Frontend changes need a new
   feature version and rebuilt templates; no accuracy gain is assumed.
5. **Separate wake detection from command content.** A configurable keyword
   spotter can detect the wake phrase, followed by bounded command recognition
   and speaker verification on enough speech. Sherpa supports custom keyword
   lists and per-keyword boosting/trigger settings. These tune a false-trigger
   tradeoff; they are not a substitute for evaluation. General speech can use
   ASR with an allowlisted intent mapping. Keep an explicit unknown outcome.
6. **Benchmark speaker frontends.** Compare the configured model with suitable
   ECAPA/ResNet alternatives on this user's recordings, including latency. For
   ECAI, compare its float summaries, quantized summaries and a neural embedding
   frontend. Integer and curve versions of identical quantized features should
   remain equivalent. Also compare nearest-template versus robust multi-template
   aggregation rather than assuming more templates always improve accuracy.
7. **Improve context continuity explicitly.** A future migration/revalidation
   flow could reuse suitable command samples after speaker re-enrolment. This
   patch preserves separate banks and never silently treats old identity-bound
   samples as verified under a new identity.

Wake-word training can improve detection only when it trains or calibrates an
actual wake detector with positive and negative examples. Today changing the
wake field selects full-phrase prompts and a bank; it trains no such detector.

The existing phrase lab can collect `record(Action, validation)` and
`record(unknown, validation)`. Its calibration proposal requires at least two
validation samples per enrolled action and five unknown phrases. Use fresh
`test` samples after selecting thresholds. Synthetic round trips are useful for
regressions but are not evidence of microphone or human recognition accuracy.

## Applying this increment

Apply on top of `erm-voice-explicit-enrolment.patch`, not the original archive:

```sh
git apply --check ~/Downloads/erm-voice-enrolment-recovery.patch
git apply ~/Downloads/erm-voice-enrolment-recovery.patch
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
sh apps/erm/test/voice_widget_training/run.sh
rebar3 compile
```

The native GTK check requires Xvfb/xdotool or `MOTION_USE_DISPLAY=1` with a test
display. The phrase policy tests use an external fake audio peer. This increment
changes no C++ matching or model files.

After compilation, stop the widget and any shell-started lab before loading the
changed modules; an active lab record must not survive this update:

```erlang
erm_voice_widget:stop().
case whereis(erm_phrase_lab) of
    undefined -> ok;
    _ -> erm_phrase_lab:stop()
end.
code:load_file(erm_phrase_lab).
code:load_file(erm_voice_training).
code:load_file(erm_voice_widget).
erm_voice_widget:start().
```

This ends any unsaved enrolment draft. Saved profiles and phrase banks remain.
Re-enrol, record five accepted samples, Save voice, then record and train each
full command. A normal release restart is an alternative to the shell reload.

Validation here: 45 phrase/lab tests, three integration tests and eight widget
tests passed. The widget tests include native GTK pointer clicks through the
reported consistency rejection, restart, five samples, save and verification.
Native audio/embedding packets are deterministic fixtures; no live microphone,
model accuracy benchmark or full project `rebar3 compile` was run here.

## Primary references for proposed alternatives

- Sherpa configurable keyword spotting:
  https://k2-fsa.github.io/sherpa/onnx/kws/index.html
- Sherpa speaker identification and model catalogue:
  https://k2-fsa.github.io/sherpa/onnx/speaker-identification/
- ECAPA-TDNN paper (candidate architecture, not a result on this setup):
  https://arxiv.org/abs/2005.07143

Local source anchors: `erm_native_voice.cpp`, `erm_phrase_features.h`,
`erm_native_voice:enrolment_check/3`, `erm_voice_profiles:binding/3`,
`erm_phrase_voice:accept/2`, `erm_phrase_lab_metrics:recommend/3`,
`ecai_voice_features:extract/1`, `ecai_voice:compare/4` and
`ecai_voice_curve:distance/3`.
