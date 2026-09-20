%% Exercise the real facade, preparation and final-CID pre-mint checker.
%% No module mocks, private keys, chain transactions or public network calls.
-module(damage_release_publication_tests).
-include_lib("eunit/include/eunit.hrl").
-import(damage_release_test_support, [with_kubo/1, kubo_put/3, kubo_requests/1]).

platform() -> <<"ubuntu-noble-amd64">>.
asset() -> damage_release_test_support:cid().
meta_cid() -> <<"Qm", (binary:copy(<<"2">>, 44))/binary>>.
git_sha() -> binary:copy(<<"1">>, 40).
package() -> <<"publication-test package bytes; not an installable DEB">>.
digest() -> string:lowercase(binary:encode_hex(crypto:hash(sha256, package()))).
asset_path() -> <<(asset())/binary, "/damage.deb">>.
manifest_path() -> <<(asset())/binary, "/installation.json">>.

manifest() ->
    #{<<"schema_version">> => 1, <<"platform">> => platform(),
      <<"package_format">> => <<"deb">>, <<"architecture">> => <<"amd64">>,
      <<"asset_path">> => <<"damage.deb">>, <<"sha256">> => digest(),
      <<"git_sha">> => git_sha()}.

seed(Fixture, Manifest) ->
    ok = kubo_put(Fixture, manifest_path(), jsx:encode(Manifest)),
    ok = kubo_put(Fixture, asset_path(), package()).

prepare(Fixture) ->
    ok = seed(Fixture, manifest()),
    damage_release_nft:prepare_metadata(#{name => <<"fixture">>}, platform(),
        asset(), <<"installation.json">>).

check_final(Context, MetaCid) ->
    steps_release_nft:checked_mint_inputs(Context, <<"v1.4.2">>, platform(),
        git_sha(), MetaCid, asset()).

prepare_and_verify_final_cid_test() ->
    with_kubo(fun(Fixture) ->
        {ok, Prepared} = prepare(Fixture),
        ?assertEqual(<<"fixture">>, maps:get(<<"name">>, Prepared)),
        ?assertEqual(asset(), maps:get(<<"file_ipfs">>, Prepared)),
        ?assertEqual(git_sha(), maps:get(<<"git_sha">>, Prepared)),
        ?assertEqual(maps:remove(<<"git_sha">>, manifest()),
            maps:get(<<"installation">>, Prepared)),
        {ok, Expected} = damage_release_nft:prepared_installation(Prepared),
        ?assertEqual(digest(), maps:get(sha256, Expected)),
        ok = kubo_put(Fixture, meta_cid(), jsx:encode(Prepared)),
        ?assertEqual(ok, check_final(#{build_release_installation_expected => Expected}, meta_cid())),
        ?assertEqual([
            {<<"/ipfs/", (manifest_path())/binary>>, 1048577},
            {<<"/ipfs/", (asset_path())/binary>>, 4294967297},
            {<<"/ipfs/", (meta_cid())/binary>>, 1048577}
        ], kubo_requests(Fixture))
    end).

prepare_step_records_verified_identity_test() ->
    with_kubo(fun(Fixture) ->
        seed(Fixture, manifest()),
        Parts = ["I prepare installation metadata in", "meta", "for platform",
            "ubuntu-noble-amd64", "from IPFS asset hash in", "asset_hash",
            "with manifest path", "installation.json"],
        Context = #{"meta" => #{name => <<"fixture">>}, "asset_hash" => asset(), keep => unchanged},
        Result = steps_release_nft:step([], Context, <<"When">>, 1, Parts, <<>>),
        ?assertNot(maps:is_key(fail, Result)),
        ?assertEqual(unchanged, maps:get(keep, Result)),
        ?assertEqual(git_sha(), maps:get(git_sha, Result)),
        ?assertEqual(platform(), maps:get(build_release_platform, Result)),
        Prepared = maps:get("meta", Result),
        {ok, Expected} = damage_release_nft:prepared_installation(Prepared),
        ?assertEqual(Expected, maps:get(build_release_installation_expected, Result)),
        ok = kubo_put(Fixture, meta_cid(), jsx:encode(Prepared)),
        ?assertEqual(ok, check_final(Result, meta_cid()))
    end).

package_hash_mismatch_rejected_test() ->
    with_kubo(fun(Fixture) ->
        Bad = (manifest())#{<<"sha256">> := binary:copy(<<"0">>, 64)},
        seed(Fixture, Bad),
        ?assertEqual({error, {release_package_hash_mismatch, #{
                manifest_path => manifest_path(),
                package_path => asset_path(),
                expected_sha256 => binary:copy(<<"0">>, 64),
                actual_sha256 => digest()
            }}},
            damage_release_nft:prepare_metadata(#{}, platform(), asset(), <<"installation.json">>)),
        ?assertEqual(2, length(kubo_requests(Fixture)))
    end).

%% Model a DIFFERENT final CID after preparation, not mutation of an existing
%% immutable IPFS object. Neither a checksum nor a path may silently change.
changed_final_metadata_test_() ->
    [
        {"changed package checksum", fun() -> changed_final(
            fun(M) -> edit_install(M, <<"sha256">>, binary:copy(<<"0">>, 64)) end,
            prepared_installation_metadata_mismatch) end},
        {"changed package path", fun() -> changed_final(
            fun(M) -> edit_install(M, <<"asset_path">>, <<"other.deb">>) end,
            prepared_installation_metadata_mismatch) end},
        {"changed artifact CID", fun() -> changed_final(
            fun(M) -> M#{<<"file_ipfs">> := meta_cid()} end,
            {prepared_installation_metadata_invalid, release_asset_mismatch}) end},
        {"changed Git SHA", fun() -> changed_final(
            fun(M) -> M#{<<"git_sha">> := binary:copy(<<"3">>, 40)} end,
            {prepared_installation_metadata_invalid, release_git_sha_mismatch}) end},
        {"changed platform", fun() -> changed_final(
            fun(M) -> edit_install(M, <<"platform">>, <<"ubuntu-jammy-amd64">>) end,
            {prepared_installation_metadata_invalid, release_platform_mismatch}) end},
        {"installation fields removed", fun() -> changed_final(
            fun(M) -> maps:remove(<<"installation">>, M) end,
            {prepared_installation_metadata_invalid, installation_manifest_missing}) end}
    ].

changed_final(Change, Reason) ->
    with_kubo(fun(Fixture) ->
        {ok, Prepared} = prepare(Fixture),
        {ok, Expected} = damage_release_nft:prepared_installation(Prepared),
        ok = kubo_put(Fixture, meta_cid(), jsx:encode(Change(Prepared))),
        ?assertEqual({error, Reason},
            check_final(#{build_release_installation_expected => Expected}, meta_cid())),
        ?assertEqual({<<"/ipfs/", (meta_cid())/binary>>, 1048577}, lists:last(kubo_requests(Fixture))),
        ?assertEqual(3, length(kubo_requests(Fixture)))
    end).

edit_install(Meta, Key, Value) ->
    Install = maps:get(<<"installation">>, Meta),
    Meta#{<<"installation">> := Install#{Key := Value}}.

fixture_restores_configuration_after_exception_test() ->
    Keys = [ipfs_runtime, build_release_query_timeout, build_release_publish_timeout,
        build_release_require_installation, build_release_announce_oracle],
    Before = [{K, application:get_env(damage, K)} || K <- Keys],
    ?assertError(expected_fixture_failure, with_kubo(fun(_) -> error(expected_fixture_failure) end)),
    ?assertEqual(Before, [{K, application:get_env(damage, K)} || K <- Keys]).

%% These tests cover the specific preparation boundary: there must be enough
%% evidence in a BDD failure to distinguish a manifest read from package hash.
missing_installation_file_reports_stage_test() ->
    with_kubo(fun(Fixture) ->
        ?assertEqual({error, {installation_ipfs_failed,
                read_installation_manifest, manifest_path(),
                {release_ipfs_http_status, 404}}},
            damage_release_nft:prepare_metadata(#{}, platform(), asset(), <<"installation.json">>)),
        ?assertEqual([{<<"/ipfs/", (manifest_path())/binary>>, 1048577}],
            kubo_requests(Fixture))
    end).

missing_package_reports_hash_stage_test() ->
    with_kubo(fun(Fixture) ->
        ok = kubo_put(Fixture, manifest_path(), jsx:encode(manifest())),
        ?assertEqual({error, {installation_ipfs_failed,
                hash_installation_package, asset_path(),
                {release_ipfs_http_status, 404}}},
            damage_release_nft:prepare_metadata(#{}, platform(), asset(), <<"installation.json">>)),
        ?assertEqual(2, length(kubo_requests(Fixture)))
    end).

invalid_manifest_json_reports_read_stage_test() ->
    with_kubo(fun(Fixture) ->
        ok = kubo_put(Fixture, manifest_path(), <<"{not json">>),
        ?assertEqual({error, {installation_ipfs_failed,
                read_installation_manifest, manifest_path(), invalid_installation_metadata}},
            damage_release_nft:prepare_metadata(#{}, platform(), asset(), <<"installation.json">>)),
        ?assertEqual(1, length(kubo_requests(Fixture)))
    end).

%% Different file paths within one artifact must not be collapsed into a
%% generic checksum failure. No manifest/context secrets enter diagnostics.
package_hash_mismatch_reports_selected_path_test() ->
    with_kubo(fun(Fixture) ->
        Nested = <<"packages/damage.deb">>,
        WrongDigest = binary:copy(<<"0">>, 64),
        M = (manifest())#{<<"asset_path">> := Nested, <<"sha256">> := WrongDigest,
                         <<"private_note">> => <<"DO-NOT-REPORT-METADATA">>},
        ok = kubo_put(Fixture, manifest_path(), jsx:encode(M)),
        Target = <<(asset())/binary, "/", Nested/binary>>,
        ok = kubo_put(Fixture, Target, package()),
        ?assertEqual({error, {release_package_hash_mismatch, #{
                manifest_path => manifest_path(),
                package_path => Target,
                expected_sha256 => WrongDigest,
                actual_sha256 => digest()
            }}},
            damage_release_nft:prepare_metadata(
                #{secret => <<"DO-NOT-REPORT-CONTEXT">>}, platform(), asset(), <<"installation.json">>)),
        ?assertEqual(2, length(kubo_requests(Fixture)))
    end).

package_hash_mismatch_preserved_by_step_test() ->
    with_kubo(fun(Fixture) ->
        seed(Fixture, (manifest())#{<<"sha256">> := binary:copy(<<"0">>, 64)}),
        Parts = ["I prepare installation metadata in", "meta", "for platform",
            "ubuntu-noble-amd64", "from IPFS asset hash in", "asset_hash",
            "with manifest path", "installation.json"],
        Context = #{"meta" => #{name => <<"fixture">>}, "asset_hash" => asset()},
        Result = steps_release_nft:step([], Context, <<"When">>, 1, Parts, <<>>),
        Failure = iolist_to_binary(maps:get(fail, Result)),
        ?assertNotEqual(nomatch, binary:match(Failure, <<"release_package_hash_mismatch">>)),
        ?assertNotEqual(nomatch, binary:match(Failure, <<"expected_sha256">>)),
        ?assertNotEqual(nomatch, binary:match(Failure, <<"actual_sha256">>)),
        ?assertNot(maps:is_key(build_release_installation_expected, Result)),
        ?assertEqual(maps:get("meta", Context), maps:get("meta", Result))
    end).

packaged_release_version_flows_into_context_test() ->
    with_kubo(fun(Fixture) ->
        Version = <<"1.4.2">>,
        seed(Fixture, (manifest())#{<<"release">> => Version}),
        Parts = ["I prepare installation metadata in", "meta", "for platform",
            "ubuntu-noble-amd64", "from IPFS asset hash in", "asset_hash",
            "with manifest path", "installation.json"],
        Context = #{"meta" => #{name => <<"fixture">>}, "asset_hash" => asset()},
        Result = steps_release_nft:step([], Context, <<"When">>, 1, Parts, <<>>),
        ?assertNot(maps:is_key(fail, Result)),
        ?assertEqual(Version, maps:get("build_release", Result)),
        ?assertEqual(Version, maps:get(<<"build_release">>, Result)),
        ?assertEqual(git_sha(), maps:get("git_sha", Result)),
        Prepared = maps:get("meta", Result),
        ?assertEqual(Version, maps:get(<<"release">>, Prepared)),
        ok = kubo_put(Fixture, meta_cid(), jsx:encode(Prepared)),
        ?assertEqual(ok, steps_release_nft:checked_mint_inputs(Result,
            Version, platform(), git_sha(), meta_cid(), asset())),
        ?assertEqual({error, {prepared_installation_metadata_invalid, release_version_mismatch}},
            steps_release_nft:checked_mint_inputs(Result, <<"install-opaque-cid">>,
                platform(), git_sha(), meta_cid(), asset()))
    end).

manifest_release_conflict_rejected_test() ->
    with_kubo(fun(Fixture) ->
        seed(Fixture, (manifest())#{<<"release">> => <<"1.4.2">>}),
        ?assertEqual({error, release_version_mismatch}, damage_release_nft:prepare_metadata(
            #{<<"release">> => <<"different">>}, platform(), asset(), <<"installation.json">>))
    end).
