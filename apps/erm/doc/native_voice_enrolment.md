# Guided speaker enrolment

`erm_native_voice:enrol("steven", 3)` now uses the same prompt/cue coordinator
as acoustic tuning. It works before a profile exists. The native enrolment
validator and atomic profile writer are shared with the existing implementation.

## Install after the enrolment-prompts patch

```sh
git apply --check ~/Downloads/erm_native_voice_enrolment_retry.patch &&
git apply ~/Downloads/erm_native_voice_enrolment_retry.patch &&
rebar3 compile
```

This incremental patch requires `erm_native_voice_enrolment_prompts.patch`.
The existing compile hook rebuilds the native worker with protocol 4. If that
hook is absent in a custom build, run
`sh apps/erm/scripts/build_native_voice.sh compile` too. TTS and the models are
unchanged. Cancel any active guide or manual enrolment before loading the
callbacks, then reconnect to start the rebuilt worker:

```erlang
erm_voice_tune:cancel().
erm_native_voice:cancel_enrol().
l(erm_voice_tune).
l(erm_native_voice).
erm_native_voice:reconnect().
%% Wait for ready => true, native_protocol => 4 and
%% acoustic_config => #{state => applied} before starting:
erm_native_voice:status().
erm_native_voice:enrol("steven", 3).
```

An unused coordinator returns `{error, not_started}` from its `cancel/0`; continue
with the remaining commands. The Erlang record layouts have not changed.
The new Erlang code also supports protocol-3 workers: enrolment still works,
but skipping transcription requires rebuilding and reconnecting the worker.
Use the normal release-upgrade process for an installed release.

## What you hear

The first prompt is “Voice enrolment. Sample 1 of 3. After the beep…” followed
by a short sentence. It varies the sentence after each accepted sample.

- The rising beep opens a response window. Speak naturally after it.
- The falling beep confirms detection has ended, before inference finishes.
- “Accepted” advances to the next sample. A short sample, missing embedding or
  inconsistent sample gets a specific retry prompt without advancing the count.
- A rejection now says, for example, “No match. Repeat that sentence”, then
  beeps. It does not reread the sample number and sentence. The full sentence
  remains in `erm_voice_tune:status()` under `active.expected_phrase`.
- “Voice profile saved. You're ready” follows a successful atomic save.
- Expiry and save failures have their own spoken messages when TTS is available.

No wake word is required for enrolment samples. Keep music/other audio quiet,
use your usual microphone distance and volume, and read each sentence naturally.
The final confirmation remains inside the command gate, even after the profile
has been saved. Prompts and cue audio are excluded from enrolment capture.

```erlang
erm_voice_tune:status().        % phase, prompt, expected_phrase, counts, last_report
erm_native_voice:status().      % enrolment checks and guidance => enrolment
erm_native_voice:cancel_enrol().
```

The shared guide allows one activity at a time. Starting tuning during enrolment
returns `enrollment_active`; starting enrolment during tuning returns
`tuning_active`. Cancelling enrolment does not cancel a tuning trial.

## Short pauses and concise feedback

During exclusive native guidance, speech uses a **150 ms** post-playback guard
instead of the rolling Whisper guard (normally 6000 ms). The coordinator checks
speech completion every 20 ms and retries readiness every 25 ms. A completed
prompt immediately attempts the ready cue, rather than waiting for the next
poll. Both tuning and enrolment benefit. These are configured/software delays,
not measured end-to-end audio latency; playback startup, inference and the
configured VAD silence interval still take time.

Protocol 4 requests an embedding-only, one-shot capture for guided enrolment.
It uses the same audio, speaker extractor, quality checks and enrolment validator,
but does not run Whisper transcription for that sample. Tuning still transcribes
to check the wake phrase; normal command recognition is unchanged. Whisper is
still loaded at native startup. The native capture gate remains closed through
the detection-end cue and feedback, including when an embedding arrives before
the end cue has finished.

The listening log now has numeric timing instead of repeating the spoken prompt:

- `speech_wait_ms`: TTS queuing/retries, synthesis, playback and the echo guard.
- `arm_wait_ms`: from prompt completion to acceptance of the ready-cue request.
- `cue_ms`: from acceptance of that request until the listening gate is opened.
- `ready_ms`: total prompt-start to listening time, including the three above.
- `listen_ms` on detection-end: response-window duration, including your reaction
  time and VAD endpoint silence; use `audio_ms` for the captured segment length.
- `detection_to_result_ms`: time from the guide receiving detection-end to the
  validation result. With older/manual sources lacking a detection-end event,
  this starts at result arrival and does not measure inference time.

These timings do not separately measure synthesis and playback. Hardware
latency and real-world speaker accuracy must be measured on the running system.

The current effective guard is `echo_guard_ms` in `erm_tts:status()`. Configure
`guided_echo_guard_ms` in the existing TTS options; supported values are 0–2000
ms. For example, to remove the additional speech-to-cue pause:

```erlang
%% Do this between sessions; reload restarts the TTS port once.
erm_tts:reload([{guided_echo_guard_ms, 0}]).
%% Wait for ready => true and cue_ready => true, then enrol again.
```

The ready cue still has its 80 ms silent tail and capture opens after player
completion. If speaker echo leaks into a recording, raise this guard. The short
guard applies only while live native guidance owns capture; normal rolling
Whisper suppression keeps its existing settings. This does not add acoustic
echo cancellation or silently change VAD/speaker thresholds.

## Options and limits

`enrol/3` accepts a map or standard proplist:

```erlang
erm_native_voice:enrol("steven", 3, [{timeout_ms, 240000}]).
erm_native_voice:enrol("steven", 3, #{tts => false}).  % beeps, logged prompts
erm_native_voice:enrol("steven", 3, #{tts => false, cues => false}).
```

The sample count remains 3–10. `tts` and `cues` default to true. The deadline is
three minutes by default (`timeout_ms`: 1000–600000), covering prompts, responses
and inference. At most three attempts per required sample are collected. A final
announcement gets up to 15 additional seconds with capture closed. Cue failures
stop the session; they do not silently open the microphone.

Rejected samples are not added to the profile. Cancellation, expiry, failed
cues and coordinator death clear the unfinished enrolment. An existing saved
profile remains unchanged unless all required samples have already passed and
the replacement was successfully written. Cancellation cannot undo a completed
save: the final report's `profile_saved` flag records that case explicitly.

Reports in `erm_voice_tune:history()` distinguish `kind => enrolment` from tuning
and include accepted/rejected counts, save status and numeric checks. They do
not store recordings, recognised transcripts or embedding vectors. Notifications
are correlated by session reference so late results from a cancelled session
cannot affect the next one.

## Diagnose enrolment consistency

`enrolment_inconsistent` means a new normalized speaker embedding failed an
enrollment consistency check. The threshold is `enrolment_threshold` in the
native options. If omitted at startup, it inherits `speaker_threshold` (0.7 by
default). Live verification-threshold changes do not change enrollment strictness.

Enrollment compares a candidate against the normalized mean of the samples
already accepted, matching how commands are checked against the saved profile.
The candidate is excluded from that comparison so it cannot improve its own
score. The first sample establishes the reference. When a candidate passes,
every sample must also match the updated mean at the same threshold. This
prevents incremental updates from leaving an earlier accepted sample below the
threshold. A rejected sample is not added, and earlier samples are retained.

This replaces the stricter requirement that every pair of samples match.
Individual utterances can fail a pairwise comparison while matching the profile
used by the runtime. It changes enrollment acceptance, without changing the
command verification threshold or treating low-scoring candidates as verified.

The diagnostic update reports each enrollment decision with sample duration,
threshold and similarity scores:

- `method => centroid`: enrollment uses the averaged profile.
- `candidate_score`: similarity to the existing mean, before adding the sample.
- `profile_min_score`: lowest sample-to-profile score after the proposed update;
  only calculated when the candidate passes the first check.
- `failed_check`: `candidate_score` or `profile_consistency` on a mismatch.
- `min_score` and `scores`: retained pairwise diagnostics, not the acceptance
  criterion. `scores` follows accepted samples in reverse arrival order.
- `id`, `quality`, `embedding_dim`, `min_audio_ms`: now present in accepted and
  rejected enrolment logs, status and reports. `quality` reports RMS/peak dBFS,
  clipped-sample fraction and input gain; older packets report `unavailable`.
- `retry_similarity`: comparison with up to two previous consecutive inconsistent
  retries, newest first, with `compared_samples`, `scores` and `min_score`.
  Acceptance or a different rejection reason clears that comparison window.

Retry comparisons are diagnostic only. A low candidate score and high retry
similarity indicates those retries resemble one another while disagreeing with
the accepted reference. It does not identify the rightful speaker or prove that
the first sample is wrong. Low retry similarity suggests the rejected recordings
are also inconsistent with one another. Neither result changes either threshold
or replaces an accepted sample. Only two rejected vectors are kept temporarily
in the enrolment draft; cancellation, completion or expiry clears them. They
are never written to the profile, logs or guide reports.

For example, several scores near 0.46 against sample 1 alone do not establish
that those retries match one another. Use `retry_similarity` and `quality` to
investigate that ambiguity before changing capture settings. Rejected audio
with over 1% clipped samples or RMS below -40 dBFS gets a short spoken level
hint; these hints do not automatically change microphone gain or acceptance.

The first sample has no `candidate_score` or pairwise `min_score` comparison,
so both values are `undefined`. Logs contain no embeddings or transcript text.

For example, with two accepted samples whose mutual score is 0.721411, a
candidate scoring 0.693091 and 0.718844 against them scores approximately
0.760952 against their normalized mean. It therefore passes a 0.7 candidate
threshold even though one pairwise score is below 0.7. A 614 ms fragment still
fails the default 1200 ms audio-duration floor.

Check the running node:

```erlang
maps:with([ready, muted, processing, speaker_settings, enrolment, last],
          erm_native_voice:status()).
```

`speaker_settings` reports the configured capture device, duration floor,
verification requirement and threshold. While enrollment is active, `enrolment`
includes `collected`, `target`, `rejected`, `remaining_ms` and `last_check`.
Rejection counts include short audio and invalid/missing embeddings, not just
speaker mismatch. An `insufficient_audio` check shows both the sample duration
and embedding dimensions so a missing embedding can be distinguished from a
short segment. The existing `last` result is preserved for callers.

To discard a possibly poor first sample and start fresh:

```erlang
erm_native_voice:cancel_enrol().
erm_native_voice:enrol("steven", 3).
```

Use a quiet room, keep a consistent microphone distance, and speak a continuous
sentence of roughly 3–5 seconds. Wait for the next ready beep before the
next sentence; capture stays closed during inference and feedback. Keep
sentences below the configured segment limit (8 seconds by default). Guided enrolment
expires after three minutes by default. Cancelling an attempt does not delete an existing
saved profile.

If the next samples fail, retain `last_check` from status before the attempt
expires. Repeated low scores, a wrong capture device and short/fragmented audio
need different fixes; the rejection atom alone cannot distinguish them. Do not
infer a suitable threshold from one failing sample or silently relax command
verification to force enrollment to complete.

For live acoustic trials and configuration reload, see
[native_voice_tuning.md](native_voice_tuning.md). The first tuning upgrade adds
a record field and a versioned native protocol: follow its suspended code-change
sequence instead of loading the native module alone. For an installed release,
deploy using the normal release procedure.

## Verification

```sh
sh apps/erm/test/native_voice_isolated/run.sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
```

The suites test embedding-only capture without calling Whisper, restoration of
transcription for tuning/commands, protocol-3 fallback, bounded retry diagnostics,
unchanged enrolment acceptance, shared cue ordering, accepted/rejected retries, first-time
profiles, profile write failures, cancellation, timeout/save races, stale-session
notifications and short-guard restoration. Native SDK, synthesizer and player
boundaries use test doubles; actual microphone/speaker behaviour requires a
local trial.
