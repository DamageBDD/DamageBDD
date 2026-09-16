-module(damage_nft_discovery_tests).
-include_lib("eunit/include/eunit.hrl").

cid() -> <<"b", (binary:copy(<<"a">>, 58))/binary>>.
sha() -> binary:copy(<<"b">>, 64).
git_sha() -> binary:copy(<<"c">>, 40).
record_value() -> #{token_id => 7, release => <<"v1.2">>, platform => <<"archlinux-x86_64">>,
    git_sha => git_sha(), metadata_cid => cid(), asset_cid => cid()}.
answer() -> iolist_to_binary(["7|v1.2|archlinux-x86_64|", git_sha(), "|ipfs://", cid(), "|ipfs://", cid()]).
metadata() -> #{<<"file_ipfs">> => cid(), <<"git_sha">> => git_sha(), <<"installation">> => #{
    <<"schema_version">> => 1, <<"platform">> => <<"archlinux-x86_64">>,
    <<"architecture">> => <<"x86_64">>, <<"package_format">> => <<"pkg.tar.zst">>,
    <<"asset_path">> => <<"damage.pkg.tar.zst">>, <<"sha256">> => sha()}}.
some(V) -> {variant, [0, 1], 1, {V}}.

latest_calls_existing_getter_test() ->
    Query = fun("latest_release_value_for", ["archlinux-x86_64"]) -> {ok, some(answer())} end,
    ?assertEqual({ok, record_value()}, damage_release_nft:select_release(latest, <<"archlinux-x86_64">>, Query)).

global_latest_arity_test() ->
    Query = fun("latest_release_value", []) -> {ok, some(answer())} end,
    ?assertEqual({ok, record_value()}, damage_release_nft:select_release(latest, <<>>, Query)).

historical_immutable_metadata_test() ->
    M = #{<<"release">> => <<"v1.2">>, <<"platform">> => <<"archlinux-x86_64">>,
        <<"git_sha">> => git_sha(), <<"url">> => <<"ipfs://", (cid())/binary>>,
        <<"asset">> => <<"ipfs://", (cid())/binary>>},
    Query = fun
        ("release_token", ["v1.2", "archlinux-x86_64"]) -> {ok, some(7)};
        ("metadata", [7]) -> {ok, some({variant, [1, 1], 1, {M}})}
    end,
    ?assertEqual({ok, record_value()}, damage_release_nft:select_release(
        {release, <<"v1.2">>}, <<"archlinux-x86_64">>, Query)).

wrong_platform_rejected_test() ->
    Query = fun(_, _) -> {ok, some(answer())} end,
    ?assertEqual({error, release_platform_mismatch}, damage_release_nft:select_release(
        latest, <<"ubuntu-noble-amd64">>, Query)).

missing_token_test() ->
    Query = fun(_, _) -> {ok, {variant, [0, 1], 0, {}}} end,
    ?assertEqual({error, not_found}, damage_release_nft:select_release(latest, <<>>, Query)).

metadata_binding_test() ->
    R = record_value(), M = metadata(),
    {ok, Install} = damage_release_nft:installation_fields(R, M),
    ?assertEqual(sha(), maps:get(sha256, Install)),
    ?assertEqual({error, release_asset_mismatch}, damage_release_nft:installation_fields(
        R, M#{<<"file_ipfs">> := <<"another">>})),
    ?assertEqual({error, release_git_sha_mismatch}, damage_release_nft:installation_fields(
        R, M#{<<"git_sha">> := <<"another">>})),
    ?assertEqual({error, installation_manifest_missing}, damage_release_nft:installation_fields(
        R, maps:remove(<<"installation">>, M))).

metadata_path_and_schema_test() ->
    R = record_value(), M = metadata(), I = maps:get(<<"installation">>, M),
    ?assertEqual({error, invalid_asset_path}, damage_release_nft:installation_fields(
        R, M#{<<"installation">> := I#{<<"asset_path">> := <<"../private">>}})),
    ?assertEqual({error, invalid_installation_schema}, damage_release_nft:installation_fields(
        R, M#{<<"installation">> := I#{<<"schema_version">> := 2}})),
    ?assertEqual({error, release_architecture_mismatch}, damage_release_nft:installation_fields(
        R, M#{<<"installation">> := I#{<<"architecture">> := <<"aarch64">>}})).

v2_wire_no_index_test() ->
    {ok, Install} = damage_release_nft:installation_fields(record_value(), metadata()),
    Wire = damage_release_nft:install_manifest(Install#{
        network_id => <<"ae_mainnet">>, contract_id => <<"ct_test">>}),
    Lines = binary:split(Wire, <<"\n">>, [global]),
    ?assertEqual(12, length(Lines)), % 11 fields plus trailing split empty
    ?assertEqual(<<"damagebdd-install-v2">>, hd(Lines)),
    ?assertEqual(<<"ct_test">>, lists:nth(3, Lines)).

retry_content_mismatch_test() ->
    Expected = maps:remove(token_id, record_value()),
    ?assert(steps_release_nft:existing_release_matches(record_value(), Expected)),
    ?assertNot(steps_release_nft:existing_release_matches(
        (record_value())#{asset_cid := <<"different">>}, Expected)).

optional_announcement_failure_keeps_mint_test() ->
    Base = #{build_release_mint_result => record_value()},
    Result = steps_release_nft:oracle_announcement_result(Base, #{fail => snapshot_changed}),
    ?assertEqual(false, maps:is_key(fail, Result)),
    Mint = maps:get(build_release_mint_result, Result),
    ?assertEqual(7, maps:get(token_id, Mint)),
    ?assertEqual(failed, maps:get(oracle_status, Mint)).

bounded_failure_test() ->
    ?assertEqual({error, release_query_timeout}, damage_release_nft:bounded(
        fun() -> receive never -> ok end end, 5)),
    ?assertEqual({ok, done}, damage_release_nft:bounded(fun() -> {ok, done} end, 100)).
