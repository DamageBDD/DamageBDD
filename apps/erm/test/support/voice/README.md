# Shared voice test fixtures

The voice smoke, Ollama-pull and TTS discovery runners compile the production
modules from `apps/erm/src`. They share these doubles for the external HTTP and
codec dependencies:

- `damage_gun.erl.src`: deterministic Ollama responses. Each runner explicitly
  selects `voice` or `pull` using `{erm_voice_test, http_scenario}` in its fresh VM.
  Existing per-test modes control answers, blocking, missing models and failures.
- `jsx.erl.src`: an offline Erlang-term codec. It is paired with the HTTP double;
  these isolated suites do not validate real JSON encoding or HTTP transport.

Keep doubles as `.erl.src` (or `.erl.fixture`), never as compilable `.erl` files
in the repository. Runners copy them into a temporary directory before compiling
and remove it on exit. This keeps recursive rebar test compilation from picking up
modules with the same names as production dependencies.

Suite-specific playback, ECAI and native-protocol doubles stay with their suites.
In particular, the coordinator integration suite simulates blocked and unavailable
players, while the smoke suite exercises queue navigation and reports playlist
updates. They test different external behaviours; neither duplicates voice logic.
