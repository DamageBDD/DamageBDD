# ECAI OTP-managed Wikimedia fixtures

This package moves the deterministic Wikimedia BDD fixture listener into the
ECAI OTP application.

It adds:

- `ecai_wikimedia_fixture_server`, a permanent supervisor child;
- a loopback-only Cowboy listener with exact route allowlisting;
- generated pinned Wikimedia catalogs;
- ETag, conditional request, `HEAD`, and single-range support;
- fixture files under the ECAI `priv` tree;
- operator status, URL, catalog, and reload functions;
- fixture lifecycle, HTTP, restart, and coherence EUnit tests;
- an updated BDD runner that no longer spawns Python.

## Apply

From the DamageBDD repository root:

```sh
git apply --check /path/to/ecai_wikimedia_fixture_otp.patch
git apply /path/to/ecai_wikimedia_fixture_otp.patch
```

The patch is based on the Wikimedia pipeline versions of `ecai_app.erl`,
`ecai_wikimedia_ops.erl`, and the single BDD runner. When local edits make the
patch inapplicable, copy the new fixture modules/tests/priv files and merge the
small `ecai_app` and operator-facade changes manually.

## Configure

Merge:

```text
config/ecai-bdd/ecai_bdd_integration.config.fragment
```

into the existing `ecai` application environment.

## Test

```sh
rebar3 as test compile
rebar3 eunit --module=ecai_wikimedia_fixture_handler_tests
rebar3 eunit --module=ecai_wikimedia_fixture_server_tests
rebar3 eunit --module=ecai_wikimedia_fixture_supervision_tests
rebar3 eunit --module=ecai_wikimedia_fixture_source_coherence_tests
rebar3 eunit --application=ecai
rebar3 xref
```

## Run BDD fixture feature

```sh
export DAMAGEBDD_RUNNER_URL="http://127.0.0.1:4888"
export DAMAGEBDD_RUNNER_TOKEN="runner-access-token"
export ECAI_BASE_URL="http://127.0.0.1:9003"
export ECAI_ACCESS_TOKEN="ecai-api-access-token"

bash scripts/ecai-bdd/run_wikimedia_features.sh fixture
```

Detailed operations and endpoint documentation:

```text
docs/ecai/OTP_MANAGED_WIKIMEDIA_FIXTURES.md
```
