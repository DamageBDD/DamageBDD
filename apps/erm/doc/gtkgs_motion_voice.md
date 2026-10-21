# Native motion and the ECAI voice widget

This patch adds `gtkgs_motion`, a GTK frame-clock animation layer, and
`erm_voice_widget`, a native window driven by the existing ERM/ECAI voice
pipeline. Erlang sends animation targets; GTK interpolates and draws each frame.

## Build and launch

Apply `gtkgs-motion-voice-rebased.patch` from the umbrella project root containing
`apps/erm` and `apps/ecai`. The source bundle also contains every changed file
at its project-relative path; use either the patch or those files.

```sh
git apply --check /path/to/gtkgs-motion-voice-rebased.patch
git apply /path/to/gtkgs-motion-voice-rebased.patch
make -C apps/erm/c_src/gtknode4
rebar3 compile
```

For native microphone/TTS metering, rebuild their workers too, using your
existing SDK installation paths:

```sh
make -C apps/erm/c_src -f Makefile.native_voice \
  WHISPER_PREFIX=/opt/whisper SHERPA_PREFIX=/opt/sherpa-onnx
make -C apps/erm/c_src PIPER_PREFIX=/opt/piper
```

Restart the normal ERM application/node after rebuilding so the new native
workers, supervisor and Erlang modules are loaded together. Keep the usual
display environment and distributed node configuration. This does not modify
audio devices, models, enrollment data or speaker verification thresholds.

On a running ERM node with its GTK session enabled:

```erlang
{ok, _} = erm_sup:start_gtknode4().
{ok, _} = erm_voice_widget:start().
```

If GTK is currently disabled, preserve its existing options while enabling it
before the first call above:

```erlang
Gtk0 = application:get_env(erm, gtknode4, #{}).
Gtk = case is_map(Gtk0) of true -> Gtk0; false -> maps:from_list(Gtk0) end.
ok = application:set_env(erm, gtknode4, Gtk#{enabled => true, mode => local_cnode}).
```

Open the widget before starting an interactive ECAI session on the **same node**:

```erlang
erm_voice_loop:run().
%% Or your existing erm_voice_loop:start(#{profile => ..., session => ...}).
```

The widget observes the existing capture and playback operations. Opening it
does not start recording. The session's normal prompts and consent still apply.
Already-running native capture will supply its next level update automatically.

To show only ECAI session activity, or hide transcript/reply text:

```erlang
erm_voice_widget:stop().
{ok, _} = erm_voice_widget:start(#{
    sources => [ecai_voice_session, ecai_voice_live],
    show_text => false
}).
erm_voice_widget:status().
erm_voice_widget:hide().
erm_voice_widget:show().
erm_voice_widget:stop().
```

Options apply when creating the widget. Calling `start/1` while it already
exists shows the existing instance. Closing the window stops its observer;
call `start/0` to reopen it. If the GTK controller restarts, reopen the widget.

## Motion API

Wrap a widget, or a frame containing several widgets, in a single-child `motion`
container. The container preserves layout measurement and transforms its child
around the allocated center. Movement does not push neighbouring widgets aside.

```erlang
Window = gtkgs:create(window, gtkgs:server(), [{width,360},{height,240}]).
Stage = gtkgs:create(motion, Window, []).
Button = gtkgs:create(button, Stage, [{label,"Hello"}]).
ok = gtkgs:config(Window, {show,true}).
ok = gtkgs_motion:set(Stage, #{opacity=>0, y=>16, scale=>0.94}).
{ok, AnimationId} = gtkgs_motion:animate(Stage,
    #{opacity=>1, y=>0, scale=>1}, #{duration=>320, easing=>spring}).

{ok, _} = gtkgs_motion:sequence(Stage, [
    #{to=>#{x=>32}, duration=>180, easing=>out_cubic},
    #{to=>#{x=>0}, duration=>280, delay=>50, easing=>spring}
]).
ok = gtkgs_motion:pause(Stage).
ok = gtkgs_motion:seek(Stage, 100).
ok = gtkgs_motion:resume(Stage).
{ok, CurrentValues} = gtkgs_motion:inspect(Stage).
ok = gtkgs_motion:cancel(Stage).

ok = gtkgs_motion:classes(Button, ["primary", "ready"]).
ok = gtkgs_motion:remove_class(Button, ["ready"]).
ok = gtkgs_motion:add_class(Button, ["active"]).
```

Supported transform channels: `x`, `y` in pixels, `scale`, `rotation` in degrees,
and `opacity` in 0..1. Several channels animate together in a step. `voice_meter`
has `input`, `output` in 0..1 and a discrete `mood`; wrap it in `motion` for
geometric transforms, as the supplied widget does.

- `animate/2,3`: one step; default 180 ms, no delay, `out_cubic` easing.
- `sequence/2,3`: up to 64 consecutive steps, total duration at most 10 minutes.
- `stagger(Objects, Step, GapMs)`: start a step on each object with increasing
  native delays; returns one result per object. Maximum 128 objects.
- Easing: `linear`, `out_cubic`, or a fixed damped `spring` curve. Spring is an
  easing function, not a configurable physics solver.
- `seek/2` pauses at an absolute time within the current timeline.
- A new animation replaces the old one from its currently rendered values.
  `set/2` replaces the animation immediately and clears its timeline.
- GTK emits `motion_finished` with `animation_id` and `status`:
  `completed`, `replaced`, or `cancelled`. Use the existing `gtkgs:await_event/4`
  or owner event delivery. Destroying a widget removes its frame callback.
- `classes/2` replaces **all** CSS classes on the target. Use `add_class/2` and
  `remove_class/2` when preserving theme-supplied classes matters.

`#{reduced_motion=>true}` in animation options jumps to the final state.
The default follows `application:get_env(erm, reduced_motion, false)` and GTK's
`gtk-enable-animations` setting. The processing spinner also respects this.

This is a native motion foundation, not an anime.js compatibility API. There
is no DOM, arbitrary CSS property tweening, SVG morphing, automatic layout
transitions or configurable spring simulation. The native node advertises
`motion => 1`; the fake backend does not implement it.

## Where the voice data comes from

| Producer | Input to the UI |
| --- | --- |
| `erm_native_voice` | RMS dBFS and VAD after microphone gain, every 64 ms; epoch, mute and echo gates are checked before publishing |
| `erm_phrase_voice` | The same measured levels for phrase and phrase-lab capture, plus gate, processing and failure state |
| `erm_voice` | Actual planning/action start, completion, reset and error states |
| `erm_tts` / `erm_tts_port` | Synthesis state, player start, PCM envelope every 64 ms, completion/cancellation and failure |
| `ecai_voice_session` | Existing `arecord`/`aplay` WAVs sampled every 100 ms; synthesis and speaker-scoring state |
| `ecai_voice_live` | The same command adapter around the existing capture/playback and identification loop |

The meter uses a -60..0 dBFS display range. Teal is microphone energy; violet
is output energy. The center bars represent the scalar energy envelope, not
frequency bands. Only the processing arc rotates independently of audio.

Output is measured from actual PCM at the player's elapsed time, not a speaker
loopback device. Player startup and device buffering can offset its timing.
ECAI metering supports the PCM16 WAV files its existing commands produce;
it reads at most a header and a 100 ms window per update. No additional
microphone process is opened.

`erm_voice_events` is supervised in normal ERM sessions and can also be started
by the widget in a standalone GTK session. It keeps bounded local state,
monitors producers, strips everything except phase/level/speech/text, and caps
display text at 240 Unicode characters. It sends no audio or embeddings to GTK.
Slow observers may drop telemetry and recover from a snapshot. GTK owns the
90 ms interpolation between level targets; Erlang does not send frame ticks.
An observer restart recovers the latest cached producer states.

ECAI remains usable without ERM: its UI adapter treats an absent telemetry
module/bus as a no-op. Separate Erlang nodes are not bridged by this patch.

Native capture adds packet `L` with epoch64, float32 dBFS and speech8. TTS adds
`P` and `L` with float32 level, retaining its existing `D` completion packet.
All fields use the existing big-endian packet-4 protocol conventions. Rebuild
both workers to get level metering; older workers cannot provide it.

## Verification

Rebased against `latest-erm.tar(10).gz`. The newer phrase recognition, synthesis
capture, protocol 5/6 and supervisor changes are retained. The phrase controller
distinguishes the 14-byte microphone meter from its existing 9-byte `L` profile
acknowledgement; delayed or gated meter packets cannot dispatch a command.
The ECAI changes retain the same baseline as the original motion patch.

Rebase checks also exercise the phrase controller's live level updates,
stale epochs, pause and TTS suppression, plus the existing native phrase/lab
protocol and build tests. The synthesis laboratory's separate playback port
is unchanged; this patch's phrase-lab metering covers capture.

Validated with OTP 25 and GTK 4.14.5:

- 57 existing/native microphone tests, including the new real native metering
  packet and mute-gate test against the isolated audio/model fixtures.
- 50 TTS tests using the official Piper header and fixture synthesizer/player,
  including playback telemetry, cancellation and the existing echo guard.
- 10 existing ECAI session/live/TTS tests. The optional real eSpeak test was not
  run because eSpeak was unavailable in the validation environment.
- 5 motion/voice tests, including a real C-node/GTK/Xvfb integration test:
  timeline seeking, pause/resume/cancel, completion, reduced motion, destruction
  during animation, CSS class updates, and ECAI PCM adapter → bus → native
  widget input/output changes.
- Inspected the rendered GTK widget using a deterministic PCM fixture.

```sh
sh apps/erm/test/motion/run.sh
sh apps/erm/test/native_voice_isolated/run.sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
sh apps/erm/test/phrase_lab_isolated/run_native.sh
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
```

The motion test uses Xvfb by default. To use an already configured test display,
set `MOTION_USE_DISPLAY=1`. Compilation is strict for the new Erlang code.
The existing GTK CSS loading API emits a deprecation warning on GTK 4.14.

Physical microphone/speaker timing, the installed Whisper/sherpa/Piper models,
and the complete umbrella application's external services were not exercised
here. No models, generated audio, compiled binaries or SDK files are included.


## Verification and training panel

Apply `erm-voice-widget-training.patch` after the motion, heartbeat and
phrase-lab diagnostics patches. The new `erm_voice_training` process keeps lab
calls and status polling away from the GTK owner so inference does not freeze
meter rendering. The lab snapshot is refreshed every 250 ms. Existing input and
output level events continue to animate the meter.

Opening `erm_voice_widget:start()` remains passive. Use **Start session** to
lease the existing phrase capture backend, or the widget will display an
already-running lab. This needs the phrase backend with `lab_enabled => true`
and native protocol 6. A missing speaker profile is supported for first-time
enrolment; command capture stays paused until an identity has been enrolled.
Starting the lab pauses command dispatch and leaves it paused when the session
ends.

1. Select a phrase from the list. Each row shows the complete wake phrase and
   command, for example `bob stop music`, with recorded and trained counts.
2. **Verify voice** captures one diagnostic take through the existing speaker
   and quality checks. Wait for **Speak now**, say the complete phrase and pause.
   The take is not added to the corpus or templates, even when it passes.
   Speaker verification and phrase recognition have separate feedback: a
   verified speaker can still produce no phrase match or the wrong command.
   The recognition line shows the matched command, distance and margin when
   the native recogniser supplies them.
3. **Record take** captures one human training take. The panel shows the live
   listening/processing state, acceptance or rejection, speaker score against
   its threshold, duration, RMS and clipping. Only accepted, distinct takes
   increase the training count. A score of 0.530 against 0.700 remains rejected.
4. After 3 accepted takes, **Train phrase** commits that phrase's verified
   templates. Up to 5 takes are supported; the control shows the saved profile
   revision. This trains phrase recognition, not the enrolled speaker identity.
5. **Cancel capture** cancels only the current capture started by this widget.
   **End session** explicitly ends the displayed lab, including one started in
   the shell. Echo-guard and playback waits disable capture and show a status
   message. Closing the widget ends a session it started; it preserves an
   externally started session and only cancels its own still-active trial.

Verification thresholds are displayed from the backend configuration. The UI
does not lower them or promote a failed speaker take. For a recurring speaker
failure, inspect the microphone/device and enrolled speaker profile first.
Training remains explicit; the widget never enables command dispatch.

The lab adds `verify(Action)` and capture IDs in `record/2` and `verify/1` replies.
`cancel(Id)` rejects a stale ID, protecting a later shell capture from UI
cleanup. `status/0` adds configured prompts and structured training results.
No raw audio, embeddings, features or synthesis model are sent to the widget.

## Named voices and wake phrases

Apply `erm-voice-profiles-wakeword.patch` after `erm-voice-widget-training.patch`,
compile, and restart the phrase backend as described below. These controls use
the existing phrase capture worker; they do not launch a second microphone.

1. Enter a unique voice name such as `Desk voice`, then click **Start enrolment**. It
   opens the lab session automatically, pausing ambient command capture first.
   **Start session** remains available for verification/training without a new
   identity. To build a fresh reference for an existing speaker, click
   **Re-enrol selected voice**. This creates a draft with a unique name such as
   `Steven (2)` and preserves the old profile. The current profile remains
   active while enrolment is pending.
2. Click **Record sample**, wait for **Speak now**, and say the displayed sentence.
   Repeat for five accepted samples. Each sample must meet the duration, RMS,
   clipping and embedding checks. Later samples must agree with the earlier
   samples and with their combined mean. The first accepted sample establishes
   the new reference; it is not required to match the old speaker profile.
   Feedback shows accepted/rejected counts
   and the consistency score; a rejected take can be recorded again.
3. **Save voice** becomes available after five accepted samples. It explicitly
   saves and selects a new speaker profile. Enrolment compares the new takes
   with each other, so a new voice does not have to match the previous identity.
   **Discard enrolment** clears the pending draft, including an active capture.
   A draft started in the shell can also be continued from the widget. Actions
   carry its displayed ID, so a stale click cannot affect a newer draft.
   A draft expires after
   three minutes; unsaved enrolment vectors are not persisted.
4. Select an existing voice from the list to switch back. Profiles have separate
   phrase recordings and templates. Saving a new voice preserves the original
   configured speaker profile and its training data.
5. Enter the wake phrase and click **Apply** (or press Enter). It accepts one to
   four words, normalises case, and updates every command prompt. Selection
   persists across backend restarts. Record and train the complete new phrases;
   switching back restores the previous wake phrase's recordings and templates.

### Enrolment workflow fixes and deletion

Apply `erm-voice-enrolment-controls-fix.patch` on top of
`erm-voice-profiles-wakeword.patch`. Recompile and restart the phrase backend,
lab and widget using the commands below. The widget reports a restart/config
problem when the running backend lacks the expected API or has the lab disabled.

- **Start enrolment** works before a session has been opened. A blank/invalid name
  reports an error before it pauses capture. Opening the widget itself remains
  passive.
- Draft preparation and saving do not wait for the microphone echo guard.
  **Record sample** still obeys playback, processing and echo suppression; the
  status explains the wait. Accepted/rejected counts update after each sample.
- **Discard enrolment** removes unsaved samples. **Delete voice** operates on
  the selected saved profile: the UI names it, changes to **Confirm delete**,
  and offers **Keep voice** to cancel. Deleting the active profile clears its
  native templates and leaves command capture paused until another voice is
  selected or enrolled. The deletion persists across restarts.
- Deletion removes the speaker profile file, including the original configured
  file when that profile is selected. Phrase recordings and templates remain
  on disk; deletion does not recursively remove training directories. A failed
  file cleanup is reported explicitly and never reactivates the removed voice.
- The managed `voices` directory is created with mode `0700`. Existing managed
  directories created at `0755` by earlier wake-specific writes are tightened
  to `0700`, fixing `phrase_directory_must_be_private` when saving a new voice.
  Symlinks and non-directory targets are rejected.

### Explicit enrolment entry and feedback

Apply `erm-voice-explicit-enrolment.patch` after the controls-fix patch above.
It changes the ambiguous **New voice** label to **Start enrolment**, adds
**Re-enrol selected voice**, and puts enrolment at the top of the left column.
Both columns scroll so their controls remain reachable in a tiled window.

The enrolment panel now has its own state and spoken prompt. **Record sample**
is disabled until a draft exists, while the panel says **No enrolment active**.
Empty/duplicate-name errors appear beside the start button. A duplicate name
does not create a draft; select the existing voice and use **Re-enrol selected
voice**, or use an unused name. A re-enrolment draft gets a new unique name and
does not overwrite the selected speaker or its phrase templates.

**Verify voice** and **Record take** belong to phrase verification/training.
They check the saved speaker identity. A rejected phrase take cannot enrol a
new identity. For enrolment, use the sentence beside **Record sample**, accept
five samples, and explicitly **Save voice**. This workflow keeps the usual
duration/RMS/clipping checks and consistency between new samples, without
requiring those samples to match the previous identity. No threshold is lowered.

The existing shell API can also expose this step immediately in a running lab:

```erlang
erm_phrase_lab:enrol_voice(<<"Steven fresh reference">>, 5). %% Use an unused name
erm_phrase_lab:record_voice(). %% Wait for listening; repeat for each sentence
erm_phrase_lab:status().       %% Inspect enrolment.collected and last.check
%% After five accepted samples:
erm_phrase_lab:save_voice().
```

For this UI/controller-only update, compile then reload these two processes:

```erlang
erm_voice_widget:stop().
code:load_file(erm_voice_training).
code:load_file(erm_voice_widget).
erm_voice_widget:start().
```

Phrase capture and training need an enrolled identity. A new installation can
start the session and enrol its first voice even when the configured speaker
file does not exist. An invalid existing speaker file or incompatible model is
still reported as an error. The widget never lowers the speaker threshold to
make enrolment or verification pass. The enrolment consistency threshold is at
least `speaker_threshold` (optionally higher via `enrolment_threshold`).

The manifest is stored beside the configured phrase profile, at
`<profile_file>.voices`. New private speaker profiles are stored under
`voices/<generated-id>.speaker`; training files for each speaker/model/device/
wake binding live under `voices/<binding>/`. The original binding continues to
use its existing phrase profile and corpus. An explicitly configured corpus
path is preserved for that binding and gets a binding suffix for others.
Saving uses the existing private-file and atomic-write helpers. The manifest
contains labels, opaque IDs and selections; the UI receives no embeddings or
filesystem paths. Up to 16 named profiles are supported.

The equivalent lab APIs are:

```erlang
erm_phrase_lab:enrol_voice(<<"Desk voice">>, 5). %% API accepts 3..10 samples
erm_phrase_lab:record_voice().                %% Once per spoken sentence
erm_phrase_lab:status().                      %% Enrolment progress and checks
erm_phrase_lab:save_voice().                  %% Explicitly commit when ready
erm_phrase_lab:set_wake(<<"hey erm">>).
%% Copy a profile ID from status().profiles.voices:
erm_phrase_lab:select_voice(<<"configured">>). %% If an original profile exists
%% Delete a saved profile using its ID from status().profiles.voices:
%% erm_phrase_lab:delete_voice(Id).
```

### What wake training can improve

The current recogniser compares the complete utterance against MFCC/DTW phrase
templates. Training `hey erm stop music` therefore includes the wake phrase and
the command together. Representative human takes can supply better templates
for that person's pronunciation and microphone conditions; improvement must be
measured with separate verification takes. Editing the wake text alone does
not train an acoustic model. Changing the wake selects an empty training set
until matching recordings are added, rather than relabelling old audio.

There is no separate wake-only detector in this update. Such a detector would
need its own positive/negative recordings and false-trigger evaluation. Wake
training also cannot fix a speaker score of 0.530 against a 0.700 identity
threshold: check the capture conditions or enrol a consistent new identity,
then record and train that voice's full phrases.

### Reload on a running node

Compile the patched project with `rebar3 compile`. A normal application/node
restart loads everything. To update a running node with the phrase worker
supervised by `erm_sup`, stop the widget, lab and phrase worker before loading
the changed code. Loading modules alone does not upgrade the backend's stored
profile state:

```erlang
erm_voice_widget:stop().
case whereis(erm_phrase_lab) of
    undefined -> ok;
    _ -> erm_phrase_lab:stop()
end.
ok = supervisor:terminate_child(erm_sup, erm_phrase_voice).
[code:load_file(M) || M <- [erm_native_voice, erm_phrase_codec,
    erm_voice_profiles, erm_phrase_voice, erm_phrase_lab,
    erm_voice_training, erm_voice_widget]].
supervisor:restart_child(erm_sup, erm_phrase_voice).
erm_voice_widget:start().
```

Wait for `erm_phrase_voice:status()` to show `ready => true`, then use **Start
enrolment** or **Start session**. If the worker is started manually, stop
and restart it using the same options instead of the supervisor calls.

### Validation

```sh
sh apps/erm/test/phrase_lab_isolated/run_erlang.sh
sh apps/erm/test/motion/run.sh
sh apps/erm/test/voice_widget_training/run.sh
```

The last test requires GTK4, Erlang/EUnit, Xvfb, xauth, xdotool and a C++ compiler.
It uses real native GTK buttons through XTEST mouse events, production lab and
speaker-check policy, and a deterministic native packet fixture. It checks
passive opening, live metering/processing, failed and successful verification
without corpus writes, rejected-take feedback, three accepted training takes,
template persistence, direct phrase selection, typing/applying a wake phrase,
five-sample voice enrolment and explicit saving, profile switching, restoration
of earlier training, automatic session opening from Start enrolment, discarding a
draft, deletion confirmation/cancellation, disabled controls and owned-session
cleanup.
Backend tests also cover first-time enrolment and restart persistence, rejected
and duplicate enrolment takes, invalid wake phrases, stale cancellation IDs,
continuing a shell-created draft, private-directory repair and deletion of both
managed and original speaker profiles without deleting phrase templates.
The GTK workflow also reproduces a failed old-profile verification and a
duplicate-name attempt, then re-enrols five samples that fail the old identity
check. It verifies that the saved new reference accepts that voice and that the
old profile survives until explicitly deleted. These are deterministic packet
fixtures exercising real GTK clicks, not a claim about live model accuracy.
`WIDGET_SCREENSHOT_DIR` optionally saves screenshots
using ImageMagick's `import`; `MOTION_USE_DISPLAY=1` uses an existing X display.

The fixture does not validate microphone hardware, speaker-model accuracy or
ECAI responses on the target machine. Those still require a live voice take.
