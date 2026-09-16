-module(damage_release_nft_tests).
-include_lib("eunit/include/eunit.hrl").

-import(damage_release_test_support, [cid/0, digest/0, answer/0,
    release_record/0, metadata/0, installed_release/0, some/1, token_metadata/0]).

manifest(Path, Digest) ->
    A = answer(),
    <<A/binary, "|", Path/binary, "|", Digest/binary>>.

release_decode_test() ->
    {ok, R} = damage_release_nft:parse_release(answer()),
    ?assertEqual(42, maps:get(token_id, R)),
    ?assertEqual(<<"ubuntu-noble-amd64">>, maps:get(platform, R)),
    ?assertEqual(<<>>, maps:get(git_sha, R)).

manifest_decode_test() ->
    {ok, R} = damage_release_nft:parse_manifest(manifest(<<"damage.deb">>, digest())),
    ?assertEqual(<<"damage.deb">>, maps:get(asset_path, R)),
    ?assertEqual(digest(), maps:get(sha256, R)).

%% An infrastructure exception (for example a missing shared IPFS API)
%% must NOT satisfy a validation test merely by returning {error, _}.
invalid_manifest_test_() ->
    [
        ?_assertEqual({error, Reason}, damage_release_nft:parse_manifest(M))
     || {M, Reason} <- [
            {<<>>, invalid_release_manifest},
            {<<"bogus">>, invalid_release_manifest},
            {binary:copy(<<"a">>, 4097), invalid_release_manifest},
            {manifest(<<"../damage.deb">>, digest()), invalid_asset_path},
            {manifest(<<"/tmp/file.deb">>, digest()), invalid_asset_path},
            {manifest(<<"dir//file.deb">>, digest()), invalid_asset_path},
            {manifest(<<"dir/%2e%2e/file.deb">>, digest()), invalid_asset_path},
            {manifest(<<"dir/./file.deb">>, digest()), invalid_asset_path},
            {manifest(<<"$(id)">>, digest()), invalid_asset_path},
            {manifest(<<"damage.deb">>, <<>>), invalid_package_sha256},
            {manifest(<<"damage.deb">>, binary:copy(<<"g">>, 64)), invalid_package_sha256},
            {<<(manifest(<<"damage.deb">>, digest()))/binary, "\n">>, invalid_package_sha256}
        ]
    ].

option_decode_test() ->
    ?assertEqual(none, damage_release_nft:option_value({variant, [0, 1], 0, {}})),
    ?assertEqual({ok, answer()}, damage_release_nft:option_value({variant, [0, 1], 1, {answer()}})),
    ?assertMatch({error, _}, damage_release_nft:option_value({variant, [1, 0], 1, {answer()}})).

%% Existing NFT getters, not the removed companion decode_snapshot API.
latest_platform_test() ->
    Query = fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        {ok, some(answer())}
    end,
    ?assertEqual({ok, release_record()}, damage_release_nft:select_release(
        latest, <<"ubuntu-noble-amd64">>, Query)).

latest_global_test() ->
    Query = fun("latest_release_value", []) -> {ok, some(answer())} end,
    ?assertEqual({ok, release_record()}, damage_release_nft:select_release(latest, <<>>, Query)).

historical_lookup_test() ->
    Query = fun
        ("release_token", ["v1.4.1", "ubuntu-noble-amd64"]) -> {ok, some(42)};
        ("metadata", [42]) -> {ok, some(token_metadata())}
    end,
    ?assertEqual({ok, release_record()}, damage_release_nft:select_release(
        {release, <<"v1.4.1">>}, <<"ubuntu-noble-amd64">>, Query)).

missing_release_test() ->
    Query = fun(_, _) -> {ok, {variant, [0, 1], 0, {}}} end,
    ?assertEqual({error, not_found}, damage_release_nft:select_release(latest, <<>>, Query)).

snapshot_mismatch_test() ->
    Query = fun(_, _) -> {ok, some(answer())} end,
    ?assertEqual({error, release_platform_mismatch},
        damage_release_nft:select_release(latest, <<"archlinux-x86_64">>, Query)),
    Historical = fun
        ("release_token", _) -> {ok, some(42)};
        ("metadata", [42]) -> {ok, some(token_metadata())}
    end,
    ?assertEqual({error, release_version_mismatch}, damage_release_nft:select_release(
        {release, <<"v0.0.0">>}, <<"ubuntu-noble-amd64">>, Historical)).

install_manifest_v2_test() ->
    Bin = damage_release_nft:install_manifest(installed_release()),
    ?assertEqual([
        <<"damagebdd-install-v2">>, <<"ae_mainnet">>, <<"ct_test_fixture">>, <<"42">>,
        <<"v1.4.1">>, <<"ubuntu-noble-amd64">>, <<>>, cid(), cid(),
        <<"damage.deb">>, digest(), <<>>
    ], binary:split(Bin, <<"\n">>, [global])).

shared_release_serialization_test() ->
    Encoded = damage_release_nft:release_answer(42, <<"v1.4.1">>,
        <<"ubuntu-noble-amd64">>, <<>>, cid(), cid()),
    ?assertEqual(answer(), Encoded),
    ?assertEqual({ok, release_record()}, damage_release_nft:parse_release(Encoded)).

shared_contract_decoder_test_() ->
    [?_assertEqual({ok, 42}, damage_release_nft:call_return(Call)) || Call <- [
        #{return_type => ok, return_value => 42},
        #{<<"return_type">> => <<"ok">>, <<"return_value">> => 42},
        #{"return_type" => "ok", "return_value" => 42}
    ]].

shared_contract_error_test() ->
    ?assertEqual({error, {revert, <<"denied">>}}, damage_release_nft:call_return(
        #{return_type => revert, return_value => <<"denied">>})),
    ?assertEqual({error, contract_call_failed}, damage_release_nft:call_return(not_a_map)),
    ?assertEqual({error, missing_return_type}, damage_release_nft:call_return(#{})).

prepared_installation_test() ->
    {ok, Actual} = damage_release_nft:installation_fields(release_record(), metadata()),
    Expected = damage_release_nft:installation_identity(Actual),
    ?assertEqual(7, map_size(Expected)),
    ?assertEqual({ok, Expected}, damage_release_nft:prepared_installation(metadata())),
    ?assertEqual(Expected, damage_release_nft:installation_identity(
        Actual#{ignored => <<"extra">>, token_id => 999})).

metadata_binding_test() ->
    Meta = metadata(),
    ?assertEqual({error, installation_manifest_missing},
        damage_release_nft:installation_fields(release_record(), #{})),
    ?assertEqual({error, release_asset_mismatch}, damage_release_nft:installation_fields(
        release_record(), Meta#{<<"file_ipfs">> := <<"different">>})),
    ?assertEqual({error, release_git_sha_mismatch}, damage_release_nft:installation_fields(
        release_record(), Meta#{<<"git_sha">> := binary:copy(<<"a">>, 40)})).

installation_rejection_test_() ->
    Meta = metadata(),
    I = maps:get(<<"installation">>, Meta),
    [?_assertEqual({error, Reason}, damage_release_nft:installation_fields(
        release_record(), Meta#{<<"installation">> := I#{Key => Value}}))
     || {Key, Value, Reason} <- [
        {<<"schema_version">>, 2, invalid_installation_schema},
        {<<"platform">>, <<"archlinux-x86_64">>, release_platform_mismatch},
        {<<"asset_path">>, <<"../damage.deb">>, invalid_asset_path},
        {<<"sha256">>, <<"wrong">>, invalid_package_sha256},
        {<<"package_format">>, <<"exe">>, invalid_package_format},
        {<<"architecture">>, <<"arm64">>, release_architecture_mismatch}
    ]].

json_validation_test() ->
    ?assertEqual({ok, metadata()}, damage_release_nft:checked_json(jsx:encode(metadata()))),
    ?assertEqual({error, invalid_installation_metadata}, damage_release_nft:checked_json(<<"[]">>)),
    ?assertEqual({error, invalid_installation_metadata}, damage_release_nft:checked_json(<<"{">>)),
    ?assertEqual({error, release_metadata_too_large},
        damage_release_nft:checked_json(binary:copy(<<"a">>, 1048577))).

bounded_query_test() ->
    ?assertEqual({ok, value}, damage_release_nft:bounded(fun() -> {ok, value} end, 1000)),
    Parent = self(),
    Tag = make_ref(),
    ?assertEqual(
        {error, release_query_timeout},
        damage_release_nft:bounded(
            fun() ->
                Parent ! {Tag, self()},
                receive
                    never -> ok
                end
            end,
            10
        )
    ),
    receive
        {Tag, Pid} -> ?assertNot(is_process_alive(Pid))
    after 1000 -> error(no_worker)
    end.

package_hash_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Root = filename:join(
        "/tmp", "damage-release-test-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Root),
    Path = filename:join(Root, "damage.deb"),
    Link = filename:join(Root, "link.deb"),
    try
        ok = file:write_file(Path, <<"test">>),
        Expected = list_to_binary(
            string:lowercase(binary_to_list(binary:encode_hex(crypto:hash(sha256, <<"test">>))))
        ),
        ?assertEqual({ok, Expected}, damage_release_nft:package_sha256(Root, "damage.deb")),
        ?assertMatch({error, _}, damage_release_nft:package_sha256(Root, "../damage.deb")),
        ?assertMatch({error, _}, damage_release_nft:package_sha256(Root, Path)),
        ok = file:make_symlink(Path, Link),
        ?assertMatch({error, _}, damage_release_nft:package_sha256(Root, "link.deb"))
    after
        file:delete(Link),
        file:delete(Path),
        file:del_dir(Root)
    end.
