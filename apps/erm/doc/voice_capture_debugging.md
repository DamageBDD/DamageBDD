# Inspecting voice captures in the GTK widget

This increment applies after `erm-voice-enrolment-recovery.patch`. It adds a
native GTK capture inspector, a bounded event trace and automatic reconstruction
playback. It does not change speaker thresholds or phrase-matching decisions.

## What to do

1. Start a session or re-enrol from the widget. Autoplay is enabled for a session
   explicitly opened this way. If attaching to a lab started in the shell, click
   **Autoplay: off** to turn it on.
2. Click **Record sample**, **Record take**, or **Verify voice**. Wait for
   **Speak now**, read the prompt naturally, then pause.
3. Inspect **Matching & playback**. Each completed human take, including rejected
   takes, updates its measured stages and plays its reconstruction when autoplay
   is on. A rejected fifth sample does not replace the four accepted samples.
4. Use **Replay last sample** to listen again or **Stop playback** to interrupt.
   Wait for the post-playback echo guard before recording the next take.
5. Select and copy the read-only **Event trace** when reporting a failure.
   **Clear trace** clears the display history, not saved samples or profiles.

The inspector is a third column. Smaller windows can scroll horizontally; its
graphs scroll while playback controls and the trace remain visible. An active
enrolment now expires after three minutes
of inactivity, with explicit capture/replay and active playback extending that
deadline. Reading the remaining-time display helps distinguish an expired
draft from a rejected take.

## Reading the graphics

- **Audio quality:** captured segment duration, RMS level and clipped fraction.
- **Analysis:** MFCC frame count and speaker embedding dimensions.
- **Voice consistency / speaker identity:** the actual comparison gate. During
  enrolment this is the new take versus the preceding accepted-sample mean,
  followed by the proposed profile's minimum similarity when calculated. During
  verification it is the saved-profile cosine score. These are not probabilities.
- **Phrase content:** separately reports the command match. It is not applicable
  to speaker enrolment. A content match does not override failed identity checks.
- **Take outcome:** whether a human take was accepted into a draft, saved into
  the corpus, rejected, or used only for verification. Recorded phrase takes
  still need **Train phrase** before becoming active templates.

Score bars show the exact numeric values and a gold threshold marker. Green
and red indicate the existing comparison's pass/fail result. Pairwise reference
bars are neutral: they compare the candidate with individual accepted takes,
but they are not additional acceptance gates. This can reveal one unusually
dissimilar reference without silently deleting or modifying it.

The RMS envelope is measured from the same captured VAD segment's reconstruction
analysis. Its vertical scale follows that take's peak RMS; the numeric quality
checks remain absolute. It is an energy envelope, not an original waveform.
The current capture state is displayed separately from the latest completed
take, so an old rejection is not presented as the new take's result.

Configured input device, speaker-model basename, embedding dimension, input
gain and VAD settings are visible. A device named `default` is the configured
ALSA route; it does not identify the physical microphone behind that route.

## What playback is, and what it is not

Playback uses the existing native source/filter reconstruction from the **same
captured segment**: per-frame energy, pitch/voicing and LPC filter coefficients.
Speed and pitch remain at 1.0. It never reads the expected prompt with a TTS
voice and never substitutes a known phrase for what was captured.

This is lossy acoustic reconstruction. A robotic or distorted reconstruction
can result from the synthesizer itself; it is not conclusive evidence that the
microphone audio or speaker embedding was bad. Speaker embeddings cannot be
listened to directly, and the reconstruction is not recovered from the MFCCs.
Use it to inspect approximate duration, cut-off speech and gross signal content
alongside the numeric diagnostics. It is not a transcript or an exact replay of
the original waveform.

The latest reconstruction model and generated WAV stay in the lab process's
memory for replay. Rejected enrolment takes are not added to the speaker profile
or training corpus. Existing accepted phrase-training storage still includes its
LPC sidecar as before. No new raw microphone recording archive is created.

The microphone lease is closed before reconstruction/playback and a new echo
guard begins after completion, stop or failure. Playback never arms a capture
loop, and its generated audio cannot automatically become a training take.
The lab remains in command-observation mode. Playback work runs outside the UI
process; stopping/cancelling closes the native worker and its player child.

## Event trace and errors

The trace retains at most 100 entries with monotonic sequence numbers and elapsed
milliseconds. The widget displays newest first so the latest error is visible;
the status API returns chronological order. A compact recent-take history retains
at most 20 entries. Entries
include capture request, armed acknowledgement, native inference start,
completed take outcome, reconstruction start/completion, playback start/end,
stop and failure. Known native utterance-too-long/busy diagnostics are forwarded
while capture is waiting; these older native diagnostic packets lack an epoch,
so they are supporting clues rather than proof of a particular audio segment.

Trace text is bounded and contains diagnostic summaries, not embeddings, PCM,
reconstruction coefficients, credentials or full model paths. Replacing graph
data does not overwrite a user's text selection on every polling tick.

If VAD never supplies a completed segment, the capture times out with **no audio
captured**. The UI must not replay an older take as if it were this capture.
Missing native reconstruction/player executables or player errors appear as
playback failures while the original acceptance result remains available.

For the reported `4 / 5 accepted`, `14 rejected`, `0.510 / 0.700` case, compare:

1. Did the received segment contain the complete spoken sentence?
2. Did RMS, clipping, duration and embedding dimensions pass?
3. Is the low similarity against all references or chiefly one reference?
4. Did the candidate-versus-mean gate fail, or did a proposed profile minimum
   fail after the candidate comparison passed?

These observations should guide new recordings or measured calibration. This
patch does not lower the threshold to make the fifth sample pass.

## Build and restart

```sh
git apply --check ~/Downloads/erm-voice-capture-debug.patch
git apply ~/Downloads/erm-voice-capture-debug.patch
make -C apps/erm/c_src/gtknode4
rebar3 compile
```

Reconstruction needs the existing `apps/erm/priv/erm_phrase_lab` executable
and `aplay` (or the player configured when opening a lab). Build that existing
worker through the project's normal native build hook if it is absent.

Restart erm using the normal release/service workflow after compiling. This
increment changes the lab record and adds native GTK properties, so reloading
only the widget while retaining the old C-node is insufficient. Restarting ends
unsaved drafts; saved profiles and phrase banks remain.

Shell APIs, for an already-running lab:

```erlang
erm_phrase_lab:set_autoplay(true).
erm_phrase_lab:replay().
erm_phrase_lab:stop_playback().
erm_phrase_lab:clear_trace().
erm_phrase_lab:status().
```

The shell-started lab keeps autoplay off until explicitly enabled. Playback
device/player options remain those supplied to `erm_phrase_lab:start/1`.

## Verification

```sh
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
WIDGET_DEBUG_ONLY=1 sh apps/erm/test/voice_widget_training/run.sh
sh apps/erm/test/voice_widget_training/run.sh
sh apps/erm/test/motion/run.sh
```

The isolated tests use the production LPC renderer and a silent test player,
with deterministic native speaker packets. The GTK suite uses actual native
widgets and pointer clicks, including read-only trace properties. These checks
validate lifecycle, graphics and playback routing, not live microphone/model
accuracy or reconstruction intelligibility on the user's hardware.

The focused native debug run also covers accepted and rejected enrolment takes,
replay and stop, player failure, capture gating and recovery, clearing the trace,
and closing a widget without terminating an attached shell lab. Diagnostics
tests separately confirm that a later storage rejection cannot erase a passing
speaker comparison.
