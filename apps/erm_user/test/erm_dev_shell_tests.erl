-module(erm_dev_shell_tests).
-include_lib("eunit/include/eunit.hrl").

%% Rebar executes the startup script before loading sys.config. A desktop
%% opt-out must therefore remain effective after later configuration changes.
damage_shell_blocks_legacy_desktop_after_config_reload_test() ->
    with_state(fun() ->
        run_damage_shell_script(),
        ?assertEqual(true, persistent_term:get({erm, damage_dev_shell})),
        ?assertEqual({ok, false}, application:get_env(erm, enabled)),
        %% Simulate the config reload which follows the script in Rebar.
        ok = application:set_env(erm, enabled, true),
        ok = application:set_env(erm, http_enabled, true),
        ok = application:set_env(erm, http_required, true),
        ?assertMatch({ok, {_, []}}, erm_sup:init([])),
        ?assertEqual(ok, erm_app:start_phase(start_trails_http, normal, []))
    end).

configured_desktop_opt_out_remains_supported_test() ->
    with_state(fun() ->
        persistent_term:erase({erm, damage_dev_shell}),
        ok = application:set_env(erm, enabled, false),
        ok = application:set_env(erm, http_enabled, true),
        ?assertMatch({ok, {_, []}}, erm_sup:init([])),
        ?assertEqual(ok, erm_app:start_phase(start_trails_http, normal, []))
    end).

run_damage_shell_script() ->
    {ok, Script} = escript:extract("apps/damage/scripts/dev_shell.escript", [compile_source]),
    Beam = proplists:get_value(source, Script),
    Module = proplists:get_value(module, beam_lib:info(Beam)),
    {module, Module} = code:load_binary(Module, "/test/damage_dev_shell", Beam),
    try Module:main([])
    after
        code:delete(Module),
        code:purge(Module)
    end.

with_state(Test) ->
    Env = [{Key, application:get_env(erm, Key)} || Key <- [enabled, http_enabled, http_required]],
    Keys = [{erm, damage_dev_shell}, {damage_reload, shell_root}],
    Markers = [{Key, persistent_term:get(Key, absent)} || Key <- Keys],
    try Test()
    after
        lists:foreach(fun restore_env/1, Env),
        lists:foreach(fun restore_marker/1, Markers)
    end.

restore_env({Key, undefined}) ->
    application:unset_env(erm, Key, [{persistent, true}]);
restore_env({Key, {ok, Value}}) ->
    application:set_env(erm, Key, Value, [{persistent, true}]).

restore_marker({Key, absent}) -> persistent_term:erase(Key);
restore_marker({Key, Value}) -> persistent_term:put(Key, Value).
