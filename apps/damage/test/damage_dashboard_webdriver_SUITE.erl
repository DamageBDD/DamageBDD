%% Runs the exact DamageBDD step module with the real egherkin parser.
%% This local CI harness has no wallet/IPFS/step-spend side effects of its own.
-module(damage_dashboard_webdriver_SUITE).
-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    navigation/1,
    desktop/1,
    mobile/1,
    composer_fixture/1,
    composer_keyboard/1,
    live_auth/1,
    live_generation/1,
    live_billing/1,
    auth_fixture/1
]).

%% First-use provisioning has its own bounded deadline and can exceed a UI test.
suite() -> [{timetrap, {minutes, 35}}].
all() ->
    [
        navigation,
        desktop,
        mobile,
        composer_fixture,
        composer_keyboard,
        live_auth,
        live_generation,
        live_billing,
        auth_fixture
    ].

init_per_suite(Config) ->
    %% This harness must never change authorization/config in a production VM.
    case lists:keymember(damage, 1, application:which_applications()) of
        true -> ct:fail(do_not_run_webdriver_ct_inside_a_running_damage_application);
        false -> ok
    end,
    Keys = [webdriver_runtime, webdriver, webdriver_profiles, node_admins],
    Saved = [{K, application:get_env(damage, K)} || K <- Keys],
    try
        load_sys_config(ct:get_config(webdriver_sys_config)),
        case ct:get_config(webdriver_runtime) of
            undefined ->
                case application:get_env(damage, webdriver_runtime) of
                    {ok, Runtime0} ->
                        application:set_env(
                            damage, webdriver_runtime, fixture_script(Runtime0, Config)
                        );
                    undefined ->
                        ok
                end;
            Runtime ->
                application:set_env(
                    damage,
                    webdriver_runtime,
                    fixture_script(Runtime, Config)
                )
        end,
        Profile0 =
            case ct:get_config(webdriver_profile) of
                undefined ->
                    ct:get_config(webdriver, application:get_env(damage, webdriver, undefined));
                Name ->
                    case
                        proplists:lookup(Name, application:get_env(damage, webdriver_profiles, []))
                    of
                        {Name, Named} -> Named;
                        none -> error(unknown_webdriver_profile)
                    end
            end,
        case Profile0 of
            undefined ->
                restore(Saved),
                {skip, webdriver_profile_not_configured};
            _ ->
                configure(Profile0, Config, Saved)
        end
    catch
        _:_ ->
            restore(Saved),
            ct:fail(webdriver_suite_setup_failed_see_private_runtime_log)
    end.

configure(Profile0, Config, Saved) ->
    Profile = env_override(
        "DAMAGE_WEBDRIVER_URL",
        endpoint,
        env_override("DAMAGE_DASHBOARD_URL", dashboard_url, Profile0)
    ),
    Selected = ct:get_config(webdriver_suites, [
        navigation, desktop, composer_fixture, composer_keyboard
    ]),
    true = is_list(Selected) andalso Selected =/= [],
    true = lists:all(fun(N) -> lists:member(N, all()) end, Selected),
    Sup = start_runtime(Profile),
    try
        %% Validate the resolved profile, but keep the original for each session.
        %% Reusing a resolved endpoint would lose generation/race checks.
        {ok, Resolved} = damage_webdriver_runtime:resolve_profile(Profile),
        {ok, _} = damage_webdriver:options(Resolved),
        ok = application:set_env(damage, node_admins, [<<"local-dashboard-webdriver-test">>]),
        [
            {webdriver, Profile},
            {webdriver_suites, Selected},
            {owned_webdriver_sup, Sup},
            {saved_webdriver_env, Saved}
            | proplists:delete(webdriver, Config)
        ]
    catch
        Class:Reason:Stack ->
            stop_runtime(Sup),
            erlang:raise(Class, Reason, Stack)
    end.

load_sys_config(undefined) ->
    ok;
load_sys_config({priv, Name}) ->
    load_sys_config(filename:join(code:priv_dir(damage), Name));
load_sys_config(Path) ->
    {ok, [Apps]} = file:consult(Path),
    Damage = proplists:get_value(damage, Apps, []),
    %% Do not start other applications or import node secrets/authorization.
    lists:foreach(
        fun(K) ->
            case proplists:lookup(K, Damage) of
                none -> ok;
                {K, V} -> application:set_env(damage, K, V)
            end
        end,
        [webdriver_runtime, webdriver, webdriver_profiles]
    ).

fixture_script(Runtime, Config) ->
    Fixture = proplists:get_value(fixture, Runtime, []),
    case
        proplists:get_value(enabled, Fixture, false) andalso
            not proplists:is_defined(script, Fixture)
    of
        true ->
            DataDir = string:trim(
                filename:absname(proplists:get_value(data_dir, Config)), trailing, "/"
            ),
            Filename =
                case ct:get_config(webdriver_fixture, dashboard) of
                    dashboard -> "dashboard_webdriver_fixture.py";
                    auth -> "auth_webdriver_fixture.py";
                    _ -> error(invalid_webdriver_fixture)
                end,
            Script = filename:join([filename:dirname(DataDir), "scripts", Filename]),
            [{fixture, [{script, Script} | Fixture]} | proplists:delete(fixture, Runtime)];
        false ->
            Runtime
    end.

start_runtime(Profile) ->
    case
        proplists:is_defined(managed, Profile) orelse
            proplists:get_value(managed_fixture, Profile, false)
    of
        false ->
            undefined;
        true ->
            undefined = whereis(damage_webdriver_sup),
            lists:foreach(
                fun(App) -> {ok, _} = application:ensure_all_started(App) end,
                [ssl, inets, erlexec]
            ),
            {ok, Pid} = damage_webdriver_sup:start_link(),
            unlink(Pid),
            Pid
    end.

stop_runtime(undefined) ->
    ok;
stop_runtime(Pid) ->
    try
        gen_server:stop(Pid, shutdown, 45000)
    catch
        exit:noproc -> ok
    end.
restore(Saved) ->
    lists:foreach(
        fun
            ({K, {ok, V}}) -> application:set_env(damage, K, V);
            ({K, undefined}) -> application:unset_env(damage, K)
        end,
        Saved
    ),
    ok.

end_per_suite(Config) ->
    try
        stop_runtime(proplists:get_value(owned_webdriver_sup, Config))
    after
        restore(proplists:get_value(saved_webdriver_env, Config, []))
    end,
    ok.
init_per_testcase(Name, Config) ->
    Selected = proplists:get_value(webdriver_suites, Config, [
        navigation, desktop, composer_fixture, composer_keyboard
    ]),
    P = proplists:get_value(webdriver, Config),
    Fixture = proplists:get_value(fixture, P, false),
    case lists:member(Name, Selected) of
        false ->
            {skip, {not_selected, Name}};
        true ->
            case {Name, Fixture} of
                {auth_fixture, false} -> ct:fail(fixture_suite_rejected_for_live_profile);
                {composer_keyboard, false} -> ct:fail(fixture_suite_rejected_for_live_profile);
                {composer_fixture, false} -> ct:fail(fixture_suite_rejected_for_live_profile);
                {live_auth, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                {live_generation, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                {live_billing, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                _ -> Config
            end
    end.

auth_fixture(C) -> run("auth_fixture.feature", C).
navigation(C) -> run("navigation.feature", C).
desktop(C) -> run("desktop.feature", C).
mobile(C) -> run("mobile.feature", C).
composer_keyboard(C) -> run("composer_keyboard.feature", C).
composer_fixture(C) -> run("composer_fixture.feature", C).
live_auth(C) -> run("live_auth.feature", C).
live_generation(C) -> run("live_generation.feature", C).
live_billing(C) -> run("live_billing.feature", C).

run(Name, Config) ->
    Path = filename:join(proplists:get_value(data_dir, Config), Name),
    {ok, Source} = file:read_file(Path),
    AST =
        case egherkin:parse(Source) of
            {ok, A} -> A;
            A -> A
        end,
    {_Line, _Tags, _Feature, _Description, Background, Scenarios} = AST,
    true = is_list(Scenarios) andalso Scenarios =/= [],
    Errors = lists:flatmap(
        fun(Scenario) -> run_scenario(Scenario, Background, Config) end, Scenarios
    ),
    case Errors of
        [] -> ok;
        _ -> ct:fail({dashboard_scenarios_failed, Errors})
    end.

run_scenario({_Line, Title, _Tags, Steps}, Background, Config) ->
    %% Worker ownership ensures sessions are also reclaimed if CT timetraps a test.
    Parent = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        ParentMonitor = erlang:monitor(process, Parent),
        %% Linked guardian kills this worker when its Common Test parent disappears.
        Worker = self(),
        Guardian = spawn_link(fun() ->
            R = erlang:monitor(process, Parent),
            receive
                {'DOWN', R, process, Parent, _} -> exit(Worker, kill);
                done -> ok
            end
        end),
        Context = #{public_key => <<"local-dashboard-webdriver-test">>},
        Result =
            try
                Final = run_steps(background(Background) ++ Steps, Config, Context),
                Cleanup = steps_webdriver:cleanup(Final),
                case {maps:find(fail, Final), Cleanup} of
                    {error, ok} -> ok;
                    {{ok, Reason}, _} -> {error, Reason};
                    {_, Other} -> {error, Other}
                end
            after
                steps_webdriver:cleanup_owner()
            end,
        Guardian ! done,
        erlang:demonitor(ParentMonitor, [flush]),
        Parent ! {Tag, Result}
    end),
    receive
        {Tag, ok} ->
            erlang:demonitor(Monitor, [flush]),
            ct:pal("PASS ~ts", [Title]),
            [];
        {Tag, {error, Why}} ->
            erlang:demonitor(Monitor, [flush]),
            ct:pal("FAIL ~ts: ~p", [Title, Why]),
            [{Title, Why}];
        {'DOWN', Monitor, process, Pid, _} ->
            %% Never log raw exception terms; a driver error could contain user text.
            [{Title, scenario_worker_failed}]
    end;
run_scenario(_, _, _) ->
    [{invalid_scenario, unsupported_gherkin_ast}].

background(undefined) -> [];
background([]) -> [];
background({_Line, Steps}) when is_list(Steps) -> Steps;
background(_) -> error(unsupported_background_ast).
run_steps([], _Config, C) ->
    C;
run_steps(_, _Config, #{fail := _} = C) ->
    C;
run_steps([Step | Rest], Config, C) ->
    try unpack(Step) of
        {Line, Keyword, Text, Body} ->
            %% There are intentionally no runtime template variables in these files.
            Parts = damage_step_tokenizer:tokenize(Text),
            try steps_webdriver:step(Config, C, Keyword, Line, Parts, Body) of
                C1 when is_map(C1) -> run_steps(Rest, Config, C1)
            catch
                error:function_clause -> C#{fail => {undefined_webdriver_step, Line}};
                _:_ -> C#{fail => {webdriver_step_failed, Line}}
            end
    catch
        _:_ -> C#{fail => unsupported_step_ast}
    end.
unpack({Line, Keyword, Body}) ->
    {Text, Args} = body(Body),
    {Line, Keyword, Text, Args};
unpack({Line, Keyword, Text, Args}) ->
    {T, _} = body(Text),
    {Line, Keyword, T, Args}.
body(B) when is_binary(B) -> {B, <<>>};
body(Parts) when is_list(Parts) ->
    Text = iolist_to_binary(lists:join(<<" ">>, [B || B <- Parts, is_binary(B)])),
    Doc =
        case [Lines || {<<"\"\"\"">>, Lines} <- Parts] of
            [] -> <<>>;
            [Lines] -> iolist_to_binary(lists:join(<<"\n">>, Lines))
        end,
    {Text, Doc}.
env_override(Name, Key, P) ->
    case os:getenv(Name) of
        false -> P;
        Value -> [{Key, unicode:characters_to_binary(Value)} | proplists:delete(Key, P)]
    end.
