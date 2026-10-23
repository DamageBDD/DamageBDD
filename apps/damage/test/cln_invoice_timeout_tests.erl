-module(cln_invoice_timeout_tests).
-include_lib("eunit/include/eunit.hrl").

all_invoice_wrappers_use_bounded_calls_test_() ->
    [?_test(with_pool_mock(0, [], fun() ->
        Result = Invoke(),
        ?assertMatch({create_invoice, 1000, <<"fixture">>, _, _, {_, #{}}}, Result),
        {create_invoice, _, _, _, _, {Deadline, Options}} = Result,
        ?assertEqual(5000, maps:get(connect_timeout, Options)),
        ?assertEqual(10000, maps:get(timeout, Options)),
        ?assertEqual(65536, maps:get(max_response_bytes, Options)),
        ?assertEqual(0, maps:get(retry, Options)),
        ?assert(Deadline > erlang:monotonic_time(millisecond)),
        ?assertEqual(1, meck:num_calls(poolboy, transaction, 3))
    end)) || Invoke <- [
        fun() -> cln:create_invoice(1000, "fixture") end,
        fun() -> cln:create_invoice(1000, <<"fixture">>, 600) end,
        fun() -> cln:create_invoice(1000, "fixture", "label") end,
        fun() -> cln:create_invoice(1000, <<"fixture">>, 600, <<"label">>) end
    ]].

reply_after_old_five_second_limit_test_() ->
    {timeout, 10, fun() ->
        with_pool_mock(5200, [], fun() ->
            ?assertMatch(
                {create_invoice, 1000, _, 600, <<"label">>, _},
                cln:create_invoice(1000, <<"fixture">>, 600, <<"label">>)
            )
        end)
    end}.

configured_timeouts_are_snapshotted_test() ->
    with_pool_mock(0, [
        {cln_invoice_connect_timeout_ms, 200},
        {cln_invoice_http_timeout_ms, 700},
        {cln_invoice_checkout_timeout_ms, 123}
    ], fun() ->
        {create_invoice, _, _, _, _, {_, Options}} =
            cln:create_invoice(1000, <<"fixture">>, 600, <<"label">>),
        ?assertEqual(200, maps:get(connect_timeout, Options)),
        ?assertEqual(700, maps:get(timeout, Options))
    end).

invalid_timeouts_fall_back_test() ->
    with_pool_mock(0, [
        {cln_invoice_connect_timeout_ms, infinity},
        {cln_invoice_http_timeout_ms, -1},
        {cln_invoice_checkout_timeout_ms, 60001}
    ], fun() ->
        {create_invoice, _, _, _, _, {_, Options}} =
            cln:create_invoice(1000, <<"fixture">>, 600, <<"label">>),
        ?assertEqual(5000, maps:get(connect_timeout, Options)),
        ?assertEqual(10000, maps:get(timeout, Options))
    end).

expired_queue_deadline_never_sends_http_test() ->
    with_transport_mock(fun(_, _, _, _, _, _) -> error(must_not_send) end, fun() ->
        ?assertEqual(
            {error, {cln_unavailable, invoice_deadline_expired}},
            post_invoice(erlang:monotonic_time(millisecond) - 1)
        ),
        ?assertEqual(0, meck:num_calls(damage_gun, post, 6))
    end).

remaining_deadline_caps_transport_budgets_test() ->
    {ok, Options} = cln:invoice_request_options(
        erlang:monotonic_time(millisecond) + 5000, invoice_options()
    ),
    Connect = maps:get(connect_timeout, Options),
    Http = maps:get(timeout, Options),
    ?assert(Connect > 0),
    ?assert(Http > 0),
    ?assert(Connect + Http =< 5000).

http_failures_are_normalized_test_() ->
    Cases = [
        {{ok, #{status => 200, json => #{bolt11 => <<"lnbc1fixture">>}}},
            #{bolt11 => <<"lnbc1fixture">>}},
        {{ok, #{status => 503, json => #{message => <<"backend-secret-fixture">>}}},
            {error, {cln_http_status, 503}}},
        {{ok, #{status => 401, json => #{}}}, {error, {cln_http_status, 401}}},
        {{error, #{body => <<"backend-secret-fixture">>, error => {invalid_json, badarg}}},
            {error, invalid_cln_json}},
        {{error, response_timeout}, {error, {cln_http_failed, response_timeout}}},
        {unexpected_reply, {error, invalid_cln_response}}
    ],
    [?_test(with_transport_mock(fun(_, _, _, _, _, _) -> Reply end, fun() ->
        ?assertEqual(Expected, post_invoice(erlang:monotonic_time(millisecond) + 15000)),
        ?assertEqual(1, meck:num_calls(damage_gun, post, 6))
    end)) || {Reply, Expected} <- Cases].

invoice_transport_options_test() ->
    Owner = self(),
    Ref = make_ref(),
    with_transport_mock(fun(Host, Port, Path, Headers, Body, Options) ->
        Owner ! {Ref, Host, Port, Path, Headers, Body, Options},
        {ok, #{status => 200, json => #{}}}
    end, fun() ->
        ?assertEqual(#{}, post_invoice(erlang:monotonic_time(millisecond) + 15000)),
        receive
            {Ref, "localhost", 3010, "/v1/invoice", Headers, Body, Options} ->
                ?assertEqual(<<"fixture-rune">>, proplists:get_value(<<"Rune">>, Headers)),
                ?assertEqual(#{<<"amount_msat">> => 1000}, jsx:decode(Body, [return_maps])),
                ?assertEqual(65536, maps:get(max_response_bytes, Options)),
                ?assertEqual(json, maps:get(decode, Options)),
                ?assertEqual(true, maps:get(close, Options)),
                ?assertEqual(0, maps:get(retry, Options)),
                ?assertEqual(none, maps:get(proxy, Options))
        after 1000 -> error(missing_transport_call)
        end
    end).

post_invoice(Deadline) ->
    cln:cln_invoice_post_json(
        "localhost", 3010, #{}, <<"fixture-rune">>, #{amount_msat => 1000},
        Deadline, invoice_options()
    ).

invoice_options() ->
    #{connect_timeout => 5000, timeout => 10000, max_response_bytes => 65536, retry => 0}.

with_transport_mock(Post, Test) ->
    ok = meck:new(damage_gun, [no_link]),
    try
        ok = meck:expect(damage_gun, post, Post),
        Test(),
        ?assert(meck:validate(damage_gun))
    after
        meck:unload(damage_gun)
    end.

with_pool_mock(Delay, Overrides, Test) ->
    Keys = [cln_invoice_connect_timeout_ms, cln_invoice_http_timeout_ms,
            cln_invoice_checkout_timeout_ms],
    Saved = [{Key, application:get_env(damage, Key)} || Key <- Keys],
    [application:unset_env(damage, Key) || Key <- Keys],
    [application:set_env(damage, Key, Value) || {Key, Value} <- Overrides],
    ConfiguredCheckout = application:get_env(damage, cln_invoice_checkout_timeout_ms, 1000),
    ExpectedCheckout = case ConfiguredCheckout of
        N when is_integer(N), N > 0, N =< 60000 -> N;
        _ -> 1000
    end,
    Worker = spawn(fun() -> fake_worker(Delay) end),
    Mods = [poolboy, datestring],
    ok = meck:new(Mods, [no_link]),
    try
        ok = meck:expect(datestring, format, fun(_, _) -> {ok, "20261021000000"} end),
        ok = meck:expect(poolboy, transaction, fun(cln, Fun, Timeout) ->
            %% This still exercises a real gen_server:call to the fixture PID.
            ?assertEqual(ExpectedCheckout, Timeout),
            Fun(Worker)
        end),
        Test(),
        [?assert(meck:validate(Mod)) || Mod <- Mods],
        ok
    after
        exit(Worker, kill),
        meck:unload(Mods),
        [restore_env(Key, Value) || {Key, Value} <- Saved]
    end.

fake_worker(Delay) ->
    receive
        {'$gen_call', From, Request} ->
            timer:sleep(Delay),
            gen_server:reply(From, Request),
            fake_worker(Delay)
    end.

restore_env(Key, {ok, Value}) -> application:set_env(damage, Key, Value);
restore_env(Key, undefined) -> application:unset_env(damage, Key).
