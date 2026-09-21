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

prepared_version_remains_authoritative_at_discovery_test() ->
    {ok, Expected} = damage_release_nft:prepared_installation(metadata()),
    ?assertEqual(version(), maps:get(packaged_release, Expected)),
    NewVersion = <<"1.4.3">>,
    ChangedRecord = (record())#{release := NewVersion},
    Meta = metadata(),
    ChangedMeta = Meta#{<<"release">> := NewVersion,
        <<"installation">> := (maps:get(<<"installation">>, Meta))#{<<"release">> := NewVersion}},
    %% NFT, final metadata, package CID and digest all agree with each other.
    %% Only the saved preparation proves they relabel the original package.
    {ok, Actual} = damage_release_nft:installation_fields(ChangedRecord, ChangedMeta),
    Mint = ChangedRecord#{contract_id => maps:get(nft, config())},
    Found = Actual#{contract_id => maps:get(nft, config())},
    ?assertEqual({error, prepared_release_version_mismatch},
        damage_release_nft:verify_publication(Mint, Expected, Found)).

missing_discovered_packaged_version_cannot_downgrade_binding_test() ->
    Lookup = lookup(),
    {ok, Found} = Lookup(latest, platform()),
    {ok, Expected} = damage_release_nft:prepared_installation(metadata()),
    Mint = (record())#{contract_id => maps:get(nft, config())},
    ?assertEqual(ok, damage_release_nft:verify_publication(Mint, Expected, Found)),
    ?assertEqual({error, {release_discovery_mismatch, [packaged_release]}},
        damage_release_nft:verify_publication(Mint, Expected,
            maps:remove(packaged_release, Found))),
    ?assertEqual({error, {release_discovery_mismatch, [packaged_release]}},
        damage_release_nft:verify_publication(Mint, Expected,
            Found#{packaged_release := <<"1.4.3">>})).

legacy_metadata_does_not_inherit_packaged_version_from_nft_test() ->
    LegacyMeta = damage_release_test_support:metadata(),
    LegacyRecord = damage_release_test_support:release_record(),
    {ok, Expected} = damage_release_nft:prepared_installation(LegacyMeta),
    {ok, Actual} = damage_release_nft:installation_fields(
        LegacyRecord#{packaged_release => maps:get(release, LegacyRecord)}, LegacyMeta),
    ?assertNot(maps:is_key(packaged_release, Expected)),
    ?assertNot(maps:is_key(packaged_release, Actual)),
    Mint = LegacyRecord#{contract_id => maps:get(nft, config())},
    Found = Actual#{contract_id => maps:get(nft, config())},
    ?assertEqual(ok, damage_release_nft:verify_publication(Mint, Expected, Found)).

invalid_installation_version_is_503_test_() ->
    [{lists:flatten(io_lib:format("invalid metadata release ~p (~p)", [BadVersion, Format])),
      fun() -> assert_invalid_installation_version_response(BadVersion, Format) end}
     || BadVersion <- [<<"bad/version">>, <<"latest">>, <<>>, 142,
                       binary:copy(<<"v">>, 161)],
        Format <- [<<"json">>, <<"install">>]].

assert_invalid_installation_version_response(BadVersion, Format) ->
    Meta = metadata(),
    I = maps:get(<<"installation">>, Meta),
    BadMeta = Meta#{<<"installation">> := I#{<<"release">> := BadVersion}},
    ?assertEqual({error, invalid_installation_release},
        damage_release_nft:installation_fields(record(), BadMeta)),
    Read = fun(R) -> damage_release_nft:installation_fields(R, BadMeta) end,
    Lookup = fun(latest, P) ->
        damage_release_nft:discover(latest, P, config(), query(), Read)
    end,
    {503, Headers, Body} = damage_releases_http:discovery_response(latest, undefined,
        [{<<"platform">>, platform()}, {<<"format">>, Format}], Lookup),
    ?assertEqual(<<"30">>, maps:get(<<"retry-after">>, Headers)),
    ?assertEqual(<<"application/json">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"release_unavailable">>},
        jsx:decode(Body, [return_maps])).

invalid_requested_version_is_still_400_test_() ->
    [?_test(begin
        %% The real selector validation runs before any configuration, chain
        %% query or IPFS read. No backend fixture or signing key is required.
        Lookup = fun({release, V}, P) -> damage_release_nft:release(V, P) end,
        {400, Headers, Body} = damage_releases_http:discovery_response(versioned, Version,
            [{<<"platform">>, platform()}, {<<"format">>, <<"install">>}], Lookup),
        ?assertNot(maps:is_key(<<"retry-after">>, Headers)),
        ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"invalid_release_request">>},
            jsx:decode(Body, [return_maps]))
    end) || Version <- [<<"bad/version">>, <<>>, <<"latest">>, binary:copy(<<"v">>, 161)]].

invalid_prepared_metadata_version_has_domain_error_test() ->
    ?assertEqual({error, invalid_installation_release},
        damage_release_nft:prepared_installation((metadata())#{<<"release">> := <<"bad/version">>})).
