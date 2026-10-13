# Validation record

The generated managed-fixture package received these artifact checks:

- Erlang module filenames match their `-module(...)` declarations.
- Delimiters and preprocessor blocks are balanced outside comments and strings.
- No changed source file contains trailing whitespace or tab characters.
- The BDD runner passes `bash -n`.
- The runner contains no `python3 -m http.server`, fixture PID ownership, or
  shell-side fixture shutdown logic.
- Fixture files in `priv` decompress byte-for-byte to the packaged source
  sidecars.
- Every JSONL content-fixture line parses as a JSON object.
- The listener defaults to loopback and rejects non-loopback addresses without
  an explicit opt-in.
- File routes are generated from validated fixture names rather than request
  path values.
- Catalog publication uses a synchronized temporary file followed by atomic
  rename.
- Served files have SHA-256-derived ETags and bounded single-range handling.
- Configuration fragments contain one non-duplicated managed-fixture profile.
- The binary Git patch applies to a reconstructed baseline and reproduces the
  packaged source, tests, scripts, configuration, documentation, and fixtures.
- Package and individual-file SHA-256 checksums are generated and verified.

Erlang/OTP and Rebar3 are not installed in the artifact environment. Run these
runtime gates in DamageBDD:

```sh
rebar3 as test clean
rebar3 as test compile
rebar3 eunit --module=ecai_wikimedia_fixture_handler_tests
rebar3 eunit --module=ecai_wikimedia_fixture_server_tests
rebar3 eunit --module=ecai_wikimedia_fixture_supervision_tests
rebar3 eunit --module=ecai_wikimedia_fixture_source_coherence_tests
rebar3 eunit --application=ecai
rebar3 xref
```
