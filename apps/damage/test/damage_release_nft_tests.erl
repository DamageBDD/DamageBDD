-module(damage_release_nft_tests).
-include_lib("eunit/include/eunit.hrl").

cid() -> <<"QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS">>.
digest() -> binary:copy(<<"a">>, 64).
answer() ->
    C = cid(),
    <<"42|v1.4.1|ubuntu-noble-amd64||ipfs://", C/binary, "|ipfs://", C/binary>>.
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

invalid_manifest_test_() ->
    [
        ?_assertMatch({error, _}, damage_release_nft:parse_manifest(M))
     || M <- [
            <<>>,
            <<"bogus">>,
            binary:copy(<<"a">>, 4097),
            manifest(<<"../damage.deb">>, digest()),
            manifest(<<"/tmp/file.deb">>, digest()),
            manifest(<<"dir//file.deb">>, digest()),
            manifest(<<"dir/%2e%2e/file.deb">>, digest()),
            manifest(<<"dir/./file.deb">>, digest()),
            manifest(<<"$(id)">>, digest()),
            manifest(<<"damage.deb">>, <<>>),
            manifest(<<"damage.deb">>, binary:copy(<<"g">>, 64)),
            <<(manifest(<<"damage.deb">>, digest()))/binary, "\n">>
        ]
    ].

option_decode_test() ->
    ?assertEqual(none, damage_release_nft:option_value({variant, [0, 1], 0, {}})),
    ?assertEqual({ok, answer()}, damage_release_nft:option_value({variant, [0, 1], 1, {answer()}})),
    ?assertMatch({error, _}, damage_release_nft:option_value({variant, [1, 0], 1, {answer()}})).

snapshot_test() ->
    Source = {address, <<1:256>>},
    Ct = aeser_api_encoder:encode(contract_pubkey, <<1:256>>),
    Config = #{
        nft => Ct, index => Ct, network => <<"ae_mainnet">>, gateway => <<"https://ipfs.io/ipfs">>
    },
    Value = {variant, [0, 1], 1, {manifest(<<"damage.deb">>, digest())}},
    {ok, R} = damage_release_nft:decode_snapshot(
        {tuple, {Source, Value}},
        Config,
        latest,
        <<"ubuntu-noble-amd64">>
    ),
    ?assertEqual(Ct, maps:get(contract_id, R)),
    ?assertEqual(
        12,
        length(
            binary:split(
                string:trim(damage_release_nft:install_manifest(R), trailing, "\n"),
                <<"\n">>,
                [global]
            )
        )
    ),
    ?assertEqual(
        {error, not_found},
        damage_release_nft:decode_snapshot(
            {Source, {variant, [0, 1], 0, {}}}, Config, latest, <<>>
        )
    ),
    ?assertEqual(
        {error, release_platform_mismatch},
        damage_release_nft:decode_snapshot(
            {Source, Value}, Config, latest, <<"archlinux-x86_64">>
        )
    ),
    ?assertEqual(
        {error, release_version_mismatch},
        damage_release_nft:decode_snapshot(
            {Source, Value}, Config, {release, <<"v0.0.0">>}, <<"ubuntu-noble-amd64">>
        )
    ),
    ?assertEqual(
        {error, release_source_mismatch},
        damage_release_nft:decode_snapshot(
            {{address, <<2:256>>}, Value}, Config, latest, <<>>
        )
    ).

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
