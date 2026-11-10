#!/bin/sh
# Isolated verification: never boots Damage or the desktop application.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
cd "$root"
if [ -z "${JSX_EBIN:-}" ]; then
    JSX_EBIN=$(erl -noshell -eval 'case code:lib_dir(jsx,ebin) of {error,_}->halt(1); P->io:format("~s",[P]),halt() end.') || {
        echo 'Set JSX_EBIN to a compiled jsx/ebin directory (from the normal Rebar build).' >&2
        exit 1
    }
fi
[ -d "$JSX_EBIN" ] || { echo 'JSX_EBIN is not a directory' >&2; exit 1; }
build=$(mktemp -d)
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
mkdir "$build/prod" "$build/test"
erlc -Werror -o "$build/prod" apps/damage/src/damage_erm_bridge.erl \
    apps/damage/src/damage_sup.erl apps/erm/src/erm_sup.erl apps/erm/src/erm_app.erl \
    apps/erm_user/src/*.erl
erl -pa "$build/prod" -noshell -eval '
    {module,damage_erm_bridge}=code:ensure_loaded(damage_erm_bridge),
    false=erlang:function_exported(damage_erm_bridge,serve,2),
    {module,erm_user_bridge}=code:ensure_loaded(erm_user_bridge),
    false=erlang:function_exported(erm_user_bridge,exchange,3),halt().'
erlc -Werror -DTEST -o "$build/test" apps/damage/src/damage_erm_bridge.erl \
    apps/damage/test/damage_erm_bridge_tests.erl \
    apps/erm/src/erm_sup.erl apps/erm/src/erm_app.erl \
    apps/erm_user/src/*.erl apps/erm_user/test/*.erl
erl -pa "$build/test" -pa "$JSX_EBIN" -noshell -eval '
    case eunit:test([damage_erm_bridge_tests,erm_user_bridge_tests,erm_dev_shell_tests],[verbose]) of
        ok -> halt(0); _ -> halt(1) end.'
python3 apps/damage/test/scripts/erm_bridge_grant.test.py -v
python3 apps/erm/packaging/userspace/test_packaging.py -v
python3 apps/erm_user/test/native_profile_tests.py -v
