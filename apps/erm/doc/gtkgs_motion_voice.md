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
