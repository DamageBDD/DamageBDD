%% Runs the exact DamageBDD step module with the real egherkin parser.
%% This local CI harness has no wallet/IPFS/step-spend side effects of its own.
-module(damage_dashboard_webdriver_SUITE).
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, navigation/1, desktop/1, mobile/1, composer_fixture/1, composer_keyboard/1,
    live_auth/1, live_generation/1, live_billing/1]).

suite() -> [{timetrap, {minutes, 12}}].
all() -> [navigation, desktop, mobile, composer_fixture, composer_keyboard, live_auth, live_generation, live_billing].

init_per_suite(Config) ->
    case ct:get_config(webdriver) of
        undefined -> {skip, webdriver_profile_not_configured};
        Profile0 -> configure(Profile0, Config)
    end.

configure(Profile0, Config) ->
    %% Run in a dedicated CT VM, never against a running production BEAM.
    case lists:keymember(damage, 1, application:which_applications()) of
        true -> ct:fail(do_not_run_webdriver_ct_inside_a_running_damage_application);
        false -> ok
    end,
    Profile = env_override("DAMAGE_WEBDRIVER_URL", endpoint,
        env_override("DAMAGE_DASHBOARD_URL", dashboard_url, Profile0)),
    case damage_webdriver:options(Profile) of
        {ok, _} -> ok;
        _ -> ct:fail(missing_or_invalid_webdriver_profile)
    end,
    Selected = ct:get_config(webdriver_suites, [navigation, desktop, composer_fixture, composer_keyboard]),
    true = is_list(Selected) andalso Selected =/= [],
    true = lists:all(fun(N) -> lists:member(N, all()) end, Selected),
    %% This only authorizes local test-step dispatch. The browser still logs in
    %% to the target node as the separate test account with its actual permissions.
    OldAdmins = application:get_env(damage, node_admins),
    ok = application:set_env(damage, node_admins, [<<"local-dashboard-webdriver-test">>]),
    [{webdriver, Profile}, {webdriver_suites, Selected}, {old_node_admins, OldAdmins} |
        proplists:delete(webdriver, Config)].
end_per_suite(Config) ->
    case proplists:get_value(old_node_admins, Config) of
        {ok, V} -> application:set_env(damage, node_admins, V);
        _ -> application:unset_env(damage, node_admins)
    end,
    ok.
init_per_testcase(Name, Config) ->
    Selected = proplists:get_value(webdriver_suites, Config, [navigation, desktop, composer_fixture, composer_keyboard]),
    P = proplists:get_value(webdriver, Config),
    Fixture = proplists:get_value(fixture, P, false),
    case lists:member(Name, Selected) of
        false -> {skip, {not_selected, Name}};
        true ->
            case {Name, Fixture} of
                {composer_keyboard, false} -> ct:fail(fixture_suite_rejected_for_live_profile);
                {composer_fixture, false} -> ct:fail(fixture_suite_rejected_for_live_profile);
                {live_auth, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                {live_generation, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                {live_billing, true} -> ct:fail(live_suite_rejected_for_fixture_profile);
                _ -> Config
            end
    end.

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
    AST = case egherkin:parse(Source) of {ok, A} -> A; A -> A end,
    {_Line, _Tags, _Feature, _Description, Background, Scenarios} = AST,
    true = is_list(Scenarios) andalso Scenarios =/= [],
    Errors = lists:flatmap(fun(Scenario) -> run_scenario(Scenario, Background, Config) end, Scenarios),
    case Errors of [] -> ok; _ -> ct:fail({dashboard_scenarios_failed, Errors}) end.

run_scenario({_Line, Title, _Tags, Steps}, Background, Config) ->
    %% Worker ownership ensures sessions are also reclaimed if CT timetraps a test.
    Parent = self(), Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        ParentMonitor = erlang:monitor(process, Parent),
        %% Linked guardian kills this worker when its Common Test parent disappears.
        Worker = self(),
        Guardian = spawn_link(fun() ->
            R = erlang:monitor(process, Parent),
            receive {'DOWN', R, process, Parent, _} -> exit(Worker, kill);
                done -> ok end
        end),
        Context = #{public_key => <<"local-dashboard-webdriver-test">>},
        Final = run_steps(background(Background) ++ Steps, Config, Context),
        Cleanup = steps_webdriver:cleanup(Final),
        Result = case {maps:find(fail, Final), Cleanup} of
            {error, ok} -> ok;
            {{ok, Reason}, _} -> {error, Reason};
            {_, Other} -> {error, Other}
        end,
        Guardian ! done,
        erlang:demonitor(ParentMonitor, [flush]),
        Parent ! {Tag, Result}
    end),
    receive
        {Tag, ok} ->
            erlang:demonitor(Monitor, [flush]),
            ct:pal("PASS ~ts", [Title]), [];
        {Tag, {error, Why}} ->
            erlang:demonitor(Monitor, [flush]),
            ct:pal("FAIL ~ts: ~p", [Title, Why]), [{Title, Why}];
        {'DOWN', Monitor, process, Pid, _} ->
            %% Never log raw exception terms; a driver error could contain user text.
            [{Title, scenario_worker_failed}]
    end;
run_scenario(_, _, _) -> [{invalid_scenario, unsupported_gherkin_ast}].

background(undefined) -> [];
background([]) -> [];
background({_Line, Steps}) when is_list(Steps) -> Steps;
background(_) -> error(unsupported_background_ast).
run_steps([], _Config, C) -> C;
run_steps(_, _Config, #{fail := _} = C) -> C;
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
    catch _:_ -> C#{fail => unsupported_step_ast}
    end.
unpack({Line, Keyword, Body}) ->
    {Text, Args} = body(Body), {Line, Keyword, Text, Args};
unpack({Line, Keyword, Text, Args}) ->
    {T, _} = body(Text), {Line, Keyword, T, Args}.
body(B) when is_binary(B) -> {B, <<>>};
body(Parts) when is_list(Parts) ->
    Text = iolist_to_binary(lists:join(<<" ">>, [B || B <- Parts, is_binary(B)])),
    Doc = case [Lines || {<<"\"\"\"">>, Lines} <- Parts] of
        [] -> <<>>;
        [Lines] -> iolist_to_binary(lists:join(<<"\n">>, Lines))
    end,
    {Text, Doc}.
env_override(Name, Key, P) ->
    case os:getenv(Name) of
        false -> P;
        Value -> [{Key, unicode:characters_to_binary(Value)} | proplists:delete(Key, P)]
    end.
