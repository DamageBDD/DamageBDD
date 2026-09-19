#!/bin/sh
# Compile selected files and run in a fresh VM, never on an operator node.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
command -v erlc >/dev/null 2>&1 || { echo 'Erlang erlc is required.' >&2; exit 127; }
command -v erl >/dev/null 2>&1 || { echo 'Erlang erl is required.' >&2; exit 127; }
# Ignore ambient project code paths, config/boot arguments, and compiler flags.
unset ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_LIBS ERL_COMPILER_OPTIONS
BUILD=$(mktemp -d)
BUILD=$(CDPATH= cd -- "$BUILD" && pwd)
trap 'rm -rf "$BUILD"' 0
trap 'exit 1' HUP INT TERM
cd "$ROOT"
erlc -DTEST +warnings_as_errors -o "$BUILD" \
    apps/damage/src/damage_release_overrides.erl \
    apps/damage/src/damage_hotcode.erl \
    apps/damage/test/damage_hotcode_generation_tests.erl
# Do not use the repository as the VM's current directory/code path.
cd "$BUILD"
erl -boot start_clean -noshell -noinput -pa "$BUILD" -eval '
    try
        undefined = application:get_all_key(damage),
        undefined = whereis(damage_sup),
        {ok, _} = application:ensure_all_started(crypto),
        [] = damage_hotcode_generation_tests:generation_identity_test_(),
        ok = application:set_env(damage_hotcode_generation_tests, isolated_node, true),
        Tests = {inorder, Cases} = damage_hotcode_generation_tests:generation_identity_test_(),
        true = (is_list(Cases) andalso Cases =/= []),
        io:format("Running ~B isolated hot-code generations cases.~n", [length(Cases)]),
        case eunit:test({"isolated hot-code generations", Tests}, [verbose]) of
            ok -> halt(0);
            _ -> halt(1)
        end
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "Isolated hot-code test runner failed: ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.'
