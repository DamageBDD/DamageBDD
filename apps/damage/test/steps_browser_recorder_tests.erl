%% Local socket fixtures exercise the real managed-client protocol, not Selenium.
-module(steps_browser_recorder_tests).
-include_lib("eunit/include/eunit.hrl").
-define(ELEMENT, <<"element-6066-11e4-a52e-4f735466cecf">>).
-define(OWNER, <<"recorder-unit-admin">>).

profile(Endpoint) ->
    [{endpoint, Endpoint}, {dashboard_url, <<"https://example.test">>},
     {wait_ms, 300}, {command_timeout_ms, 1000}, {session_start_timeout_ms, 2000},
     {capabilities, [{browserName, <<"chrome">>}]}].

run(Context, Parts) -> run(Context, Parts, <<>>).
run(Context, Parts, Body) ->
    steps_browser_recorder:step([], Context, <<"When">>, 1, Parts, Body).

start(Endpoint) ->
    steps_browser_recorder:step(
        [{webdriver, profile(Endpoint)}], #{public_key => ?OWNER}, <<"Given">>, 1,
        ["I start a recorded browser at", "https://example.test/signup"], <<>>).

runtime_guard_denies_unprivileged_replay_test() ->
    with_admin(fun() ->
        [begin
            Context = #{public_key => <<"not-admin">>},
            ?assertMatch(#{fail := _}, run(Context, Parts)),
            ?assertMatch(#{fail := _}, steps_browser_recorder:step_dry(
                [], Context, <<"Given">>, 1, Parts, <<>>))
        end || Parts <- vocabulary()],
        %% A feature-supplied roles field does not grant permission.
        ?assertMatch(#{fail := _}, run(#{roles => [node_admin]},
            ["I start a recorded browser at", "https://example.test"]))
    end).

recorder_is_discovered_once_and_role_filtered_test() ->
    with_admin(fun() ->
        ?assertEqual(1, length([M || M <- damage_utils:loaded_steps(), M =:= steps_browser_recorder])),
        ?assert(steps_utils:step_module_allowed(steps_browser_recorder, #{public_key => ?OWNER})),
        ?assertNot(steps_utils:step_module_allowed(steps_browser_recorder, #{}))
    end).

dry_run_has_no_browser_and_preserves_metering_test() ->
    with_admin(fun() ->
        C = #{public_key => ?OWNER},
        [begin
            Result = steps_browser_recorder:step_dry([], C, <<"When">>, 1, Parts, <<>>),
            ?assertNot(maps:is_key(fail, Result)),
            ?assertNot(maps:is_key(webdriver_session, Result)),
            ?assert(maps:is_key(step_spend, Result))
        end || Parts <- vocabulary()],
        ?assertEqual(undefined, get({steps_webdriver, session}))
    end).

unrelated_steps_are_not_swallowed_test() ->
    ?assertError(function_clause,
        steps_browser_recorder:step([], #{}, <<"When">>, 1, ["Unrelated step"], <<>>)),
    ?assertError(function_clause,
        steps_browser_recorder:step_dry([], #{}, <<"When">>, 1, ["Unrelated step"], <<>>)).

navigation_validation_test() ->
    [begin
        ?assertEqual({error, invalid_browser_url}, damage_webdriver:navigation_url(URL))
    end || URL <- [
        <<"javascript:alert(1)">>, <<"file:///etc/passwd">>, <<"about:blank">>,
        <<"https://user:password@example.test/">>, <<"https://example.test:0/">>,
        <<"https://example.test/a\nb">>, <<"https://example.test:65536/">>, <<>>
    ]],
    URL = <<"https://example.test/path?q=a%20b#/screen">>,
    ?assertEqual({ok, URL}, damage_webdriver:navigation_url(URL)).

invalid_start_does_not_open_a_session_test() ->
    with_admin(fun() ->
        C = run(#{public_key => ?OWNER}, ["I start a recorded browser at", "file:///private"]),
        ?assertMatch(#{fail := _}, C),
        ?assertNot(maps:is_key(webdriver_session, C)),
        ?assertEqual(undefined, get({steps_webdriver, session}))
    end).

recorded_vocabulary_uses_native_session_and_cleanup_test() ->
    with_admin(fun() ->
        with_server(fun normal/3, fun(URL) ->
            C0 = start(URL),
            ?assertNot(maps:is_key(fail, C0)),
            Pid = maps:get(webdriver_session, C0),
            ?assert(is_pid(Pid)),
            ?assertNot(maps:is_key(browser_recorder_session, C0)),
            C1 = run(C0, ["I type into recorded field", "#name"], <<"Alice\nSmith">>),
            C2 = run(C1, ["I select recorded option in", "#plan"], <<"pro">>),
            C3 = run(C2, ["I set recorded checkbox", "#terms", "to checked"]),
            C4 = run(C3, ["I set recorded checkbox", "#terms", "to checked"]),
            C5 = run(C4, ["I set recorded checkbox", "#terms", "to unchecked"]),
            C6 = run(C5, ["I press Enter in recorded field", "#name"]),
            C7 = run(C6, ["I click recorded element", "#submit"]),
            C8 = run(C7, ["recorded element", "#message", "should contain text"], <<"Success">>),
            C9 = run(C8, ["the recorded browser URL should start with", "https://example.test/signup"]),
            C10 = run(C9, ["I navigate the recorded browser to", "https://example.test/done"]),
            ?assertNot(maps:is_key(fail, C10)),
            Closed = run(C10, ["I close the recorded browser"]),
            ?assertNot(maps:is_key(webdriver_session, Closed)),
            ?assertNot(maps:is_key(fail, Closed)),
            ?assertEqual(undefined, get({steps_webdriver, session})),
            Requests = drain_requests([]),
            ?assertEqual(2, length([ok || {<<"POST">>, P, _} <- Requests,
                binary:match(P, <<"/element/terms/click">>) =/= nomatch])),
            ?assertEqual(1, length([ok || {<<"DELETE">>, _, _} <- Requests])),
            ?assert(lists:any(fun({M, P, Payload}) ->
                M =:= <<"POST">> andalso binary:match(P, <<"/element/name/value">>) =/= nomatch
                    andalso maps:get(<<"text">>, Payload, undefined) =:= <<"Alice\nSmith">>
            end, Requests))
        end)
    end).

empty_select_value_is_replayed_test() ->
    with_admin(fun() ->
        with_server(fun normal/3, fun(URL) ->
            C = run(start(URL), ["I select recorded option in", "#plan"], <<>>),
            ?assertNot(maps:is_key(fail, C)),
            _ = run(C, ["I close the recorded browser"]),
            ?assert(lists:any(fun({M, P, _}) ->
                M =:= <<"POST">> andalso binary:match(P, <<"/element/empty/click">>) =/= nomatch
            end, drain_requests([])))
        end)
    end).

text_assertion_failure_closes_session_test() ->
    with_admin(fun() ->
        with_server(fun normal/3, fun(URL) ->
            Failed = run(start(URL), ["recorded element", "#message", "should contain text"], <<"Missing">>),
            ?assertMatch(#{fail := _}, Failed),
            ?assertNot(maps:is_key(webdriver_session, Failed)),
            ?assertEqual(1, length([ok || {<<"DELETE">>, _, _} <- drain_requests([])]))
        end)
    end).

scenario_cleanup_handles_skipped_explicit_close_test() ->
    with_admin(fun() ->
        with_server(fun normal/3, fun(URL) ->
            C = start(URL),
            %% The same cleanup entrypoints used by damage:execute_steps/3.
            ?assertEqual(ok, steps_webdriver:cleanup(C#{fail => <<"A later HTTP step failed">>})),
            ?assertEqual(ok, steps_webdriver:cleanup_owner()),
            ?assertEqual(1, length([ok || {<<"DELETE">>, _, _} <- drain_requests([])]))
        end)
    end).

remote_error_text_is_redacted_test() ->
    with_admin(fun() ->
        Handler = fun(Method, Path, Json) ->
            case {Method, binary:match(Path, <<"/click">>)} of
                {<<"POST">>, {_, _}} -> {500, #{<<"error">> => <<"SENTINEL_SECRET">>, <<"message">> => <<"SENTINEL_SECRET">>}};
                _ -> normal(Method, Path, Json)
            end
        end,
        with_server(Handler, fun(URL) ->
            Failed = run(start(URL), ["I click recorded element", "#submit"]),
            ?assertMatch(#{fail := _}, Failed),
            ?assertEqual(nomatch, binary:match(term_to_binary(Failed), <<"SENTINEL_SECRET">>)),
            ?assertNot(maps:is_key(webdriver_session, Failed))
        end)
    end).

fixture_feature_matches_catalog_test() ->
    {ok, {steps_browser_recorder, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(steps_browser_recorder), [abstract_code]),
    Entries = damage_bdd_catalog:from_forms(<<"steps_browser_recorder">>, <<"test">>, Forms),
    Catalog = #{revision => <<"test">>, steps => Entries},
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    File = filename:join([filename:dirname(Source), "steps_browser_recorder_tests_data", "vocabulary.feature"]),
    {ok, Text} = file:read_file(File),
    Result = damage_bdd_validator:validate(Text, Catalog),
    ?assertEqual({true, []}, {maps:get(valid, Result), maps:get(diagnostics, Result)}).

vocabulary() ->
    [["I start a recorded browser at", "https://example.test"],
     ["I navigate the recorded browser to", "https://example.test/next"],
     ["I click recorded element", "#submit"],
     ["I type into recorded field", "#name"],
     ["I type secret", "browser_secret_test", "into recorded field", "#password"],
     ["I select recorded option in", "#plan"],
     ["I set recorded checkbox", "#terms", "to checked"],
     ["I set recorded checkbox", "#terms", "to unchecked"],
     ["I press Enter in recorded field", "#name"],
     ["recorded element", "#message", "should contain text"],
     ["the recorded browser URL should start with", "https://example.test"],
     ["I close the recorded browser"]].

with_admin(Fun) ->
    Previous = application:get_env(damage, node_admins),
    application:set_env(damage, node_admins, [?OWNER]),
    try Fun()
    after
        _ = steps_webdriver:cleanup_owner(),
        case Previous of
            {ok, Value} -> application:set_env(damage, node_admins, Value);
            undefined -> application:unset_env(damage, node_admins)
        end
    end.

%% Each fixture listens on loopback and an ephemeral port. Request logging is
%% test-only and uses synthetic inputs; production code never records bodies.
with_server(Handler, Test) ->
    {ok, _} = application:ensure_all_started(inets),
    _ = drain_requests([]),
    Parent = self(),
    Wrapped = fun(M, P, J) -> Parent ! {recorder_wire, M, P, J}, Handler(M, P, J) end,
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Pid = spawn_link(fun() -> accept_loop(Listen, Wrapped) end),
    URL = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/wd/hub"]),
    try Test(URL)
    after
        _ = steps_webdriver:cleanup_owner(),
        gen_tcp:close(Listen),
        unlink(Pid),
        exit(Pid, shutdown),
        _ = drain_requests([])
    end.

accept_loop(Listen, Handler) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            try serve(Socket, Handler) after gen_tcp:close(Socket) end,
            accept_loop(Listen, Handler);
        {error, closed} -> ok
    end.
serve(Socket, Handler) ->
    {Head, Rest} = read_header(Socket, <<>>),
    [First | _] = binary:split(Head, <<"\r\n">>, [global]),
    [Method, Path, _] = binary:split(First, <<" ">>, [global]),
    Length = case re:run(Head, <<"(?i)content-length:\\s*([0-9]+)">>, [{capture, [1], binary}]) of
        {match, [N]} -> binary_to_integer(N);
        nomatch -> 0
    end,
    Body = read_body(Socket, Rest, Length),
    Json = case Body of <<>> -> #{}; _ -> jsx:decode(Body, [return_maps]) end,
    {Status, Value} = Handler(Method, Path, Json),
    Raw = jsx:encode(#{<<"value">> => Value}),
    ok = gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_list(Status), " Test\r\n",
        "Content-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        integer_to_list(byte_size(Raw)), "\r\n\r\n", Raw]).
read_header(Socket, Bytes) ->
    case binary:split(Bytes, <<"\r\n\r\n">>) of
        [Head, Rest] -> {Head, Rest};
        [_] when byte_size(Bytes) < 65536 ->
            {ok, More} = gen_tcp:recv(Socket, 0, 2000),
            read_header(Socket, <<Bytes/binary, More/binary>>)
    end.
read_body(_Socket, Bytes, Length) when byte_size(Bytes) >= Length -> binary:part(Bytes, 0, Length);
read_body(Socket, Bytes, Length) ->
    {ok, More} = gen_tcp:recv(Socket, Length - byte_size(Bytes), 2000),
    <<Bytes/binary, More/binary>>.

drain_requests(Acc) ->
    receive {recorder_wire, M, P, J} -> drain_requests([{M, P, J} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

normal(<<"POST">>, <<"/wd/hub/session">>, _) ->
    {200, #{<<"sessionId">> => <<"recorder-test">>, <<"capabilities">> => #{}}};
normal(M, <<"/wd/hub/session/recorder-test", Path/binary>>, J) ->
    normal_session(M, Path, J).
normal_session(<<"POST">>, <<"/url">>, #{<<"url">> := URL}) -> put(url, URL), {200, null};
normal_session(<<"GET">>, <<"/url">>, _) -> {200, get(url)};
normal_session(<<"POST">>, <<"/execute/sync">>, #{<<"script">> := Script}) ->
    case binary:match(Script, <<"e.innerText">>) of
        nomatch -> {200, true};
        _ -> {200, <<"Success">>}
    end;
normal_session(<<"POST">>, <<"/elements">>, #{<<"value">> := <<"#", Id/binary>>}) ->
    {200, [#{?ELEMENT => Id}]};
normal_session(<<"GET">>, <<"/element/plan/name">>, _) -> {200, <<"select">>};
normal_session(<<"GET">>, <<"/element/plan/property/multiple">>, _) -> {200, false};
normal_session(<<"POST">>, <<"/element/plan/elements">>, _) ->
    {200, [#{?ELEMENT => <<"empty">>}, #{?ELEMENT => <<"pro">>}]};
normal_session(<<"GET">>, <<"/element/empty/property/value">>, _) -> {200, <<>>};
normal_session(<<"GET">>, <<"/element/pro/property/value">>, _) -> {200, <<"pro">>};
normal_session(<<"GET">>, <<"/element/terms/property/type">>, _) -> {200, <<"checkbox">>};
normal_session(M, <<"/element/", Tail/binary>>, _) ->
    case {M, binary:split(Tail, <<"/">>)} of
        {<<"POST">>, [Id, <<"click">>]} ->
            put({selected, Id}, get({selected, Id}) =/= true), {200, null};
        {<<"GET">>, [Id, <<"selected">>]} -> {200, get({selected, Id}) =:= true};
        _ -> {200, null}
    end;
normal_session(_, _, _) -> {200, null}.
