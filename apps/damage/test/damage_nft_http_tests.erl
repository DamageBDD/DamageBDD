-module(damage_nft_http_tests).
-include_lib("eunit/include/eunit.hrl").
legacy_nft_not_installable_test() ->
    {422, _, Body} = damage_releases_http:response({error, installation_manifest_missing}, json),
    ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"installation_manifest_missing">>},
        jsx:decode(Body, [return_maps])).
