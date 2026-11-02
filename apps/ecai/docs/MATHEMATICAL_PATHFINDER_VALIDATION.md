# Validation record — 16 October 2026

## Executed successfully

- Independent Python standard-library reference suite: **12 tests passed**.
- The rational-kernel grid within that suite checked **220 nonsingular cases**,
  including nonzero and fractional kernels.
- The portable demo's two rational maps each passed an exact polynomial identity
  check using a degree bound of ten and eleven distinct exact evaluations.
- The reference suite rejected wrong map coefficients, wrong codomains, wrong
  degrees, zero denominators, singular sources and disconnected/tampered paths.
- `python -m py_compile` passed for the optional Sage exporter.
- `bash -n` passed for the native test runner.

## Not executed successfully here

- **Native Erlang compilation and the 57 provided EUnit test functions were not
  run.** This environment has neither `erl` nor `erlc`; attempts to obtain the
  runtime failed. Running the isolated script exited 127 with:
  `Erlang/OTP 27+ compiler (erlc) is required.`
- SageMath itself is unavailable. The exporter was syntax-checked, not exercised
  against a live Sage installation.
- No full DamageBDD release build, live Gherkin runner, network service, IPFS
  publication, consensus verification or production deployment was performed.

The independent reference tests validate the mathematical fixtures and reference
checker. They do **not** substitute for compiling or executing the Erlang source.
Run the isolated EUnit suite on your OTP host before integrating the change:

```bash
bash apps/ecai/test/math_pathfinder/run.sh --demo
```

## Patch baseline

Only new files are added under `apps/ecai` and `apps/damage`. The patch does not
modify existing supervisors, app configuration, dependencies, NIFs, or relation
rules. The existing relation API was inspected from `ecai_relation_core.patch`;
the newer ECAI archive's raw-file materialization was unavailable. The available
14 October Damage source archive was inspected for the step callback convention.
This is therefore an additive implementation, not a claim of a complete build
against the user's latest uncommitted ECAI checkout.
