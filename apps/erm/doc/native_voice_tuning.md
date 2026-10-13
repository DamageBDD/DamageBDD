# Live acoustic tuning

The native worker accepts acoustic changes while retaining the microphone,
Whisper model and speaker extractor. It resets the VAD at the configuration
boundary and invalidates in-flight utterances. The enrolled profile is unchanged.
`configure/1` validates a map or a standard proplist before applying any change.

## Install the cue update

Apply this patch after `erm_native_voice_live_tuning.patch`. From the project
root, rebuild both native workers and compile the Erlang modules:

```sh
git apply --check ~/Downloads/erm_native_voice_tuning_cues.patch &&
git apply ~/Downloads/erm_native_voice_tuning_cues.patch &&
make -C apps/erm/c_src PIPER_PREFIX=/opt/piper &&
rebar3 compile
```

The Makefile rebuilds the existing Piper port in `apps/erm/priv`; ordinary
`rebar3 compile` runs the native voice build hook. Use your installed Piper
prefix if it differs. No new runtime dependency or audio file download is needed.

For a running development node that already has the live-tuning update, cancel
any trial before loading the changed modules. Their record layouts are unchanged:

```erlang
erm_voice_tune:cancel().
l(erm_tts).
l(erm_voice_tune).
l(erm_native_voice).
erm_tts:reload().
erm_native_voice:reconnect().
```

If the tuner has never run, `cancel/0` returns `{error, not_started}` and you can
continue. The one-time reload/reconnect starts the rebuilt native executables
without restarting the Erlang node. Wait until `erm_tts:status()` reports
`ready => true, cue_ready => true`, and `erm_native_voice:status()` reports
`ready => true, native_protocol => 3` and `acoustic_config.state => applied`.
Acoustic changes still apply live without reconnecting. Release upgrades should
use the normal OTP release procedure. For the first upgrade from a version
before live tuning, also follow that patch's `sys:change_code/4` migration.

The subsequent `erm_native_voice_enrolment_prompts.patch` adds enrolment to this
shared guide and reduces its speech-to-cue delay. See
[native_voice_enrolment.md](native_voice_enrolment.md) for installation and timing
controls; that follow-up needs no further native rebuild.

## Run a guided trial

First keep music paused and leave the microphone in its usual position:

```erlang
erm_native_voice:tune(#{label => "quiet", samples => 3}).
erm_voice_tune:status().
```

The tuner says “After the beep…” and handles the speech echo guard itself.
There is no spoken countdown or instruction to count seconds:

- A short **rising beep** means to start speaking. Capture opens after the
  player finishes the cue and its short silent tail.
- A short **falling beep** confirms the detector has finished collecting the
  utterance. It plays as inference starts, before the transcript and speaker
  score are available. It confirms capture completion, not a successful match.
- Spoken feedback then explains the result: matched, below threshold, too
  quiet, clipping, too short, or missing the wake phrase. The next ready beep
  opens the next response window.

Say the requested wake phrase and command as one continuous utterance. The end
cue follows the configured VAD silence interval (`silence_ms`, default 700 ms)
plus detection/player scheduling, so a pause is expected before that cue.
`status()` exposes `prompting`, `arming`, `ready_cue`, `listening`, `processing`
and `finishing`. `processing` means detection has ended and the measurement or
end cue is still pending.

Cues are generated as PCM in the existing native TTS port, with no Piper text
synthesis. They use the TTS player and current voice volume, and do not replace
the response remembered by “repeat louder”. For example:

```erlang
erm_tts:set_volume(120).
```

With the enrolment-prompts update, exclusive native guidance uses a 150 ms
post-speech guard (`guided_echo_guard_ms`) and immediate cue scheduling. Normal
rolling Whisper suppression is unchanged. The cue is 160 ms with a gentle
fade and an 80 ms silent tail. Native protocol 3 closes capture automatically
when it queues the first completed utterance. The inference job keeps its epoch,
so playing the end cue cannot invalidate that sample. Capture remains closed
through prompts and feedback, and is reset when the next response window opens.

Normal command dispatch is blocked throughout the trial, including during
prompts and feedback. Each prompt consumes at most one utterance. Tuning never
enrolls a new profile, adds a sample to a profile, or changes a threshold.
The caller labels the condition; the tuner cannot determine who spoke.

Read the finished report and previous trials:

```erlang
erm_voice_tune:status().
erm_voice_tune:history().
```

Reports include the configuration, microphone device, per-utterance levels,
duration, wake detection and verification scores. `measured` counts utterances
with a valid speaker score and a detected wake phrase; `matched` counts those
above the trial's threshold. These are diagnostic counts, not a biometric
accuracy estimate. The ten most recent reports are held in memory. They contain
no recordings, recognized text, or speaker vectors.

## Adjust one setting and repeat

For example, try a longer pause before ending an utterance if your sentence is
being split. Change only one variable per trial:

```erlang
erm_native_voice:configure([{silence_ms, 1000}]).
%% Wait for acoustic_config.state = applied in status(), then:
erm_native_voice:tune(#{label => "longer-pause", samples => 3}).
```

Other live controls:

```erlang
erm_native_voice:configure(#{input_gain_db => -3.0}).
erm_native_voice:configure(#{vad_threshold => 0.6}).
erm_native_voice:configure(#{speaker_threshold => 0.60}).
```

| Setting | Default | Range / effect |
| --- | --- | --- |
| `input_gain_db` | 0.0 | -24 to +12 dB, software gain before VAD and both models |
| `vad_threshold` | 0.5 | 0.05 to 0.95; higher requires stronger VAD evidence |
| `silence_ms` | 700 | 200 to 2000 ms of silence before completing speech |
| `min_speech_ms` | 250 | 100 to 2000 ms, VAD speech duration floor |
| `max_segment_ms` | 8000 | 2000 to 15000 ms, completed-utterance limit |
| `min_speaker_ms` | 1200 | 500 to 15000 ms, must be below the segment limit |
| `speaker_threshold` | 0.7 | 0.01 to 0.99, command verification |
| `enrolment_threshold` | startup speaker threshold | 0.01 to 0.99, enrollment consistency |
| `observe_only` | false | Verify without executing commands outside tuning |
| `debug_utterances` | false | Existing accepted-utterance text diagnostics |
| `require_speaker` | true | Existing verification requirement |
| `trigger_phrases` | `["bob"]` | Wake phrases, case-insensitive boundary matching |

Levels are measured over the completed VAD segment **after software gain**.
`rms_dbfs` is average signal level, `peak_dbfs` is peak level, and
`clipped_fraction` is the proportion of samples near full scale. These are not
SNR measurements. The spoken hints use simple heuristics (RMS below -40 dBFS;
more than 1% near full scale), not automatic gain control. Reducing software gain
cannot repair clipping that already happened in the microphone or ADC.

Settings are frozen during a trial and during enrollment; finish or cancel
before changing them. Validation failures leave all current settings intact.
Acoustic changes are acknowledged asynchronously; `configure/1` returns `ok`
when submitted and status reports `pending` until the native ACK arrives.
An ACK timeout is reported and the managed worker is restarted. Old native
binaries reject live audio changes with `native_rebuild_required`, while
Erlang-only controls remain available. Model paths, capture device and other
startup-only changes are reported as `restart_required` by reload.

## Reload configuration

```erlang
%% Apply supported settings currently in application environment:
erm_native_voice:reload().

%% Read the erm.whisper_trigger section directly from a plain sys.config:
erm_native_voice:reload("/absolute/path/to/sys.config").
```

Both operations merge explicitly supplied settings into the running options;
omitted settings keep their current values. The file form uses `file:consult/1`:
it does not evaluate config scripts, expand includes, reload other applications,
or overwrite application environment. Neither form edits the file. Keep chosen
values in the normal `sys.config` for future application starts. For example,
inside the existing `whisper_trigger` proplist:

```erlang
{native, [
    {input_gain_db, 0.0},
    {vad_threshold, 0.5},
    {silence_ms, 1000},
    {min_speech_ms, 250},
    {speaker_threshold, 0.60},
    {enrolment_threshold, 0.70}
]}
```

Preserve other existing native settings when editing that proplist.

## Stop, compare playback, or use text prompts

```erlang
erm_voice_tune:cancel().
erm_native_voice:tune(#{label => "headphones", samples => 3}).
erm_native_voice:tune(#{label => "speakers", samples => 3}).
erm_native_voice:tune(#{label => "manual", samples => 3, tts => false, cues => false}).
```

Set playback conditions manually before each trial. This update does not add
echo cancellation or change MPV volume. Compare the same phrase and microphone
position between quiet, headphones and speaker playback before changing the
verification threshold. Test other speakers separately; matching your voice
more often alone does not demonstrate better separation.

Both `tts` (spoken prompts/feedback) and `cues` default to `true`. Use
`tts => false` for logged prompts with beeps, or set both to `false` for a fully
silent trial driven by `status()`. Cue playback still requires a ready TTS port
and player even when spoken prompts are disabled.

A failed or unavailable cue stops the trial with `outcome => {cue_failed, ...}`;
it never silently opens a response window after a failed start cue. Zero TTS
volume is reported as `cue_volume_zero`. Old workers report
`native_rebuild_required` or `tts_rebuild_required`. A cue is acknowledged only
after player exit; playback is bounded to five seconds. Cancel, backend failure,
reload and tuner death stop an active cue. A cancelled cue retains the existing
speech echo guard before normal listening resumes.

Trials default to three samples and a three-minute deadline, with a maximum of
three attempts per requested sample. `samples` accepts 1–10 and `timeout_ms`
accepts 1000–600000. Cancellation, expiry and tuner-process failure release the
command gate. Any active TTS echo guard still applies normally.

## Verification

```sh
sh apps/erm/test/native_voice_isolated/run.sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
```

The isolated suite compiles production Erlang with warnings as errors, exercises
the real tuning coordinator against controlled TTS/port boundaries, and runs
the production C++ worker against SDK test doubles and deterministic PCM. The
control test checks ACKs, gain measurements, epoch muting, capture closing after
one sample, invalid configuration and arecord arguments. TTS tests use the
production port and a fake synthesizer/player to check cue PCM, playback
completion, volume, replay preservation and cancellation. The SDK doubles do not establish model accuracy or real
microphone/Piper behaviour; those require local trials. No Python test or runtime
dependency is added.
