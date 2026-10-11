-module(ecai_mm_feed_tests).
-include_lib("eunit/include/eunit.hrl").

depth() -> #{<<"code">>=>0,
    <<"data">> => #{<<"a">>=>[[<<"0.0101">>,<<"1000">>,1]],
                    <<"b">>=>[[<<"0.0099">>,<<"1000">>,1]]}}.
ticker() -> #{<<"code">> => <<"0">>, <<"data">> => [
    #{<<"symbol">> => <<"damageusdt">>, <<"price">> => <<"0.01">>},
    #{<<"symbol">> => <<"btcusdt">>, <<"price">> => <<"95000">>}]}.

decode_test() ->
    ?assertMatch({ok, #{bid:=0.0099,ask:=0.0101}}, ecai_mm_feed:decode_depth(depth())),
    ?assertMatch({ok, #{btc_usdt:=95000.0}}, ecai_mm_feed:decode_prices(ticker())).

invalid_market_test() ->
    Bad = depth(),
    Data = maps:get(<<"data">>, Bad),
    Crossed = Bad#{<<"data">> => Data#{<<"a">> => [[<<"0.008">>,<<"1">>]]}},
    ?assertMatch({error, _}, ecai_mm_feed:decode_depth(Crossed)),
    ?assertMatch({error, _}, ecai_mm_feed:decode_prices(#{<<"code">>=>0,<<"data">>=>[]})).

adapter_test() ->
    Get = fun(Path) ->
       case lists:prefix("/v1/market/depth/", Path) of
           true -> {ok, depth()};
           false -> {ok, ticker()}
       end
    end,
    {ok, Snapshot} = ecai_mm_feed:fetch(Get),
    ?assertEqual(0.0099, maps:get(bid, Snapshot)),
    ?assertEqual(95000.0, maps:get(btc_usdt, Snapshot)),
    ?assertEqual(<<"coinstore">>, maps:get(source, Snapshot)).
