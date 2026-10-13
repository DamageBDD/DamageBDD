# ECAI voice: one-command Erlang/ERM operator loop

**Entry point (running ERM shell):**

```erlang
erm_voice_loop:start().
```

`start/0` deliberately runs **synchronously in the calling Erlang shell** so
`io:get_line/1` has exclusive access to the operator's terminal. You don't
need to run any standalone enrollment, TTS, or test orchestration scripts.
Type `q` at a prompt to exit normally. The subsequent invocation resumes the
same persistent development session or loads the saved calibrated profile.

On first run it:

1. Verifies `espeak-ng`, `aplay` and `arecord` on **the Erlang node host**.
2. Requires affirmative consent for local recording.
3. Asks for two or more speaker labels; pressing Enter uses `speaker_a,speaker_b`.
4. Uses spoken prompts, records and checks the enrollment takes and fresh
   calibration takes; Enter accepts a usable take, `r` rerecords it, `p`
   plays it for review and `q` safely exits.
5. Optionally requests a third person to calibrate unknown-speaker rejection.
6. Calls `ecai_voice_loop:build/1` and `ecai_voice:load/1`. A failure to
   separate development voices refuses to build a profile. The operator may
   explicitly archive the development recordings and retry; no test recordings
   are used for tuning.
7. Enters a repeated TTS → 6-second WAV → elliptic matching → voiced feedback
   cycle; Enter gives an unlabelled diagnostic, a speaker label/`unknown`
   supplies diagnostic ground truth and `q` quits.

Subsequent runs skip enrollment when `voices.ecv` exists and validates.
Interrupted enrollment resumes from already accepted takes. A lock prevents
concurrent loops from writing into the same session. If the VM was forcibly
terminated, the stale `.voice-operator.lock` directory must be checked and
removed manually **only after confirming no other session is active**.

## Examples

```erlang
%% Inspect the default saved state; no audio tools or recording required.
erm_voice_loop:inspect().

%% Start the complete guided workflow with default settings.
erm_voice_loop:start().

%% Advanced one-command setup with selected ALSA devices and more calibration.
erm_voice_loop:run(#{
    session => "/var/lib/damage/ecai-voice-operator",
    speakers => [<<"alice">>, <<"bob">>],
    device => "default",
    playback => "default",
    seconds => 6,
    settle_ms => 1000,
    enroll_takes => 2,
    calibrate_takes => 2,
    unknown_calibration => ask,
    backend => curve,
    speak_results => true
}).
```

The optional `start(#{profile => ..., session => ...})` from the previous patch
still starts the **asynchronous, test-only** gen_server. It does not run the
wizard; use `start/0`, `run/0`, or `run/1` for first-run initialization.

For audio access on Debian/Ubuntu:

```sh
sudo apt-get install espeak-ng alsa-utils
arecord -l
aplay -l
```

The commands and devices run on the machine hosting the Erlang VM, not on the
workstation connected to a remote shell. Use headphones. Audio format is
strict 16 kHz mono PCM16 little-endian WAV; unsupported or incomplete captures
are rejected. This module does not install OS packages, change system audio
routing, or require a neural model/NIF.

## Persistence and operating constraints

Default state: `$XDG_STATE_HOME/ecai/voice` or
`$HOME/.local/state/ecai/voice`; falling back to
`_build/ecai_voice_operator` if neither variable exists.

```
voice/
  speakers.txt             # speaker labels
  develop/                 # accepted enrol/calibration WAVs
  takes/                   # each development attempt (including retries)
  archive/                 # earlier development attempts after explicit retry
  voices.ecv               # versioned calibrated ECAI profile
  dataset.term             # profile build dataset
  tests/                   # every test WAV, *.result.term, *.feedback.txt
```

Session folders are changed to mode 0700, and recorded and generated files to
0600. This is local experimental storage; it is not encryption, speaker
liveness verification, or biometric authentication. Do not publish templates
or retain identifiable voice samples without an appropriate retention policy.

A two-person calibration can reject real human recordings because the current
non-neural features are not proven robust for arbitrary speakers. This is an
**explicit experimental failure**, not a cue to weaken thresholds. The
curve/integer comparison checks algebraic consistency; it does not certify
speaker recognition accuracy or post-quantum protection.

## Build and automated checks

Compile your normal application or run the isolated ECAI test runner:

```sh
rebar3 compile
bash apps/ecai/test/run_voice_poc.sh test
```

The isolated runner is a *test harness only*, never a prerequisite for running
`erm_voice_loop:start().` from a node with the modules on the code path.
`ecai_voice_session_tests` exercises options, saved speaker manifests,
pre-populated development state and profile inspection. It does **not**
exercise a physical microphone or TTS hardware. Complete native compilation
and hardware testing must run on your machine.
