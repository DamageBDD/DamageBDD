# erm native phrase synthesis and recognition lab

Experimental phrase-synthesis extension, rebased with recognition onto
`latest-erm.tar(9).gz`. Included in the combined `erm-voice-rebased.patch`.

**Release gate:** Native fixtures and audio-core sanitizers passed. Erlang
compilation/EUnit and the real SDK/microphone/speaker loop were not run here.
Keep observation mode enabled and pass the supplied Erlang runner before activation.

## What is shared, and what is not

A new, explicitly labelled microphone take produces two representations from the
**same VAD-delimited PCM segment**:

* the existing 13-coefficient MFCC sequence for phrase recognition; and
* an `ELS1` synthesis sidecar: sixteen LPC reflection coefficients, pitch,
  voicing and energy per 10 ms frame.

The original phrase profiles contain MFCCs only. They are not a reversible audio
codec, and this implementation does not invent the missing pitch/excitation.
Existing profiles remain usable for recognition, but need fresh labelled takes
in the lab to acquire synthesis sidecars.

The new C++ source–filter vocoder reconstructs an enrolled **whole phrase** from
its synthesis parameters. It stores neither raw PCM nor the original residual
waveform. It does not concatenate arbitrary words, implement general text-to-
speech, train a neural voice model, or replace Piper for arbitrary replies.
Audible intelligibility, resemblance to the source speaker and handheld latency
have not been validated. Good classifier distance is not evidence of good sound.

MFCC reconstruction with added pitch/source–filter information has precedent in
Milner & Shao, “Speech reconstruction from mel-frequency cepstral coefficients
using a source-filter model”, ICSLP 2002, DOI 10.21437/ICSLP.2002-110. This patch
uses a separate LPC analysis of the original utterance, not their exact method.

## Apply and build

The combined patch applies both phrase recognition and this synthesis lab to
the uploaded source archive. Do not apply the earlier patches first. The
ordered two-patch series in the delivery is an alternative to the combined
patch; never apply both forms. No remote branch was substituted for your source.
Do not force rejected hunks on a different working tree.

```sh
git apply --check ~/Downloads/erm-voice-rebased.patch &&
git apply ~/Downloads/erm-voice-rebased.patch
```

From the complete DamageBDD checkout, run:

```sh
set -e
sh apps/erm/test/phrase_lab_isolated/run_native.sh
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
ERM_NATIVE_VOICE_AUTO_SETUP=0 \
  sh apps/erm/scripts/build_native_voice.sh compile
rebar3 compile
```

The existing native build/clean hook now builds and cleans both executables.
`rebar.config.script` registers both artifacts while preserving the native-build
opt-out and the separate opt-in share bridge. The build integration tests use
local SDK fixtures, including SDK paths containing spaces; they do not download
or validate real speech SDKs.

The first native runner needs C/C++, pthreads and Python 3 **for test fixtures
only**. Production needs no Python. Use `SANITIZE=1 sh .../run_native.sh` to also
run AddressSanitizer/UndefinedBehaviorSanitizer on both audio algorithm suites.
The Erlang runner needs the complete checkout, including
`apps/erm/src/erm_native_voice.erl`, plus Erlang/EUnit. Do not activate until it
and your normal build pass.

Preserve the native voice SDK prefixes, VAD/speaker models, microphone device,
owner profile and calibrated speaker threshold already used on your node.
The independent synthesis helper has no Whisper, Piper or sherpa SDK dependency.
The existing microphone worker still needs its normal native SDK build/link
setup, although phrase modes never initialize or invoke Whisper.

## Opt in and reserve the current microphone

Inside your existing `whisper_trigger` -> `phrases` options, add:

```erlang
{lab_enabled, true},
{observe_only, true}
```

Keep `{backend, phrases}`. Merge these options; do not create another `erm`
application entry, replace your native settings, or disable speaker verification.
Restart using your normal release/application procedure: the new coordinator
record layout and protocol require a restart, not an isolated hot module load.

With lab enabled, the worker advertises protocol 6. With lab disabled, the
existing phrase backend remains protocol 5. The original Whisper backend remains
protocol 4. Ordinary phrase enrolment is unchanged and creates no synthesis data.

From a trusted local Erlang shell:

```erlang
erm_phrase_voice:pause().
erm_phrase_voice:status().
%% Wait for ready=true and processing=false, then:
erm_phrase_lab:start().
```

The lab is a temporary supervised child of `erm_sup`. It takes a monitored,
exclusive lease from `erm_phrase_voice`; it does not open a second microphone.
The lease forces observation and pause for command dispatch. Attempts to enable
commands, resume ordinary capture, enrol normally or forget templates during a
lab session are rejected.

Default synthesis helper: `code:priv_dir(erm)/erm_phrase_lab`; default player:
`/usr/bin/aplay`; playback device: `default`. The corpus is `roundtrip.elab` beside
your configured phrase profile. Override with explicit trusted local options:

```erlang
erm_phrase_lab:start(#{
    player => "/usr/bin/aplay",
    device => "default",
    corpus_file => "/var/lib/damage/voice/phrases/roundtrip-01.elab"
}).
```

Use only one of the two start examples. `binary` can also specify an absolute
path to your built `erm_phrase_lab` helper. Set `device` to the speaker/headset
output paired with the existing native microphone; this option does not change
microphone capture configuration. Begin with a low physical output volume.

## Collect shared-source human training takes

```erlang
erm_phrase_lab:record(stop_music, train).
erm_phrase_lab:status().
```

The returned prompt specifies the complete phrase (for example “bob stop music”).
Wait for `phase => listening` before speaking. The same native audio thread
acknowledges that its gate/VAD has reset; a timer guess is not used as readiness.
One completed VAD utterance closes capture. Poll status until `phase => idle` and
`last` reports a recorded take. Speak naturally and remain below the configured
segment cap (at most eight seconds).

Repeat that request **one take at a time**, obtaining three to five distinct
human takes. Then explicitly install their MFCCs into the recognizer:

```erlang
erm_phrase_lab:train(stop_music).
erm_phrase_voice:status().
```

Wait for readiness after the profile revision acknowledgement. Repeat for other
needed allowlisted actions: `pause_music`, `play_music`, `next_track`,
`previous_track`. Failed same-segment speaker/quality checks cannot enter training.
No recognition result is used as its own training label. Phrase identity is the
human-supplied label; speaker verification cannot establish what was said.

### Diagnose a rejected recording

The recording response includes `min_speaker_ms` and `max_segment_ms` alongside
the complete `say` prompt. These are limits for the captured VAD segment;
waiting longer before or after speaking does not guarantee a longer segment.

After a rejected training take, `erm_phrase_lab:status()` now retains:

```erlang
%% Illustrative values, not measurements from your microphone:
#{last => #{outcome => human_sample_rejected,
            reason => audio_too_short,
            verification => {error, audio_too_short},
            check => #{accepted => false, audio_ms => 640, frames => 62,
                       quality => #{rms_dbfs => -24.0, clipped_fraction => 0.0},
                       thresholds => #{min_speaker_ms => 1200}}}}.
```

Other reasons identify quiet audio, clipping, missing phrase features, missing
or invalid speaker embeddings, mismatched embedding dimensions, or a speaker
score below the configured threshold. When computed, `speaker_score` is included
with its threshold. `erm_phrase_voice:status()` also retains the latest lab check.
The status measurements exclude embeddings, MFCC features and synthesis data.
The voice widget displays a short rejection message when it observes
`erm_phrase_lab` events (the default `sources => all` includes them).

For a short take, repeat the complete prompt as one naturally connected phrase
at a measured pace. For quiet or clipped audio, check microphone placement and
gain. For a failed speaker match, check the selected device and enrolled speaker
profile. The diagnostics patch does not change acceptance thresholds.

Training with fewer than three accepted human takes returns
`insufficient_training_samples` with accepted/minimum/maximum counts. Cycle and
sweep with no source at the requested index return `missing_training_sample`
with the available count. Neither operation creates missing training data.
Only proceed after status shows accepted recordings in the training corpus.

After applying the diagnostics patch and compiling, the two updated modules
can be reloaded without restarting native capture: their process record layouts
and native protocol are unchanged. Stop the lab first to release its lease:

```erlang
erm_phrase_lab:stop().
l(erm_phrase_voice).
l(erm_phrase_lab).
erm_phrase_voice:pause().
erm_phrase_lab:start().
erm_phrase_lab:status().
%% Wait for capture.echo_guard_remaining_ms=0, ready=true and processing=false.
erm_phrase_lab:record(stop_music, train).
%% Wait for listening, speak the returned prompt, then inspect status again.
```

Old rejected recordings cannot be diagnosed retroactively: their verification
details were discarded. Record a fresh take after loading the patch.

## Keep independent human evaluation data

Record new takes in `validation` and `test`, never copies of training samples:

```erlang
erm_phrase_lab:record(stop_music, validation).
%% Wait for listening, speak, then wait for idle before another request.
erm_phrase_lab:record(unknown, validation).
```

For an `unknown` take, use unrelated speech or a deliberate negative such as
“Bob, do not stop music”, not the positive command. Repeat separately for `test`.
Cover omitted wake words, near-matching actions, different distances, noise and
consenting other speakers. The recognizer is whole-phrase matching: it does not
independently understand a wake word or negation.

For calibration, collect at least two fresh validation takes for each enrolled
action and five unknown phrases. These minimums enable a proposal; they are NOT
evidence of a production-quality error rate. Use a substantially broader, separate
final test before enabling actions. Do not repeatedly optimize against the final
test set and still call it unseen.

Exact MFCC fingerprints cannot cross corpus splits. Evaluation recording also
rejects exact copies of currently installed recognition templates. Near-duplicate
replay and incorrect labels cannot be identified reliably by those checks.
Validation/test data retains failed speaker/quality checks rather than silently
excluding difficult examples; the two reported metrics distinguish content from
combined capture-time eligibility. Nontraining takes retain MFCCs, not synthesis
sidecars. A VAD timeout or invalid feature segment is a recording failure, not a
scored utterance: track such failures separately when measuring end-to-end use.

## Run the round trip

```erlang
{ok, Run1} = erm_phrase_lab:cycle(stop_music, 1, #{acoustic => true}).
erm_phrase_lab:status().
erm_phrase_lab:report().
```

The index selects that action's human training take, starting at 1. This performs:

1. Native whole-phrase resynthesis from its sidecar.
2. Digital MFCC/DTW evaluation against the frozen current recognition bank.
3. A new one-shot capture through the existing native worker, armed and
   acknowledged before playback begins.
4. Playback through a dedicated native child, and evaluation of the first
   captured VAD segment. Both player completion and capture completion are needed.

The acoustic report gives the command-content result and speaker/quality
verification separately. The generated voice is not assumed to pass the owner
check. It is never routed to a media action and never stored in the human corpus.
A capture is attributed to the first VAD segment during the trial, not proven to
contain the entire generated phrase or only the generated phrase. Use a quiet,
controlled setup and listen to what was actually played. Background speech or
speaker-to-microphone echo can confound the measurement.

`#{acoustic => false}` skips hardware playback/capture and reports only the
in-memory round trip. An accepted digital match proves only that this classifier
accepted that reconstruction; it does not prove semantic understanding, good
speech, speaker identity, robustness, or improvement on human speech.

After an acoustic run completes, attach your actual listening assessment:

```erlang
erm_phrase_lab:rate(Run1, #{intelligible => true, quality => 3}).
erm_phrase_lab:export_report(
    "/var/lib/damage/voice/phrases/roundtrip-01-report.term").
```

The rating values above are examples, not observations. Quality is 1–5. Use
`intelligible => false` for unintelligible speech even when recognition succeeds.
Only the last report is held in memory; export each report you intend to compare.
Reports contain no raw WAV or synthesis model. The source fingerprint and profile
hash allow attribution; they are not an authenticity signature.

## Bounded improvement, not a self-confirming feedback loop

```erlang
erm_phrase_lab:sweep(stop_music, 1).
%% After status returns to idle:
erm_phrase_lab:report().
```

The sweep compares nine in-memory settings: pitch scales 0.95/1.0/1.05 and noise
mixes 0.05/0.15/0.25, at speed 1.0. It ranks training-cycle results and reports
settings; it does not adopt them. Listen to a candidate through `cycle/3` with the
chosen `pitch`, `noise` and optional `speed` before judging synthesis quality.
Controls are bounded: speed 0.85–1.15, pitch 0.8–1.2, noise 0–0.3. Output exceeding
eight seconds is rejected instead of truncated.

For recognition, use real held-out validation takes:

```erlang
erm_phrase_lab:calibrate().
%% After completion:
erm_phrase_lab:report().
```

This searches a small distance/margin grid. Its proposal prioritizes avoiding
false activations and wrong commands, then reducing misses. It uses human
validation only, not synthetic audio and not the final test set. It never changes
speaker thresholds, recognition thresholds or active templates automatically.
An empty or insufficient evaluation is explicitly not a pass.

Check the proposed distance/margin against the separate human test set:

```erlang
%% Substitute the actual proposed values; these are example numbers only.
erm_phrase_lab:evaluate(test, #{max_distance => 0.30, min_margin => 0.08}).
```

Also compare the unchanged baseline with `erm_phrase_lab:evaluate(test).`
Keep synthesis listening results, acoustic-loop results, human recognition errors
and false activations separate. Improvement in one does not guarantee improvement
in the others. New human recordings and explicit `train/1` are the only training
promotion path. Synthetic results are evaluation-only, even if they score well.
For a new recording campaign after a corpus reaches its caps, stop and start with
a new `corpus_file`, retaining the old corpus/reports for comparison.

This is a measured, human-reviewed iteration loop, not a proof of convergence or
a joint learned ASR/TTS model. It deliberately does not train itself until it
recognizes its own artifacts.

## Cancellation, privacy and return to normal operation

```erlang
erm_phrase_lab:cancel().
erm_phrase_lab:stop().
erm_phrase_voice:status().
```

Cancelling kills the monitored/linked helper worker and closes the native port.
The native helper monitors EOF while processing and sets parent-death killing
for its dedicated player. Owner death releases the microphone lease. Cancellation,
lab exit or backend failure leaves normal command handling paused and in
observation mode; it does not silently restore command execution. A six-second
echo guard follows cancellation/release and acoustic capture completion. Status
reports its remaining duration. Do not overlap another TTS source with a trial;
existing TTS suppression is still enforced and aborts conflicting captures.

Only after completing independent human tests, and once the echo guard is clear:

```erlang
erm_phrase_voice:resume().
%% Continue observe-only checks before explicitly enabling media actions:
erm_phrase_voice:observe_only(false).
```

No live auto-enable is performed by the lab. Speaker matching has no replay or
liveness protection; recordings or generated speech may match. Do not use it as
the sole authority for payments, secrets or other sensitive operations.

The corpus is a bounded, versioned, SHA-256 checked local file (maximum 8 MiB and
150 takes), bound to the existing speaker/device/wake profile. Training is capped
at five takes per action; held-out positives at ten/action/split; unknowns at
twenty/split. Files are written atomically with mode 0600 in a private directory;
unsafe paths and incompatible profiles are rejected. This is access control, NOT
encryption. LPC, pitch and MFCC data remains biometric-derived and sensitive even
without original recordings. Keep it local and remove unwanted corpus files
while the lab is stopped.

The native output has finite/range checks, peak limiting and edge fades, but
numeric amplitude does not set safe acoustic loudness. Keep hardware volume low.
Generated WAV exists transiently in memory/memfd; it is not written to the corpus.
The runtime remains Erlang plus bounded C++ ports. There is no Python service or
new network endpoint. This increment adds a local-shell test driver, not a new
GTK screen, and does not modify the older native enrolment/tuning UI or Piper.

## Validation scope

On the uploaded latest-source baseline, native tests exercise the
real C++ algorithms/ports against synthetic input and fake SDK/device boundaries:
16 prior phrase-core checks, 12 synthesis-core checks, six prior protocol checks
and nine new protocol/lifecycle checks, plus five real build-hook checks
using local SDK fixtures. Both audio cores also passed ASan/UBSan.
These tests do not measure real speech quality, VAD accuracy, liveness, actual SDK
linking, Steam Deck timing or battery use.

The environment used to prepare this patch had no `erl`/`erlc`. Erlang compilation
and EUnit were NOT RUN. The included strict runner covers production lab modules,
corpus/metrics/lease fixtures and prior phrase policy tests. A separate VM
also checks the current production intent routes, supervisor selection and rebar
artifact configuration instead of test doubles. It must pass on your
node before activation. The complete live Erlang -> SDK -> microphone -> speaker
round trip remains to be tested on your target hardware. See the delivery's
`validation/` logs for exact checks and results.
