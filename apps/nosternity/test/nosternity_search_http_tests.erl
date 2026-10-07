-module(nosternity_search_http_tests).
-include_lib("eunit/include/eunit.hrl").

missing_operator_token_fails_closed_test() ->
    ?assertEqual({error, auth_not_configured}, nosternity_search_http:authorize(<<"Bearer abc">>, false)),
    ?assertEqual({error, auth_not_configured}, nosternity_search_http:authorize(<<"Bearer abc">>, [])),
    ?assertEqual({error, auth_not_configured}, nosternity_search_http:authorize(<<"Bearer ">>, <<>>)).

bearer_token_test() ->
    Token = <<"operator-only-token">>,
    ?assertEqual(ok, nosternity_search_http:authorize(<<"Bearer operator-only-token">>, Token)),
    ?assertEqual(ok, nosternity_search_http:authorize(<<"Bearer operator-only-token">>, binary_to_list(Token))),
    ?assertEqual({error, unauthorized}, nosternity_search_http:authorize(<<"Bearer operator-only-tokem">>, Token)),
    ?assertEqual({error, unauthorized}, nosternity_search_http:authorize(<<"Basic operator-only-token">>, Token)),
    ?assertEqual({error, unauthorized}, nosternity_search_http:authorize(undefined, Token)).

get_search_bounds_test() ->
    ?assertEqual({ok, [#{<<"search">> => <<"bitcoin">>, <<"limit">> => 50}]},
        nosternity_search_http:query_filters([{<<"q">>, <<"bitcoin">>}])),
    lists:foreach(fun(Pairs) ->
        ?assertEqual({error, invalid_query}, nosternity_search_http:query_filters(Pairs))
    end, [
        [], [{<<"q">>, <<>>}], [{<<"q">>, <<"   ">>}],
        [{<<"q">>, <<255>>}],
        [{<<"q">>, <<"x">>}, {<<"q">>, <<"y">>}],
        [{<<"q">>, <<"x">>}, {<<"limit">>, <<"0">>}],
        [{<<"q">>, <<"x">>}, {<<"limit">>, <<"201">>}],
        [{<<"q">>, <<"x">>}, {<<"url">>, <<"http://untrusted">>}]
    ]).

json_input_bounds_test() ->
    ?assertEqual({ok, #{<<"unknown_key_927465">> => <<"x">>}},
        nosternity_search_http:decode_body(<<"{\"unknown_key_927465\":\"x\"}">>)),
    ?assertEqual({error, invalid_json_object}, nosternity_search_http:decode_body(<<"[]">>)),
    ?assertEqual({error, invalid_json}, nosternity_search_http:decode_body(<<"{broken">>)),
    ?assertEqual({error, body_too_large}, nosternity_search_http:decode_body(binary:copy(<<"x">>, 65537))).

wire_event_only_test() ->
    Event = #{id => <<"id">>, pubkey => <<"pub">>, created_at => 1,
        kind => 1, tags => [], content => <<"text">>, sig => <<"sig">>, internal => secret},
    #{results := [#{event := Wire, score := 1.25}], total := 1} =
        nosternity_search_http:search_json(#{results => [#{event => Event, score => 1.25}], total => 1}),
    ?assertEqual(<<"id">>, maps:get(<<"id">>, Wire)),
    ?assertNot(maps:is_key(<<"internal">>, Wire)),
    ?assert(lists:all(fun is_binary/1, maps:keys(Wire))).
