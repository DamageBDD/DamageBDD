# Erlang Voice POC — delivery validation

## Read this first

**Erlang compilation, EUnit execution, the Erlang demo, and full DamageBDD/ECAI
integration tests were NOT run in the delivery environment.** Neither `erl` nor
`erlc` was available. Installing a runtime was blocked by network access. The
provided runner correctly stopped with exit status 127:

```text
Missing erlc: install Erlang/OTP compiler, crypto and EUnit, then rerun.
```

No claim of a passing Erlang build or human-speaker accuracy is made. Run the
provided isolated test runner on your node before deployment.

## Input and change scope

Input: `latest-ecai.tar.gz` supplied in this conversation.

SHA-256:

```text
d757b6daf607f1ba5083a5d6cdaa4849f006d6677e9fa8441cc8513d60ca5154
```

The patch adds six production modules, four EUnit modules, the runner, an example
dataset and documentation/reference files under `apps/ecai/`. It makes no edits
to existing files, supervisors, the application resource, microphone code, NIFs,
HTTP routes, ECAI index identifiers, or configuration.

## Checks performed in the delivery environment

| Check | Result |
| --- | --- |
| Independent NumPy/SciPy acoustic reference | Passed the synthetic calibration/classification assertions |
| OpenSSL-backed compressed-point reference | Generated and checked the EUnit vectors for 1G, 2G, 17G and 255G |
| Erlang lexical delimiters, export definitions and clause grouping | Checked all ten added Erlang files; no issue found by these limited checks |
| Golden 30-coordinate acoustic vector | Matches the independent numerical reference used by the test suite |
| Bash runner syntax (`bash -n`) | Passed |
| Patch whitespace (`git diff --cached --check`) | Passed |
| Fresh-archive `git apply --check` and actual application | Passed; added file bytes verified, all 331 existing files unchanged |
| Erlang compiler / EUnit / native demo | **Not executed — missing runtime** |
| Real human recordings | **Not evaluated** |
| Complete application/rebar build | **Not executed** |

Lexical checks are not a compiler, type checker, or runtime substitute. `static-checks.json` records the source hashes and the scope
of those checks.

## Independent numerical observations — Python, NOT Erlang

The optional checker at `test/voice_reference/check_reference.py` reproduces the
Erlang fixture formulas using NumPy/SciPy and evaluates their intended descriptor.
It does not execute or import the Erlang implementation. Its results are captured
in `test/voice_reference/reference-results.json`.

Synthetic calibration: worst genuine distance **36**, nearest impostor distance
**308**, minimum genuine margin **272**. The resulting development radius is **172**
and required margin is **136**.

| Held-out synthetic fixture | Reference assignment | Distance | Margin |
| --- | --- | ---: | ---: |
| `voice_a_3` | voice_a | 22 | 300 |
| `voice_b_3` | voice_b | 43 | 262 |
| `unknown_3` | Unknown / not accepted | 337 | 192 |

The reference also assigned the synthetic timeline as A, B, A, unknown. Silence
is handled by the Erlang quality-gate tests, which remain unrun. A same-pitch,
different-envelope pair had integer descriptor distance **211** in the independent
reference; this does not establish human-speaker discrimination.

These observations justify test fixtures with substantial calibration margins.
They are NOT measured Erlang results, speech-recognition benchmarks, false-accept
estimates or evidence of deployment readiness.

## Supplied EUnit coverage

There are **19 EUnit test/test-generator entry points** across four modules. Some
entry points contain multiple assertions or loops, including an exhaustive 33×33
small-coordinate grid and full-bound endpoint comparisons.

The suites cover point encodings/group distances, invalid vectors, FFT versus a
small direct DFT, autocorrelation, quantiles, independent feature vectors, gain
variation, same-pitch spectral-envelope differences, short/silent/clipped/noisy
input, PCM/WAV bounds, odd chunks, duplicate chunks, sample-rate rejection,
antiphase stereo, separate calibration, calibration failure, test isolation,
duplicate-audio leakage, integer/curve agreement, unknown rejection, coarse
windows, short tails, profile checksums/schema/points, compression rejection and
local profile persistence. The runner additionally reloads a demo profile in a
fresh VM.

## Run on your node

```sh
bash apps/ecai/test/run_voice_poc.sh
```

The runner uses `erlc -Werror`, writes logs under `_build/ecai_voice_poc/reports`,
and exits nonzero on failure. An actual pass of that command is the next gate;
independent real recording evaluation is a separate gate after that.
