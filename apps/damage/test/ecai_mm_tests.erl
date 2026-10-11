-module(ecai_mm_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test data is synthetic fixture data — production charts never fabricate ticks.
paper_engine_restart_test() ->
    Dir = filename:join(["/tmp", "ecai-mm-eunit-" ++
        integer_to_list(erlang:unique_integer([positive]))]),
    Cfg = #{state_dir => Dir, auto_poll => false,
        paper_balances => #{damage => 10000.0, usdt => 300.0}},
    {ok, _} = ecai_mm:start_link(Cfg),
    try
        ?assertEqual(paper, maps:get(mode, ecai_mm:status())),
        Book = #{bid => 0.0099, ask => 0.0101, btc_usdt => 95000.0},
        ok = ecai_mm:ingest(Book),
        One = ecai_mm:status(),
        ?assert(length(maps:get(quotes, One)) > 0),
        ?assertEqual(1, maps:get(events, One)),
        [First] = ecai_mm:history(10),
        ?assertEqual(100.0, maps:get(damage_index, First)),
        Q = hd(maps:get(quotes, One)),
        {ok, _} = ecai_mm:paper_fill(maps:get(client_id,Q), 1.0),
        ?assertEqual(2, maps:get(events, ecai_mm:status())),
        ?assertEqual(ok, ecai_mm:verify_audit())
    after gen_server:stop(ecai_mm) end,
    {ok, _} = ecai_mm:start_link(Cfg),
    try
        ?assertEqual(2, maps:get(events, ecai_mm:status())),
        ?assertEqual(ok, ecai_mm:verify_audit()),
        ?assertEqual(2, length(ecai_mm:history(10))),
        ?assertEqual(ok, ecai_mm:verify_audit()),
        ?assertEqual(1, maps:get(fill_count, maps:get(performance, ecai_mm:status())))
    after gen_server:stop(ecai_mm) end.

live_execution_is_disabled_test() ->
    ?assertMatch({error, live_execution_not_implemented},
       ecai_mm:start_link(#{mode => live})).
