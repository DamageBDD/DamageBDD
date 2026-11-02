# erm voice notes

A small gtkgs notebook for collecting original audio, listening back, correcting
transcripts and developing ECAI speaker models from reviewed recordings.
Recording does not require speaker verification, enrolment, a wake word, VAD,
or a successful transcription. Failed analysis never deletes the recording.

## Build and start

This replacement patch is rebased against `latest-erm.tar(20261021-001745).gz`.
It includes the complete voice-note app; the previous voice-note patch does not
need to be applied first. The native build preserves `gtknode4_motion.o`, its
header dependency and the existing heartbeat changes. It adds independent
modules and two small additions to the native GTK bridge.

```sh
git apply --check ~/Downloads/erm-voice-notes-20261021.patch &&
git apply ~/Downloads/erm-voice-notes-20261021.patch &&
make -C apps/erm/c_src/voice_notes &&
make -C apps/erm/c_src/gtknode4 &&
rebar3 compile
```

Restart the GTK C-node using your normal erm restart workflow so its new keyboard
controller is loaded. A GTK restart recreates its windows. Then:

```erlang
erm_voice_notes:start().
```

The app uses the existing erm supervisor to start gtkgs when necessary. It does
not start automatically at login. The original ECAI Erlang voice frontend modules
must be present: `ecai_voice_features`, `ecai_voice_dsp`, `ecai_voice_wav`, and
`ecai_voice_curve`. No ECAI NIF or ECAI application startup is needed for scoring.

## Controls

- **Record / Stop**, or **Space** outside a text field: start/finish a note.
- **Escape** or closing the window: finish the active recording and quit.
- **Saved recordings**: select an earlier note; the list survives app/VM restarts.
- **Play selected / Stop playback**: listen to the saved recognition-input PCM.
- **Transcribe**: run the configured local recognizer again.
- **Re-score**: re-extract acoustic features from the original saved audio.
- Correct the transcript, enter a speaker name, choose the dataset role, then
  **Save reviewed text and speaker label**.
- **Update speaker model** explicitly rebuilds the reference model. Saving a
  reviewed label also rebuilds it; rebuilding is deferred during audio I/O.
- **Evaluate held-out test** reports classification counts after calibration.
- **Export dataset** writes a native `ecai_voice` dataset and a note manifest.

Space remains a normal character inside entries. Holding Space cannot repeatedly
start and stop capture. The waveform level meter and elapsed time update during
capture; expensive analysis/transcription run in monitored workers.

## Audio device and dependency boundary

Set physical Linux PCM paths in the microphone and playback fields, for example
`/dev/snd/pcmC1D0c` and `/dev/snd/pcmC0D0p`, then apply settings. Defaults are
`/dev/snd/pcmC0D0c` and `/dev/snd/pcmC0D0p`; these might not be your microphone or
speakers. Inspect your available devices in Erlang:

```erlang
file:list_dir("/dev/snd").
```

The first-party C port uses Linux's ALSA **kernel UAPI**, libc and libm directly.
It does not use libasound, PortAudio, PipeWire client libraries, arecord, aplay,
Sherpa or ONNX. Device negotiation supports PCM16LE at 16 or 48 kHz, one or two
channels. A 63-tap lowpass precedes 48-to-16 kHz conversion; stereo is averaged.
Unsupported formats are reported explicitly. For 48 kHz playback, the worker
repeats samples to produce the hardware rate; this simple playback converter can
be improved independently of the stored recognition input.

The saved WAV is mono PCM16LE at 16 kHz, **exactly the audio supplied to scoring**.
It is not LPC resynthesis or a TTS reading of an expected phrase. The hardware's
pre-conversion 48 kHz stream is not separately archived. Playback and recording
are mutually exclusive. There is no silence endpoint to truncate a sentence;
only Stop, the duration limit, EOF/disconnection or an error ends a take.

A physical device may be held by an existing voice listener or desktop sound
service. Muting a listener does not necessarily release its device. This app
reports device-open errors and does not terminate existing enrolment sessions or
system audio services. Choose an available capture device or release its current
owner. Device access uses ordinary user/session ACLs; root is not required.
Other recognizers remain independent; this app itself never dispatches commands.

Default recording limit: five minutes; configurable range: one second to ten
minutes. A capture discontinuity ends the take with a diagnostic, preserving
already received samples rather than silently treating the recording as clean.

## Transcription

The current ECAI speaker frontend does not decode words. This app provides an
optional **local whisper.cpp CLI adapter** for free-form transcription. The raw
recording, playback and ECAI scoring path remains independent of that adapter.
No model is downloaded and no audio is sent to a network service.

Set the `whisper-cli` executable and your existing Whisper model path in the
window. The model field starts with an explicitly configured
`whisper_trigger.native.whisper_model` when available. Press **Apply settings**.
Completed recordings are analysed and then transcribed automatically. Existing
notes can be transcribed with the button after configuration.

Without that optional recognizer, audio and speaker scoring still work and the
window says transcription is unavailable. You can enter reference text manually.
A failed or timed-out recognizer leaves original audio and human corrections
intact. The app invokes the executable with separate arguments, without a shell.

Example configuration (use the paths and PCM devices on your machine):

```erlang
{erm, [
  {voice_notes, #{
    input_device => "/dev/snd/pcmC1D0c",
    output_device => "/dev/snd/pcmC0D0p",
    max_recording_ms => 300000,
    whisper_cli => "/opt/whisper.cpp/build/bin/whisper-cli",
    whisper_model => "/home/steven/.cache/whisper/ggml-base.en.bin",
    language => "en",
    transcription_timeout_ms => 120000
  }}
]}.
```

Or pass those options directly to `erm_voice_notes:start/1`. GUI setting changes
last for the running app; put persistent device/model preferences in sys.config.

## Speaker training and honest scores

The first model reuses ECAI's versioned **30-coordinate non-neural acoustic
frontend**, using cepstral statistics and pitch/periodicity. This is an
experimental speaker baseline, not a replacement already demonstrated to beat
Sherpa or a trained biometric system. It provides no speech transcription,
liveness detection or overlapping-speaker separation.

Feature extraction uses up to three non-overlapping windows, each up to four
seconds, across the note. Short notes are analysed in one window. The median
quantized vector forms the note representation. The UI reports sampled duration;
it does not imply that every second of a long recording has been scored. Audio
under 1.5 seconds or without sufficient periodic voice can lack usable features;
the original note remains saved.

Speaker ranking averages the nearest three available reference distances per
speaker (or fewer when fewer references exist). Scores use the existing ECAI
quantized **integer L1 metric**, with lower values meaning closer recordings.
This is the acoustic metric used by the earlier curve-distance experiment; this
app does not run elliptic-curve arithmetic or claim it improves accuracy. Scores
are distances, not probabilities. Exact waveform hashes exclude a note's own
recording, including renamed copies, from its independent comparisons.

Start with several clean recordings labelled with your speaker name and role
**Training**. Collect fresh recordings from the same speaker as **Validation**,
and other-speaker recordings labelled exactly `unknown` as Validation. Two or
more named speakers are supported too. A single-speaker model can calibrate
against separate unknown-speaker validation recordings.

Only reviewed Training notes form templates. Validation sets the radius and
competing-speaker margin. If genuine and impostor validation overlap, the model
stays **uncalibrated** and displays distances without claiming a match. Test
recordings never enter building/calibration; evaluation rejects overlapping
waveform hashes. Keep new sessions/microphone positions represented in held-out
recordings to measure rather than assume improvement.

Human labels are the only training labels. Guessed transcripts and recognition
scores cannot label their own data. Editing a transcript preserves it separately
from the recognizer output. Labels trigger reference-model updates, but this
release does **not** fine-tune Whisper or a neural speaker model. Corrected text
and original audio are retained for later supervised temporal/acoustic work.

## Files and export

Default directory: `$XDG_DATA_HOME/erm/voice-notes`, falling back to
`~/.local/share/erm/voice-notes`. The directory is private (0700); files are 0600.
Every completed note has an original `.wav` and versioned `.note` metadata.
Metadata includes capture format/errors, waveform hash, extracted features,
recognizer provenance, separate corrected text, speaker label and dataset role.

Writes use private temporary files, fsync and rename. Escape gracefully saves a
recording. A hard kill or machine crash can leave `.pcm.part` files: they are
retained for recovery, and are not listed as completed notes. Missing or malformed
metadata is skipped. An unfinished background analysis resumes at app startup.

Export creates:

- `reviewed-dataset.term`: rows compatible with `ecai_voice:build/1` and
  `ecai_voice:evaluate/2` (`enroll`, `calibrate`, `test`).
- `dataset/<note-id>.wav`: the first up-to-30 seconds of each reviewed note,
  keeping that existing API's 30-second WAV limit.
- `reviewed-notes-manifest.term`: original note IDs/hashes/roles and full-note
  human/automatic text, plus exported audio offsets/durations. Full-note text is
  explicitly marked as such; it is not claimed aligned to the cropped clip.

The old `ecai_voice:build/1` still requires at least two named speakers; the
notebook's exploratory one-speaker reference model has a separate implementation.
Changing this notebook's corpus does not overwrite the existing phrase lab or
speaker profiles, and it does not promote a model into command dispatch.

## APIs and checks

```erlang
erm_voice_notes:status().
erm_voice_notes:notes().
erm_voice_notes:record().
erm_voice_notes:stop_recording().
erm_voice_notes:play(NoteId).
erm_voice_notes:note(NoteId).  % includes the selected note's speaker score
erm_voice_notes:review(NoteId, <<"Steven">>, train, <<"Corrected words">>).
erm_voice_notes:rebuild_model().
erm_voice_notes:evaluate_test().
erm_voice_notes:export_dataset().
erm_voice_notes:stop().
```

```sh
sh apps/erm/test/voice_notes/run.sh
sh apps/erm/test/voice_notes/run_native.sh
```

The Erlang integration suite uses the production native PCM worker in explicitly
selected fixture-input/playback-check modes; audio bytes and storage are real,
but microphone hardware is not exercised. A local process fixture tests
transcription lifecycle and correction races, not Whisper accuracy. gtkgs owner
events test the complete recording/review/playback/quit controller. The native
GTK test checks keyboard controllers, editable focus, repeat suppression and
cleanup. GUI rendering was inspected separately. Actual hardware negotiation,
speaker accuracy and real-model transcription must be checked on your host.
