# EUnit production-module isolation

## Failure reviewed

The reported run contains five `ecai_live_disk_search_tests` cases, three failing
at `ecai_ollama_rag:retrieve_sources_lexical/3` with `undef`.

In the supplied source plus the complete-source retrieval patch, the production
`apps/ecai/src/ecai_ollama_rag.erl` already exports and implements that function.
However, the supplied source also contains this standalone chat-test replacement:

```erlang
%% Previously: apps/ecai/test/personalities/chat/ecai_ollama_rag.erl
-module(ecai_ollama_rag).
-export([retrieve_sources/3]).
retrieve_sources(_, _, _) -> [].
```

A VM resolving that test module instead of the production module has precisely
the missing export in the reported stack trace. Rebar3 compiles application test
sources; module selection follows the Erlang code path. The source-level collision
is verified here. The exact loaded BEAM path on the operator's machine has not
been observed, so stale production BEAMs remain another possibility until the
new module-resolution test is run.

Other auto-discoverable standalone doubles in the supplied ECAI tree reuse
`ecai`, `ecai_chat`, `ecai_personalities`, `damage_gun`, `damage_cln`, `damage_auth`,
`cowboy_req`, `poolboy`, and `trails`. Changing just the missing RAG export would
leave those collisions in place. An empty lexical-search stub would conceal
retrieval failures rather than exercise the real indexer.

## Change

All 14 Erlang sources belonging exclusively to these three isolated harnesses
now use the existing repository convention `.erl.fixture`:

- `apps/ecai/test/personalities/chat/`
- `apps/ecai/test/personalities/cln/`
- `apps/ecai/test/conversation_personalities/`

This includes each harness's private test driver as well as its production-name
doubles: moving only the doubles would leave tests requiring those doubles in
the ordinary EUnit run. Fixture contents are unchanged.

Each existing `run.sh` copies its fixtures to a unique temporary `src/` directory,
restores `.erl` names there, and compiles into that private output directory.
The existing exit trap cleans it up. Script entry-point paths are unchanged.
The math-dashboard harness already follows this convention and is not changed.

Two regression checks are added:

* `test_eunit_fixture_isolation.py` rejects duplicate auto-compiled ECAI module
  declarations and known dependency doubles. It also tests shell staging and
  cleanup on success, compiler failure, and VM failure with explicit fake tools.
* `ecai_test_module_isolation_tests.erl` checks the loaded RAG, chat, and personality
  modules' exports and compilation origins. Its errors include the resolved BEAM
  path, compiled source, and missing exports. It does not hot-load replacements,
  purge modules, suppress failures, start applications, or call external services.

No production source, search test assertion, index format, posting data, source
blob, funding behavior, or NFT behavior is changed by this follow-up patch.

## Apply and rebuild the test profile

Apply the follow-up patch to the checkout where the complete-source retrieval
patch is already installed. Do not merely extract renamed fixtures over the old
`.erl` files; the old names must be removed too. `git apply` performs the renames.

Run from the DamageBDD repository root:

```bash
(
    set -eu
    PATCH="$HOME/Downloads/ecai-eunit-module-shadowing-fix.patch"
    test -f apps/ecai/src/ecai_ollama_rag.erl
    git apply --check "$PATCH"
    git apply "$PATCH"

    # Preserve the old generated test profile, including any stale fixture beams.
    # No source files or index directories are deleted by this command.
    if [ -d _build/test ]; then
        BACKUP="$(mktemp -d "$PWD/_build/test-before-fixture-isolation.XXXXXXXX")"
        mv -- _build/test "$BACKUP/test"
        printf 'Previous test profile preserved at %s/test\n' "$BACKUP"
    fi

    rebar3 eunit --module=ecai_test_module_isolation_tests,ecai_live_disk_search_tests
)
```

Moving the old profile aside prevents obsolete fixture BEAMs or copied test
sources from surviving a source rename. Rebuilding may recompile test-profile
dependencies and native artifacts. The old profile is retained for inspection
or restoration; this procedure does not modify a running production release.

Then run the adjacent retrieval suites:

```bash
rebar3 eunit --module=ecai_source_retrieval_tests,ecai_source_search_tests,ecai_wikimedia_content_tests,ecai_compute_settings_tests
python3 apps/ecai/test/test_eunit_fixture_isolation.py -v
```

The isolated personality tests remain separate, explicit executions:

```bash
JSX_EBIN="$PWD/_build/test/lib/jsx/ebin" \
    bash apps/ecai/test/personalities/chat/run.sh
bash apps/ecai/test/personalities/cln/run.sh
ECAI_JSX_EBIN="$PWD/_build/test/lib/jsx/ebin" \
    bash apps/ecai/test/conversation_personalities/run.sh
```

These scripts run real EUnit when the actual Erlang tools are installed. Their
HTTP, model, payment, and entitlement boundaries are intentional local doubles;
they are not live-provider or live-payment integration tests.

## Diagnostics without changing code loading

Inside the failing test VM, the following queries identify the loaded module:

```erlang
code:which(ecai_ollama_rag).
code:ensure_loaded(ecai_ollama_rag).
ecai_ollama_rag:module_info(compile).
ecai_ollama_rag:module_info(exports).
erlang:function_exported(ecai_ollama_rag, retrieve_sources_lexical, 3).
```

The production compilation source should end in `apps/ecai/src/ecai_ollama_rag.erl`;
the lexical export must be present. The new EUnit gate performs these checks in
the test code path, rather than relying on a shell with different path ordering.
A fresh test profile plus a continuing gate failure indicates another stale or
duplicate module in the umbrella/dependencies, outside the ECAI subtree reviewed.

## Validation boundary

Local validation covers source layout, byte-identical fixture staging, shell
cleanup, unchanged production sources, existing Python retrieval contracts, and
patch application to the supplied baseline. The shell tests deliberately use
fake `erl`/`erlc` executables; they do not validate Erlang syntax or runtime behavior.

Erlang/erlc/rebar3 are unavailable in the authoring environment. Native compilation,
the three new EUnit module-resolution cases, the five original live-disk cases,
and the standalone native personality suites were NOT executed here. The
operator's failing VM was not accessed. See the accompanying validation report
for executed checks and before/after source-collision evidence.

## External references

- Rebar3 EUnit compilation and test selection: https://rebar3.org/docs/testing/eunit/
- Erlang code-path lookup, loading and `code:which/1`: https://www.erlang.org/doc/apps/kernel/code.html
