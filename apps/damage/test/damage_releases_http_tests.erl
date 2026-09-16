-module(damage_releases_http_tests).
-include_lib("eunit/include/eunit.hrl").

query_test() ->
    ?assertEqual({ok, <<>>, json}, damage_releases_http:query_params([])),
    ?assertEqual(
        {ok, <<"ubuntu-noble-amd64">>, install},
        damage_releases_http:query_params([
            {<<"platform">>, <<"ubuntu-noble-amd64">>}, {<<"format">>, <<"install">>}
        ])
    ),
    ?assertMatch({error, _}, damage_releases_http:query_params([{<<"format">>, <<"install">>}])).

invalid_query_test_() ->
    [
        ?_assertMatch({error, _}, damage_releases_http:query_params(Pairs))
     || Pairs <- [
            [{<<"platform">>, <<"one">>}, {<<"platform">>, <<"two">>}],
            [{<<"format">>, <<"json">>}, {<<"format">>, <<"json">>}],
            [{<<"contract">>, <<"ct_untrusted">>}],
            [{<<"platform">>, true}],
            [{<<"format">>, <<"shell">>}],
            [{<<"platform">>, <<"../etc/passwd">>}]
        ]
    ].

status_test() ->
    {404, _, _} = damage_releases_http:response({error, not_found}, json),
    {400, _, _} = damage_releases_http:response({error, invalid_platform}, json),
    {503, Headers, Body} = damage_releases_http:response(
        {error, {missing_release_config, build_release_index_contract}}, install
    ),
    ?assertEqual(<<"30">>, maps:get(<<"retry-after">>, Headers)),
    ?assertEqual(nomatch, binary:match(Body, <<"build_release_index_contract">>)).
