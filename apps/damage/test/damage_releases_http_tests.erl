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
        {error, {missing_release_config, build_release_nft_contract}}, install
    ),
    ?assertEqual(<<"30">>, maps:get(<<"retry-after">>, Headers)),
    ?assertEqual(nomatch, binary:match(Body, <<"build_release_nft_contract">>)).


install_response_test() ->
    Release = damage_release_test_support:installed_release(),
    {200, Headers, Body} = damage_releases_http:response({ok, Release}, install),
    ?assertEqual(<<"text/plain; charset=utf-8">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, Headers)),
    ?assertEqual(damage_release_nft:install_manifest(Release), Body).

json_response_test() ->
    Release = damage_release_test_support:installed_release(),
    {200, _, Body} = damage_releases_http:response({ok, Release}, json),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(true, maps:get(<<"ok">>, Decoded)),
    ?assertEqual(2, maps:get(<<"schema_version">>, Decoded)),
    ?assertNot(maps:is_key(<<"index_contract_id">>, Decoded)).

missing_manifest_test() ->
    {422, _, Body} = damage_releases_http:response(
        {error, installation_manifest_missing}, install),
    ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"installation_manifest_missing">>},
        jsx:decode(Body, [return_maps])).
