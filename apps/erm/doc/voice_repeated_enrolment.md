# Repeated voice enrolment and automatic adjustment

Apply `erm-voice-repeated-enrolment-20261021.patch` to the latest supplied erm
source (`latest-erm.tar(20261021-001745).gz`). It is an incremental patch,
independent of the voice-note app patch; it does not touch the GTK C Makefile.

```sh
git apply --check ~/Downloads/erm-voice-repeated-enrolment-20261021.patch &&
git apply ~/Downloads/erm-voice-repeated-enrolment-20261021.patch &&
rebar3 compile
```

Restart the normal application/node after compiling. In particular, restart
`erm_phrase_voice`, the lab and the widget together; the backend record gained
calibration state, so loading new BEAM files into a running old backend is not
sufficient. No native worker changes or C rebuild are required for this patch.
Reopen the normal widget:

```erlang
erm_voice_widget:start().
```

Choose **Re-enrol selected voice**, or start a new named enrolment. The normal
widget request now needs eight distinct captures:

| Sentence | Repetitions | Use |
| --- | --- | --- |
| I am speaking naturally at my usual volume. | 3 | Training |
| Please play some music while I work today. | 3 | Training |
| The microphone can hear me clearly from here. | 2 | Validation |

Click **Record sample** for each take and wait for **Speak now**. The prompt
stays on the same sentence for its repetitions. The counter names the sentence,
stage and repetition. Autoplay and the existing echo guard still apply. There
is no automatic listening loop. **Save voice** is enabled only after validation.

The shell API `erm_phrase_lab:enrol_voice(Name, N)` still accepts N from 3 to 10.
It now collects `R = max(3, ceil(N/2))` training takes per sentence, then two
validation takes: `2*R + 2` total. Thus the widget's N=5 request and N=3 both use
8 captures; N=10 uses 12. Restart samples preserves this plan, clears the draft
and invalidates stale capture results. Three minutes of inactivity expires it.

## How the reference recovers

All training captures must pass the existing duration, level, clipping,
embedding-dimension and normalization checks. The first capture is provisional:
it no longer anchors acceptance of every later take and has no self-match score.
Repeated enrolment does not run the old sequential consistency gate at save.

After both training sentences are collected, a pairwise comparison finds a
unique largest mutually consistent set. It must contain at least 75% of the
batch. If a clear majority exists, only its outliers are removed and the UI asks
for replacements from the sentence missing a take. If no clear majority exists,
the batch resets automatically. Duplicate feature fingerprints are rejected,
including validation/training reuse. At most 64 distinct quality-passing takes
may be attempted in one draft; Restart samples clears that bound.

## Automatic threshold adjustment

Let C be the configured `native.speaker_threshold`. The lower bound is
`F = min(C, max(0.50, C - 0.20))`. Pairwise consistency uses F. For the complete
training set, compute each sample's cosine similarity to:

- the mean of the other training takes (leave one recording out);
- the mean of the other sentence's training takes (leave one sentence out).

Let L be the minimum of these scores. The saved threshold is
`max(F, min(C, L - 0.04))`. At the usual C=0.70, adjustment stays within
0.50–0.70. This is a bounded heuristic from the explicitly labelled speaker's
recordings, not a measured false-acceptance-rate calibration.

The mean and threshold are frozen before the third sentence. Both validation
captures must pass that threshold. A failed validation take cannot lower it,
update the reference, or activate the profile. Record another take or restart.
Validation vectors never enter the saved mean. These are development validation
captures; independently collected recordings are still needed for final tests.
The app asks you to read the sentence; it does not transcribe/check the words
or provide replay/liveness detection.

Saving recomputes and checks the complete payload inside the owning backend,
then persists the mean and bounded calibration summary in the new private voice
profile. The configured global threshold is unchanged. Verification, human
command training, ambient command dispatch, profile selection and backend
restart use the selected voice's effective threshold. Profiles without
calibration metadata retain the configured threshold. A later stricter global
configuration also tightens the allowed lower bound. The general native
recognizer/measurement path understands the same profile metadata when it loads
a calibrated profile; its older guided enrolment API remains sequential.

The saved summary reports `negative_samples = 0`: no impostor data was collected
by this workflow. It measures consistency and broadens the reference across
two sentences. It does not retrain SpeakerNet/sherpa model weights or make the
separate experimental ECAI voice-note scorer a neural speaker recognizer.

Speaker enrolment still does not train command templates. After saving, record
3–5 repetitions of each full wake phrase + command and choose **Train phrase**.
Existing saved voices are preserved; select one to use its original phrase bank.

## Tests

```sh
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
sh apps/erm/test/native_voice_isolated/run.sh
# Requires GTK/X11, xdotool and a normal test display or Xvfb:
sh apps/erm/test/voice_widget_training/run.sh
```

The isolated Erlang suite exercises bad-first-take recovery, automatic bounded
adjustment, duplicate and mixed-speaker rejection, frozen validation, private
profile loading in a fresh VM, selection/restart, command training and actual
normal dispatch through the production Erlang gate with a fixture native port.
These tests establish plumbing/policy behaviour; live microphone/model accuracy
must be measured with real recordings.
