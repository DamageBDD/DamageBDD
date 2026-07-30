# OTP-managed Wikimedia fixture service

The Wikimedia BDD corpus is now served by the ECAI application instead of a
shell-owned `python3 -m http.server` process.

When `wikimedia_fixture_server_enabled` is true, `ecai_app` installs
`ecai_wikimedia_fixture_server` as a permanent child of the ECAI root
supervisor. The worker owns a dedicated Cowboy listener and is restarted by
OTP after an abnormal exit.

The feature is disabled by default.

## Runtime model

```text
ecai_app
   |
   +-- ecai_sup
          |
          +-- ecai_wikimedia_fixture_server
                  |
                  +-- dedicated Cowboy listener
                  +-- generated pinned catalog
                  +-- immutable fixture file routes
```

The listener is separate from the authenticated ECAI API listener because the
fixture URLs are consumed as Wikimedia source URLs. It binds to loopback by
default and rejects a non-loopback address unless the operator explicitly opts
in.

## Files

```text
apps/ecai/src/ecai_wikimedia_fixture_server.erl
apps/ecai/src/ecai_wikimedia_fixture_handler.erl
apps/ecai/src/ecai_app.erl
apps/ecai/src/ecai_wikimedia_ops.erl

apps/ecai/priv/wikimedia-fixtures/
  pageviews-202606-user.txt
  pageviews-202606-user.bz2
  enwiki_content-20260720-00000.json
  enwiki_content-20260720-00000.json.bz2

apps/ecai/test/ecai_wikimedia_fixture_handler_tests.erl
apps/ecai/test/ecai_wikimedia_fixture_server_tests.erl
apps/ecai/test/ecai_wikimedia_fixture_supervision_tests.erl
apps/ecai/test/ecai_wikimedia_fixture_source_coherence_tests.erl
```

Rebar3 includes an application's `priv` tree in development builds and OTP
releases, so the same fixture-discovery code works in both environments.

## Configuration

Merge the entries from:

```text
config/ecai-bdd/ecai_bdd_integration.config.fragment
```

into the existing `ecai` application environment. The core fixture settings
are:

```erlang
{wikimedia_fixture_server_enabled, true},
{wikimedia_fixture_ip, {127, 0, 0, 1}},
{wikimedia_fixture_port, 9876},
{wikimedia_fixture_public_host, <<"127.0.0.1">>},
{wikimedia_fixture_runtime_dir,
    "/tmp/ecai-bdd-integration/wikimedia-fixture"},
{wikimedia_fixture_idle_timeout_ms, 60000},
{wikimedia_fixture_allow_non_loopback, false}
```

The fixture source directory defaults to:

```erlang
filename:join(code:priv_dir(ecai), "wikimedia-fixtures")
```

An explicit directory can be supplied for local experimentation:

```erlang
{wikimedia_fixture_dir, "/absolute/path/to/fixtures"}
```

Remote binding requires both values below:

```erlang
{wikimedia_fixture_ip, {0, 0, 0, 0}},
{wikimedia_fixture_allow_non_loopback, true}
```

The fixture service has no authentication and must not be exposed on a public
interface.

## Generated catalog

At startup, the worker:

1. finds compressed files matching the supported fixture naming contracts;
2. rejects missing content or pageview fixture sets;
3. rejects a directory containing mixed Cirrus release dates;
4. hashes each served file with SHA-256;
5. writes `wikimedia-catalog.json` through a synced temporary file and atomic
   rename;
6. compiles Cowboy routes for exactly those files.

The catalog path defaults to:

```text
/tmp/ecai-wikimedia-fixture/wikimedia-catalog.json
```

No caller-controlled path is passed to `file:open/2` by the HTTP handler.

## Endpoints

```text
GET|HEAD /healthz
GET|HEAD /_ecai/fixture/health
GET|HEAD /_ecai/fixture/status
GET|HEAD /wikimedia-catalog.json
GET|HEAD /pageviews-202606-user.bz2
GET|HEAD /enwiki_content-20260720-00000.json.bz2
```

The file endpoints support:

```text
ETag
If-None-Match
Range: bytes=...
If-Range
206 Partial Content
304 Not Modified
416 Range Not Satisfiable
```

Only the compressed files and generated catalog are served. The uncompressed
sidecars remain available in `priv` for inspection and fixture validation.

## Operator commands

```erlang
ecai_wikimedia_fixture_server:status().
ecai_wikimedia_fixture_server:base_url().
ecai_wikimedia_fixture_server:catalog_url().
ecai_wikimedia_fixture_server:catalog_path().
ecai_wikimedia_fixture_server:reload().
```

The same operations are exposed through the Wikimedia operator facade:

```erlang
ecai_wikimedia_ops:fixture_status().
ecai_wikimedia_ops:fixture_base_url().
ecai_wikimedia_ops:fixture_catalog_url().
ecai_wikimedia_ops:fixture_catalog_path().
ecai_wikimedia_ops:fixture_reload().
```

`ecai_wikimedia_ops:doctor/0` includes the fixture status.

A supervised `stop/0` is temporary because the permanent child will restart.
Disable the configuration and restart the ECAI application to turn the service
off.

## BDD execution

The single BDD runner no longer owns a Python process. For `fixture` and `ipfs`
it waits for the managed status endpoint, reads the generated local catalog
path, verifies the catalog URL, and injects the path into the feature.

```sh
export DAMAGEBDD_RUNNER_URL="http://127.0.0.1:4888"
export DAMAGEBDD_RUNNER_TOKEN="runner-access-token"
export ECAI_BASE_URL="http://127.0.0.1:9003"
export ECAI_ACCESS_TOKEN="ecai-api-access-token"

bash scripts/ecai-bdd/run_wikimedia_features.sh fixture
bash scripts/ecai-bdd/run_wikimedia_features.sh ipfs
```

Override the status URL when using another listener port:

```sh
export WIKIMEDIA_FIXTURE_STATUS_URL=\
"http://127.0.0.1:19876/_ecai/fixture/status"
```

## Tests

```sh
rebar3 as test compile

rebar3 eunit --module=ecai_wikimedia_fixture_handler_tests
rebar3 eunit --module=ecai_wikimedia_fixture_server_tests
rebar3 eunit --module=ecai_wikimedia_fixture_supervision_tests
rebar3 eunit --module=ecai_wikimedia_fixture_source_coherence_tests

rebar3 eunit --application=ecai
rebar3 xref
```

The tests cover range parsing, generated catalog content, full and partial file
retrieval, conditional requests, `HEAD`, unsupported methods, exact route
allowlisting, catalog reload, fail-closed source discovery, loopback policy,
permanent-child restart, and runtime export coherence.
