# ECAI voice calibration failure diagnostics (ERM)

The calibration profile is deliberately **not** created unless a global distance
threshold separates the known-speaker development recordings from the nearest
competing references, and each known speaker wins its own ranking.

`calibration_not_separable` is a measurement, not an OTP or elliptic-curve
failure. In particular, two different names for the same human speaker cannot
be learned as two distinct speakers.

## Operator commands

When the interactive loop stops after failed calibration, the accepted WAV
recordings remain in the operator session. No standalone scripts are required:

```erlang
%% Examine the previously captured enrollment/calibration WAVs:
{ok, Report} = erm_voice_loop:diagnose().

%% Same command for an explicit session directory:
{ok, Report} = erm_voice_loop:diagnose(
    "/home/steven/.local/state/ecai/voice").

maps:get(summary, Report).
maps:get(known_misranked_files, Report).
maps:get(recordings, Report).
```

This prints one diagnostic row per calibration recording, with its expected
label, nearest enrolled label, own distance, nearest other distance, and margin.
It also prints basic voice quality information. The function performs the
normal integer and secp256k1 curve comparisons and asserts equality for all
examined distances; it is **read-only**, never updates the voice profile, and
never evaluates held-out `test` rows.

After a failed run, either use **genuinely different people** under different
labels or create a **new session** when changing labels:

```erlang
erm_voice_loop:run(#{
    session => "/home/steven/.local/state/ecai/voice-two-people",
    speakers => [<<"steven">>, <<"other_person">>],
    enroll_takes => 3,
    calibrate_takes => 3,
    unknown_calibration => no,
    seconds => 6
}).
```

`unknown_calibration => no` is appropriate if a genuinely different third
speaker is not present; it is **not** evidence that unknown rejection works.
Using three enrollment and calibration takes is an experimental starting point
and does not guarantee separability. Use different questions and distinct
recordings, keeping a consistent microphone, position, and capture environment.

When you do have a real third speaker, enable unknown calibration separately;
the unknown calibrator must not also be one of the two enrolled speakers.

Do **not** change the calibration thresholds to force a result: the rejected
sample is already closer to another speaker under the current metric. If two
different human voices remain indistinguishable after controlled recordings,
that is a failure of the acoustic descriptor and requires feature/matching
improvements and independent evaluation.

## Testing and build

The voice test runner compiles `ecai_voice_diagnostics.erl` and runs
`ecai_voice_diagnostics_tests.erl` alongside the previous EUnit tests:

```bash
bash apps/ecai/test/run_voice_poc.sh test
```

The unit tests include a separable synthetic dataset, a deliberately
mislabelled synthetic calibration recording, and a test confirming that
held-out test WAVs are never opened during the diagnostic. These synthetic
tests do not validate human speaker recognition.
