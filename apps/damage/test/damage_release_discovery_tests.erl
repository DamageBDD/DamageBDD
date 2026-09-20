%% Tests the actual discovery orchestration and HTTP response path with explicit
%% chain/metadata callbacks. No live network, account secret or mint is used.
-module(damage_release_discovery_tests).
-include_lib("eunit/include/eunit.hrl").

platform() -> <<"ubuntu-noble-amd64">>.
version() -> <<"1.4.2">>.
sha() -> binary:copy(<<"1">>, 40).
config() ->
    #{network => <<"ae_mainnet">>,
      nft => aeser_api_encoder:encode(contract_pubkey, <<1:256>>),
      reader => aeser_api_encoder:encode(account_pubkey, <<2:256>>),
      gateway => <<"https://ipfs.example.test/ipfs">>, timeout => 2000}.
record() ->
    (damage_release_test_support:release_record())#{release := version(), git_sha := sha()}.
metadata() ->
    Meta = damage_release_test_support:metadata(),
    I = maps:get(<<"installation">>, Meta),
    Meta#{<<"release">> => version(), <<"platform">> => platform(), <<"git_sha">> := sha(),
        <<"installation">> := I#{<<"release">> => version()}}.
answer() ->
    R = record(),
    damage_release_nft:release_answer(maps:get(token_id, R), version(), platform(), sha(),
        maps:get(metadata_cid, R), maps:get(asset_cid, R)).
query() ->
    fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        %% Real wrapper shape: decoded string keys + raw node binary keys.
        damage_release_nft:call_return(#{
            "return_type" => "ok", "return_value" => damage_release_test_support:some(answer()),
            <<"return_type">> => <<"ok">>, <<"return_value">> => <<"cb_opaque">>})
    end.
read_installation(R) ->
    ?assertEqual(record(), R),
    damage_release_nft:installation_fields(R, metadata()).
lookup() ->
    fun(latest, Platform) -> damage_release_nft:discover(latest, Platform, config(),
        query(), fun read_installation/1) end.

installer_request_returns_exact_snapshot_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    {200, Headers, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}, {<<"format">>, <<"install">>}], lookup()),
    {ok, Installed} = damage_release_nft:parse_install_manifest(Body),
    ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, Headers)),
    ?assertEqual(record(), maps:with(maps:keys(record()), Installed)),
    ?assertEqual(maps:get(nft, config()), maps:get(contract_id, Installed)),
    ?assertEqual(<<"ae_mainnet">>, maps:get(network_id, Installed)),
    ?assertEqual(<<"damage.deb">>, maps:get(asset_path, Installed)),
    ?assertEqual(damage_release_test_support:digest(), maps:get(sha256, Installed)).

json_request_returns_exact_package_url_test() ->
    {200, _, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}], lookup()),
    Json = jsx:decode(Body, [return_maps]),
    Cid = damage_release_test_support:cid(),
    ?assertEqual(<<"https://ipfs.example.test/ipfs/", Cid/binary, "/damage.deb">>,
        maps:get(<<"asset_url">>, Json)),
    ?assertEqual(platform(), maps:get(<<"platform">>, Json)),
    ?assertEqual(version(), maps:get(<<"release">>, Json)),
    ?assertEqual(sha(), maps:get(<<"git_sha">>, Json)),
    ?assertEqual(true, maps:get(<<"ok">>, Json)).

missing_platform_never_queries_global_latest_test() ->
    Query = fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        {ok, none}
    end,
    Read = fun(_) -> error(metadata_must_not_be_read) end,
    Lookup = fun(latest, P) -> damage_release_nft:discover(latest, P, config(), Query, Read) end,
    {404, _, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}, {<<"format">>, <<"install">>}], Lookup),
    ?assertEqual(<<"release_not_found">>, maps:get(<<"error">>, jsx:decode(Body, [return_maps]))).

wrong_platform_does_not_reach_metadata_test() ->
    R = record(),
    Wrong = damage_release_nft:release_answer(42, version(), <<"archlinux-x86_64">>, sha(),
        maps:get(metadata_cid, R), maps:get(asset_cid, R)),
    Query = fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        {ok, damage_release_test_support:some(Wrong)}
    end,
    ?assertEqual({error, release_platform_mismatch}, damage_release_nft:discover(
        latest, platform(), config(), Query, fun(_) -> error(must_not_read_metadata) end)).

missing_installation_is_not_a_fallback_test() ->
    Read = fun(R) -> damage_release_nft:installation_fields(R, #{}) end,
    Lookup = fun(latest, P) -> damage_release_nft:discover(latest, P, config(), query(), Read) end,
    {422, _, _} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}], Lookup).

latest_pointer_is_resolved_once_test() ->
    Ref = make_ref(),
    put(Ref, 0),
    Query = fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        Count = get(Ref), put(Ref, Count + 1),
        ?assertEqual(0, Count),
        {ok, damage_release_test_support:some(answer())}
    end,
    try
        {ok, _} = damage_release_nft:discover(latest, platform(), config(), Query,
            fun read_installation/1),
        ?assertEqual(1, get(Ref))
    after erase(Ref) end.

verify_complete_minted_identity_test() ->
    Lookup = lookup(),
    {ok, Found} = Lookup(latest, platform()),
    Mint = (record())#{contract_id => maps:get(nft, config()), network_id => <<"ae_mainnet">>},
    {ok, Expected} = damage_release_nft:prepared_installation(metadata()),
    ?assertEqual(ok, damage_release_nft:verify_publication(Mint, Expected, Found)),
    lists:foreach(fun({Key, Value}) ->
        ?assertEqual({error, {release_discovery_mismatch, [Key]}},
            damage_release_nft:verify_publication(Mint, Expected, Found#{Key := Value}))
    end, [{token_id, 43}, {contract_id, <<"ct_other">>}, {network_id, <<"ae_uat">>},
        {release, <<"older">>}, {platform, <<"archlinux-x86_64">>}, {git_sha, <<>>},
        {metadata_cid, <<"other">>}, {asset_cid, <<"other">>}, {asset_path, <<"other.deb">>},
        {sha256, binary:copy(<<"b">>, 64)}, {package_format, <<"rpm">>},
        {architecture, <<"arm64">>}]),
    ?assertEqual({error, incomplete_publication_identity},
        damage_release_nft:verify_publication(Mint, #{}, Found)).

packaged_version_is_bound_to_nft_test() ->
    Meta = metadata(),
    I = maps:get(<<"installation">>, Meta),
    ?assertMatch({ok, _}, damage_release_nft:installation_fields(record(), Meta)),
    ?assertEqual({error, release_version_mismatch}, damage_release_nft:installation_fields(
        (record())#{release := <<"install-CID-is-not-a-version">>}, Meta)),
    ?assertEqual({error, release_version_mismatch}, damage_release_nft:installation_fields(
        record(), Meta#{<<"installation">> := I#{<<"release">> := <<"different">>}})),
    ?assertEqual({error, release_package_format_mismatch}, damage_release_nft:installation_fields(
        record(), Meta#{<<"installation">> := I#{<<"package_format">> := <<"rpm">>}})).

backend_crash_is_503_not_invalid_request_test() ->
    {503, Headers, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}], fun(_, _) -> error(backend_failure) end),
    ?assertEqual(<<"30">>, maps:get(<<"retry-after">>, Headers)),
    ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"release_unavailable">>},
        jsx:decode(Body, [return_maps])).

invalid_request_does_not_invoke_backend_test() ->
    {400, _, _} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"format">>, <<"install">>}], fun(_, _) -> error(must_not_be_called) end).

configuration_preflight_is_read_only_test() ->
    C = config(),
    Settings = [{ae_network_id, maps:get(network, C)},
        {build_release_nft_contract, maps:get(nft, C)},
        {build_release_reader_account, maps:get(reader, C)},
        {build_release_ipfs_gateway, maps:get(gateway, C)},
        {build_release_query_timeout, maps:get(timeout, C)}],
    Saved = [{K, application:get_env(damage, K)} || {K, _} <- Settings],
    try
        lists:foreach(fun({K,V}) -> application:set_env(damage, K, V) end, Settings),
        ?assertEqual({ok, C}, damage_release_nft:discovery_config()),
        Parts = ["the build release discovery is configured"],
        Result = steps_release_nft:step([], #{keep => true}, <<"Given">>, 1, Parts, <<>>),
        ?assertEqual(C, maps:get(build_release_discovery_config, Result)),
        ?assertEqual(maps:get(nft, C), maps:get(build_release_nft_contract, Result)),
        Other = aeser_api_encoder:encode(contract_pubkey, <<3:256>>),
        Mismatch = steps_release_nft:step([], #{build_release_nft_contract => Other},
            <<"Given">>, 1, Parts, <<>>),
        ?assert(maps:is_key(fail, Mismatch)),
        application:unset_env(damage, build_release_nft_contract),
        ?assertEqual({error, {missing_release_config, build_release_nft_contract}},
            damage_release_nft:discovery_config())
    after
        lists:foreach(fun
            ({K, undefined}) -> application:unset_env(damage, K);
            ({K, {ok,V}}) -> application:set_env(damage, K, V)
        end, Saved)
    end.

arch_target_uses_its_own_package_test() ->
    Platform = <<"archlinux-x86_64">>,
    R = (record())#{platform := Platform},
    Meta0 = metadata(),
    Install0 = maps:get(<<"installation">>, Meta0),
    Meta = Meta0#{<<"platform">> := Platform, <<"installation">> := Install0#{
        <<"platform">> := Platform, <<"architecture">> := <<"x86_64">>,
        <<"package_format">> := <<"pkg.tar.zst">>, <<"asset_path">> := <<"damage.pkg.tar.zst">>}},
    Answer = damage_release_nft:release_answer(42, version(), Platform, sha(),
        maps:get(metadata_cid, R), maps:get(asset_cid, R)),
    Query = fun("latest_release_value_for", ["archlinux-x86_64"]) ->
        {ok, damage_release_test_support:some(Answer)}
    end,
    Read = fun(Actual) ->
        ?assertEqual(R, Actual), damage_release_nft:installation_fields(Actual, Meta)
    end,
    Lookup = fun(latest, P) -> damage_release_nft:discover(latest, P, config(), Query, Read) end,
    {200, _, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, Platform}, {<<"format">>, <<"install">>}], Lookup),
    {ok, Installed} = damage_release_nft:parse_install_manifest(Body),
    ?assertEqual(Platform, maps:get(platform, Installed)),
    ?assertEqual(<<"damage.pkg.tar.zst">>, maps:get(asset_path, Installed)).
