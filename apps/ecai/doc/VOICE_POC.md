# ECAI Voice POC — Erlang implementation

A local, non-neural, enrolled-speaker matching experiment. It measures acoustic
features, stores bounded secp256k1 coordinates, performs actual point subtraction,
and checks its distances against an ordinary integer control. It does not turn
exact audio hashes into a noise-tolerant speaker identity.

**Validation status:** this delivery was prepared without an Erlang runtime. The
Erlang compiler and EUnit suite have NOT been run here. The standalone runner exits
127 with `Missing erlc` in this environment. An independent NumPy/SciPy numerical
reference was run successfully against the same synthetic-fixture design. Those
results are NOT a substitute for running the Erlang tests on your node. See
`VOICE_POC_VALIDATION.md` for the exact distinction.

## Apply and run

From the DamageBDD repository root, after applying the patch:

```sh
bash apps/ecai/test/run_voice_poc.sh test
bash apps/ecai/test/run_voice_poc.sh demo
```

Or run both with a separate-VM profile reload:

```sh
bash apps/ecai/test/run_voice_poc.sh
```

The runner compiles only the six new `ecai_voice*.erl` modules and their four
EUnit modules. It does NOT boot DamageBDD, ECAI supervisors, microphone capture,
HTTP services, code learning, GPUs, or the existing ECAI NIF. No rebar dependency
fetch is required. It uses `erlc -Werror +debug_info`, records logs, and returns
nonzero on compilation, test, demo, or profile-reload failure.

Target: Erlang/OTP 25 or newer, with the compiler, `crypto`, and `eunit` installed.
This is an intended compatibility range, not a matrix tested in this environment.
No added application dependency or change to `ecai.app.src` is required. Normal
rebar builds discover the new modules in `src/`; the isolated runner also works
when unrelated application compilation is failing.

Default output:

```text
_build/ecai_voice_poc/
  ebin/                         New production/test BEAM files after compilation
  reports/compile.log
  reports/eunit.log
  reports/demo.log
  reports/fresh-vm-reload.log
  demo/dataset.term             Generated dataset with absolute WAV paths
  demo/voices.ecv                Versioned local matching profile
  demo/results.term             Curve/control metrics and timeline results
  demo/timeline.wav             A / B / A / unknown / silence
```

Set `ECAI_VOICE_BUILD_DIR` to choose a different output location. The script can
be launched from any directory. `compile`, `test`, `demo`, and `all` modes are
available; `all` is the default.

## Use from the running Erlang node

Compile using the standalone runner first, then in the node shell, with the
repository root as the working directory:

```erlang
code:add_patha(filename:absname("_build/ecai_voice_poc/ebin")).
{ok, _} = application:ensure_all_started(crypto).

{ok, VoiceDemo} = ecai_voice_demo:run("_build/ecai_voice_manual").
maps:get(calibration, VoiceDemo).
maps:get(counts, maps:get(curve, VoiceDemo)).

{ok, VoiceProfile} = ecai_voice:load("_build/ecai_voice_manual/voices.ecv").
ecai_voice:identify_wav(VoiceProfile, "_build/ecai_voice_manual/voice_a_test_3.wav").
ecai_voice:scan(VoiceProfile,
    {wav, "_build/ecai_voice_manual/timeline.wav"}, 2000).
```

On an existing node that has already loaded an earlier version of these modules,
reload the newly compiled modules with `code:load_file/1` before testing. The new
modules maintain no named process, persistent_term entry, or ETS table.

## Real recording experiment

Use separate takes for enrollment, calibration and final testing. Start with
5–10 seconds per take, one active speaker, different phrases, and quiet recording
conditions. The implementation accepts 1.5–30 seconds per classification clip.
Do not reuse enrollment audio by renaming it, changing gain, or taking overlapping
crops. For meaningful generalization, separate sessions and microphones between
reference and final testing.

Input contract:

* WAV: RIFF/WAVE, integer PCM16 little-endian, exactly 16,000 Hz, one or two channels.
* Raw: signed PCM16 little-endian, 16,000 Hz, **mono**.
* Unsupported rates/formats fail explicitly. There is no implicit resampling,
  compressed codec, FFmpeg subprocess, or Python dependency in the recognizer.

Stereo WAV input selects the higher-variance channel; equal variances select the
first channel. It never averages opposite-phase channels. Select a fixed channel
with `ecai_voice:build(Rows, #{channel => 0})` or `#{channel => 1}`. The policy is
stored in the profile. A channel-1 profile cannot classify mono raw PCM.

An example dataset is supplied at `apps/ecai/examples/voice_dataset.term`. Paths
in this hand-written example are relative to the current working directory,
not the manifest file's directory.

```erlang
{ok, [VoiceRows]} = file:consult("apps/ecai/examples/voice_dataset.term").
{ok, MyVoiceProfile} = ecai_voice:build(VoiceRows).
ok = ecai_voice:save("_build/my_voices.ecv", MyVoiceProfile).

{ok, VoiceReport} = ecai_voice:evaluate(MyVoiceProfile, VoiceRows).
maps:get(counts, VoiceReport).

{ok, IntegerReport} = ecai_voice:evaluate(MyVoiceProfile, VoiceRows, integer).
maps:get(counts, IntegerReport).

ecai_voice:identify_wav(MyVoiceProfile, "recordings/alice_test.wav").
ecai_voice:scan(MyVoiceProfile, {wav, "recordings/conversation.wav"}, 3000).
```

`file:consult/1` is for your trusted local manifest; do not expose it as an
untrusted network-input parser. Speaker labels are 1–64-byte binaries. The atom
`unknown` is reserved for unenrolled calibration/test examples. Two to 100 known
speakers are supported, with at most 20 enrollment templates per speaker and 200
rows total. Multiple enrollment rows for one speaker are supported.

A typical row is:

```erlang
#{speaker => <<"alice">>, split => enroll,
  source => {wav, "recordings/alice_enroll.wav"}}.
```

For raw audio, use `source => {pcm16, PCM}`. Example:

```erlang
{ok, PCM} = file:read_file("recordings/alice.s16le").
{ok, Features} = ecai_voice:extract_pcm(PCM).
maps:get(q, Features).
maps:get(quality, Features).
ecai_voice:identify_pcm(MyVoiceProfile, PCM).
```

## Calibration, decisions and evaluation

Build opens only `enroll` and `calibrate` sources. It never opens or scores test
sources, and a test asserts that nonexistent test paths do not affect build.
Every known speaker needs a separate calibration recording. Including an
unenrolled calibration voice is strongly recommended; `unknown_count` explicitly
reports whether one was used. The final unknown test should ideally be a different
unenrolled person.

Let `G` be the largest genuine calibration distance, `I` the smallest impostor
calibration distance, and `M` the smallest known-speaker margin. Calibration must
satisfy `G < I` and `M > 0`. Otherwise no profile is returned:

```erlang
{error, {calibration_not_separable,
    #{worst_genuine => G, nearest_impostor => I,
      minimum_genuine_margin => M, known_count => NK, unknown_count => NU}}}.
```

The accepted radius is `(G + I) div 2`. The required best-versus-second-best gap
is `max(1, M div 2)`. These are small-development-set heuristics, NOT confidence
probabilities, estimated false-accept rates, or statistical guarantees. A failed
calibration is evidence to improve recordings/features; do not tune on the test set.

Each label's score is its nearest enrollment template. Ties are broken by binary
label ordering and template index, and the positive margin requirement prevents a
tie from being accepted. Enrollment templates have a deterministic PCM-hash order.

Possible outcomes:

```erlang
{ok, #{status => matched, speaker => <<"alice">>, ...}}.
{ok, #{status => unknown, speaker => undefined, reason => too_far, ...}}.
{ok, #{status => unknown, speaker => undefined, reason => ambiguous, ...}}.
{ok, #{status => insufficient_audio, speaker => undefined, ...}}.
{error, Reason}.
```

Bad files, incompatible profiles, invalid inputs and algebraic failures are errors,
not guessed speaker assignments. Quiet/short/clipped or insufficiently periodic
samples produce `insufficient_audio` during identify/evaluate/scan. Such clips fail
build, because unusable calibration evidence must not silently be discarded.

SHA-256 of canonical mono PCM detects exact duplicate audio even when WAV metadata
or an unselected stereo channel changes. Duplicates across enrollment/calibration
fail build; duplicates against development or earlier tests fail evaluation.
Identify allows an enrolled recording but labels it `seen_during_build => true`.
Gain changes, overlapping crops, and same-session correlations are not detected as
leakage. Recording provenance remains the operator's responsibility.

Evaluation separately reports known correct matches, known wrong matches, known
abstentions, unknown rejections, unknown false matches, and insufficient audio.
An insufficient unknown recording is an abstention, not a successful unknown test.
Elapsed evaluation time includes curve-table setup, profile validation, WAV reads,
feature extraction and matching. Both backends perform the same validation; only
the scoring arithmetic differs. Measure on your node before making latency claims.

## Frontend and elliptic representation

The versioned frontend uses 640-sample (40 ms) frames at a 160-sample (10 ms) hop:
DC removal, energy gating, pre-emphasis, Hann windows, a radix-2 FFT, 32 normalized
mel filters from 80 to 7600 Hz, 13 non-energy cepstral coefficients, median/IQR
aggregation, and normalized autocorrelation pitch/periodicity measurements.

The resulting 30 coordinates are quantized by 32 into `[-255,255]`. The frontend
requires at least 0.75 approximate active seconds and 0.25 approximate periodic
seconds, rejects more than 2% full-scale clipping and more than three saturated
coordinates, and checks input length/range. These guards are heuristics, not a
certified speech, overlap or spoof detector. Whispered and out-of-range voices can
be rejected. Pitch analysis is approximately restricted to 60–400 Hz.

For each coordinate `q`, store `[q]G` on secp256k1. Matching computes actual
`[q]G - [r]G` and looks up the difference in `[-510,510]`. Input encodings must be
canonical members of the allowed bounded table before reaching group arithmetic.
The implementation checks exact equality of curve and integer L1 distances on
every curve-backed comparison. A mismatch stops the operation.

This is a reference implementation with variable-time public-coordinate arithmetic.
It does not use the existing hash-to-Curve25519 mapping or change any ECAI content,
frame, utterance or NFT identifier. It does NOT supply encryption, proof of a live
person, post-quantum security or a superior speaker metric just by using a curve.
It also does not claim a performance advantage over direct integer subtraction.

The Erlang frontend/schema has its own version ID. It is not a drop-in loader for
the previous Python JSON profiles: input formats, FFT padding implementation and
half-way rounding differ. Re-enroll/recalibrate when changing frontend versions.
The optional independent reference checker is development tooling only.

## Relationship to the supplied ECAI audio code

The archive includes `ecai_audio_features`, `ecai_audio_frame`,
`ecai_audio_utterance`, `ecai_audio_utterance_verify`, `ecai_mic_stream`, and
`ecai_vad`. Their existing byte/point identity path is unchanged.

In the supplied `ecai_mic_stream`, subscribers receive point/event metadata, not
raw PCM. A voice cannot be reconstructed from those hashes. A future live adapter
must buffer raw **mono PCM before hashing** and pass a complete window to
`identify_pcm/2`. This patch does not silently subscribe to point events, change
microphone privacy, or reinterpret existing utterance verification as speaker ID.
It also does not change the microphone module's existing stereo downmix policy.

Keep reference DSP work out of latency-sensitive callback bodies. Run batches in
ordinary supervised workers when integrating this library into production. This
POC adds no worker or supervisor itself; failure supervision/capture backpressure
are integration work, not secretly implemented here.

## Scope and handling profiles

`scan/3` produces fixed, non-overlapping windows for **enrolled labels**. Its window
argument is milliseconds. It does not estimate exact turn boundaries, distinguish
multiple unknown speakers, detect overlap, or separate simultaneous voices. A
mixed-speaker window may be misassigned. Short final windows explicitly abstain.

Profiles are uncompressed, size-bounded ETF inside a version/length/SHA-256 envelope.
Loading uses `binary_to_term(...,[safe,used])`, checks consumed length and schema,
and validates coordinates against points. Compressed payloads are rejected to
avoid decompression expansion. Writes use an exclusive temporary file, owner-only
permissions, file sync and rename. Directory metadata is not explicitly fsynced;
this is not a claim of full power-loss transaction durability on every filesystem.

The checksum is NOT a signature or MAC. Anyone who can replace a profile can
recompute it. Treat profiles as sensitive, trusted local data. Bounded coordinates
are recoverable and the integer features are stored in plaintext. Do not publish
them to a global index or use this POC for access-control authentication.

## Source layout

| File | Responsibility |
| --- | --- |
| `src/ecai_voice.erl` | Build, calibration, matching, evaluation, scan, persistence |
| `src/ecai_voice_wav.erl` | Strict bounded WAV and mono-PCM handling |
| `src/ecai_voice_dsp.erl` | Pure Erlang reference FFT, mel/DCT and quantiles |
| `src/ecai_voice_features.erl` | Versioned acoustic descriptor and quality gates |
| `src/ecai_voice_curve.erl` | Public bounded secp256k1 encoding and exact comparison |
| `src/ecai_voice_demo.erl` | Procedural fixtures and complete offline demonstration |
| `test/ecai_voice*_tests.erl` | EUnit suites, including numerical reference vectors |
| `test/run_voice_poc.sh` | Isolated compilation, tests, demo and fresh-VM reload |
| `test/voice_reference/` | Optional independent Python numerical checks and results |

Reference documentation: Erlang EUnit guide
<https://www.erlang.org/doc/apps/eunit/chapter.html>, external-term decoding
<https://www.erlang.org/doc/apps/erts/erlang.html#binary_to_term/2>, and crypto APIs
<https://www.erlang.org/doc/apps/crypto/crypto.html>. These references document OTP
interfaces; they do not validate the acoustic recognizer.
