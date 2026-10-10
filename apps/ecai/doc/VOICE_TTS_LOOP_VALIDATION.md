# ECAI TTS loop — delivery validation

Date: 8 October 2026. Scope: follow-up to `ecai-voice-erlang.patch` based on the
uploaded `latest-ecai.tar.gz`. No inference of production readiness is made.

## Results actually observed

| Check | Observation |
|---|---|
| Bash orchestrator tests with fake Erlang/audio commands | **20 tests passed** |
| Prompt playback ends before capture, including configured guard | Passed in mocked event-order/timestamp tests |
| TTS/playback/compiler/profile/capture/scorer failures | Passed fail-closed orchestration checks |
| Failed calibration cannot enter test loop | Passed with fake backend returning calibration failure |
| Separate takes, rejected samples, optional unknown, resume | Passed orchestration checks |
| Literal device argument handling and invalid-label rejection | Passed injection-regression checks |
| Concurrent session lock, SIGTERM and SIGINT cancellation | Passed against the fake recorder process |
| Hung-recorder deadline and session recording budget | Passed orchestration checks |
| Private directory/file permissions | Passed on created mock session files |
| Real offline eSpeak synthesis | Produced a nonempty mono PCM16 WAV at 22,050 Hz |
| Bash syntax checks | Passed for both runners |
| Incremental and complete Git patches | Passed check and actual application to fresh source trees |
| Original uploaded source files | All 331 preserved byte-for-byte |
| Native Erlang compiler/EUnit | **NOT RUN: `erlc` and `erl` unavailable** |
| Physical playback/microphone acquisition | **NOT RUN** |
| Native recognition, human accuracy, full DamageBDD startup | **NOT RUN** |

The actual native compile gate exited **127**, reporting `Missing erlc`.
The orchestration tests deliberately supply mock executables through an isolated
PATH. They exercise the delivered Bash script, but their voice decisions are
canned test values. They do not run Erlang, extract acoustic features or prove
physical-device correctness. The original POC's lack of native validation remains.

The real synthesis check used the installed eSpeak 1.48.15 to write a prompt WAV.
The waveform was inspected for PCM structure and nonzero length, not played.
The 22,050 Hz output is the TTS playback asset; microphone data requested by the
loop is independently 16,000 Hz, mono PCM16.

Captured logs: `test/voice_loop/reports/orchestration.log`, `native-gate.log`, and
`tts-synthesis.json`. The source ZIP does not include mock recordings or the
synthesized prompt as reference speaker data.

## Added code and native tests

`src/ecai_voice_loop.erl` is the CLI/file bridge to the existing recognizer.
`test/run_voice_loop.sh` handles local TTS, terminal prompts and finite capture.
`test/ecai_voice_loop_tests.erl` has five EUnit entry points, including a synthetic
end-to-end session generator. These tests are added to `run_voice_poc.sh`.
`test/voice_loop/test_orchestration.py` contains the 20 executed mock tests.

Recognition, curve arithmetic, acoustic features, the ECAI microphone service,
supervisors, application configuration and NIFs are unchanged. The old six
production voice POC modules are retained byte-for-byte.

## Limits

The loop's software ordering is not echo cancellation. A successful prompted
recording is not proof of a live speaker. The interactive workflow is a diagnostic,
not an independent test of biometric accuracy. No live sample is automatically
added to the profile. Failed calibration stays failed, without relaxed thresholds.

Run `bash apps/ecai/test/run_voice_poc.sh test` on the target ECAI machine, then
check the actual playback/capture devices before collecting human observations.
