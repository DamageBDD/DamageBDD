-module(steps_release_nft_dry_tests).
-include_lib("eunit/include/eunit.hrl").

obsolete_publication_test() ->
    Context = #{build_release_mint_result => #{token_id => 42}},
    Parts = ["I publish the minted build release for installation using package file",
        "docker/out/damage.deb", "and IPFS path", "damage.deb"],
    Dry = steps_release_nft:step_dry([], Context, <<"When">>, 1, Parts, <<>>),
    Run = steps_release_nft:step([], Context, <<"When">>, 1, Parts, <<>>),
    ?assertEqual(Dry, Run),
    ?assert(is_binary(maps:get(fail, Dry))),
    ?assertEqual(maps:get(build_release_mint_result, Context),
        maps:get(build_release_mint_result, Dry)).

prepared_step_dry_run_test() ->
    Parts = ["I prepare installation metadata in", "meta", "for platform",
        "ubuntu-noble-amd64", "from IPFS asset hash in", "asset_hash",
        "with manifest path", "installation.json"],
    %% No context assets/keys/backends are required or contacted during dry run.
    ?assertEqual(#{}, steps_release_nft:step_dry([], #{}, <<"When">>, 1, Parts, <<>>)).

mint_dry_run_variants_test_() ->
    [?_assertEqual(#{}, steps_release_nft:step_dry([], #{}, <<"When">>, 1, Parts, <<>>))
     || Parts <- [
        ["I mint an NFT with metadata IPFS hash in", "meta", "and asset hash in", "asset"],
        ["I mint a build release NFT for platform", "ubuntu-noble-amd64",
            "with metadata IPFS hash in", "meta", "and asset hash in", "asset"],
        ["I mint build release", "v1", "for platform", "ubuntu-noble-amd64",
            "with git SHA", "", "metadata IPFS hash in", "meta", "and asset hash in", "asset"]
    ]].

retry_identity_test() ->
    Record = damage_release_test_support:release_record(),
    Expected = maps:remove(token_id, Record),
    ?assert(steps_release_nft:existing_release_matches(Record, Expected)),
    ?assertNot(steps_release_nft:existing_release_matches(
        Record#{metadata_cid := <<"different">>}, Expected)).

optional_announcement_failure_test() ->
    Mint = (damage_release_test_support:release_record())#{mint_status => minted,
        mint_tx_hash => <<"th_fixture">>, future_field => retained},
    Base = #{build_release_mint_result => Mint},
    Result = steps_release_nft:oracle_announcement_result(Base, #{fail => unavailable}),
    Updated = maps:get(build_release_mint_result, Result),
    ?assertNot(maps:is_key(fail, Result)),
    ?assertEqual(failed, maps:get(oracle_status, Updated)),
    ?assertEqual(retained, maps:get(future_field, Updated)),
    ?assertEqual(<<"th_fixture">>, maps:get(mint_tx_hash, Updated)).
