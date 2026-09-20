-module(steps_release_nft_install_flow_tests).
-include_lib("eunit/include/eunit.hrl").

legacy_parts() ->
    ["I publish the minted build release for installation using package file",
     "docker/out/damage.deb", "and IPFS path", "damage.deb"].

legacy_step_rejected_in_dry_run_test() ->
    Context = #{public_key => <<"not_used">>, keep => unchanged},
    Result = steps_release_nft:step_dry([], Context, <<"When">>, 111,
                                      legacy_parts(), <<>>),
    ?assert(is_binary(maps:get(fail, Result))),
    ?assertNotEqual(nomatch, binary:match(maps:get(fail, Result),
                                        <<"obsolete_install_publication_step">>)),
    ?assertEqual(Context, maps:remove(fail, Result)).

legacy_step_runtime_preserves_successful_mint_test() ->
    Mint = #{token_id => 17, mint_status => minted},
    Context = #{build_release_mint_result => Mint},
    Result = steps_release_nft:step([], Context, <<"When">>, 111,
                                 legacy_parts(), <<>>),
    ?assert(maps:is_key(fail, Result)),
    ?assertEqual(Mint, maps:get(build_release_mint_result, Result)),
    ?assertNot(maps:is_key(build_release_install_result, Result)).

legacy_step_never_requires_a_local_run_directory_test() ->
    ?assertEqual(
        steps_release_nft:step([], #{}, <<"When">>, 1, legacy_parts(), <<>>),
        steps_release_nft:step([{run_dir, "/does/not/exist"}], #{},
                              <<"When">>, 1, legacy_parts(), <<>>)).

prepare_step_is_side_effect_free_in_dry_run_test() ->
    Parts = ["I prepare installation metadata in", "meta", "for platform",
             "ubuntu-noble-amd64", "from IPFS asset hash in", "asset_hash",
             "with manifest path", "installation.json"],
    %% No IPFS daemon, metadata value, account or run directory is needed.
    Context = #{keep => unchanged},
    ?assertEqual(Context,
        steps_release_nft:step_dry([], Context, <<"When">>, 1, Parts, <<>>)).

missing_preparation_fails_before_mint_test() ->
    Keys = [build_release_require_installation, build_release_announce_oracle],
    Saved = [{K, application:get_env(damage, K)} || K <- Keys],
    try
        application:set_env(damage, build_release_require_installation, true),
        application:set_env(damage, build_release_announce_oracle, false),
        Cid = <<"QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS">>,
        ?assertEqual({error, installation_metadata_not_prepared},
            steps_release_nft:checked_mint_inputs(#{}, <<"v1.0">>,
                <<"ubuntu-noble-amd64">>, <<>>, Cid, Cid))
    after
        lists:foreach(fun
            ({K, undefined}) -> application:unset_env(damage, K);
            ({K, {ok, V}}) -> application:set_env(damage, K, V)
        end, Saved)
    end.

discovery_steps_are_side_effect_free_in_dry_run_test_() ->
    [?_assertEqual(#{keep => unchanged}, steps_release_nft:step_dry([], #{keep => unchanged},
        <<"Then">>, 1, Parts, <<>>)) || Parts <- [
        ["the build release discovery is configured"],
        ["the latest installable build release must match the minted NFT"]
    ]].

missing_discovery_identity_preserves_successful_mint_test() ->
    Mint = #{token_id => 42, mint_status => minted},
    Context = #{build_release_mint_result => Mint,
        build_release_install_result => stale_result,
        build_release_install_manifest => <<"stale">>},
    Result = steps_release_nft:step([], Context, <<"Then">>, 1,
        ["the latest installable build release must match the minted NFT"], <<>>),
    ?assert(maps:is_key(fail, Result)),
    ?assertEqual(Mint, maps:get(build_release_mint_result, Result)),
    ?assertNot(maps:is_key(build_release_install_result, Result)).
