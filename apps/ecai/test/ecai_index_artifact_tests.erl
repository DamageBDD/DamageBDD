-module(ecai_index_artifact_tests).

-include_lib("eunit/include/eunit.hrl").

disk_artifact_is_path_independent_and_chained_test() ->
    Root = temp_dir(),
    ArtifactRoot = filename:join(Root, "artifacts"),
    BaseA = filename:join(Root, "index-a"),
    BaseB = filename:join(Root, "index-b"),
    Previous = <<"bafy-previous-index-manifest">>,
    PreviousEnv = application:get_env(ecai, index_jobs_artifact_dir),
    try
        ok = prepare_fake_index(BaseA),
        ok = prepare_fake_index(BaseB),
        ok = application:set_env(ecai, index_jobs_artifact_dir, ArtifactRoot),
        JobA = job(<<"ijob-artifact-a">>, BaseA, Previous),
        JobB = job(<<"ijob-artifact-b">>, BaseB, Previous),
        Result = #{
            documents_indexed => 1,
            records_indexed => 2,
            duplicates => 0
        },
        {ok, ArtifactA} = ecai_index_artifact:finalize(JobA, Result),
        {ok, ArtifactB} = ecai_index_artifact:finalize(JobB, Result),
        ?assertEqual(false, maps:get(ready_to_mint, ArtifactA)),
        ?assertEqual(
            maps:get(index_root, ArtifactA),
            maps:get(index_root, ArtifactB)
        ),
        ?assertEqual(
            maps:get(manifest_sha256, ArtifactA),
            maps:get(manifest_sha256, ArtifactB)
        ),
        ?assertEqual(
            Previous,
            maps:get(previous_manifest_cid, ArtifactA)
        ),
        ?assertEqual(
            maps:get(source_frontier_root, ArtifactA),
            maps:get(source_frontier_root, ArtifactB)
        )
    after
        restore_env(index_jobs_artifact_dir, PreviousEnv),
        remove_tree(Root)
    end.

job(JobId, BaseDir, PreviousManifestCid) ->
    {ok, Spec} = ecai_index_job_codec:normalize_spec(#{
        kind => ipfs_cid,
        source => #{
            cid => <<"bafy-source">>,
            source_key => <<"ipfs://bafy-source">>,
            title => <<"Source">>
        },
        target => #{
            index_id => <<"global-ecai">>,
            namespace => <<"org.damagebdd.global">>,
            base_dir => unicode:characters_to_binary(BaseDir),
            mode => searchable_disk,
            previous_manifest_cid => PreviousManifestCid
        },
        finalize => #{
            build_nft_manifest => true,
            publish_ipfs => false,
            auto_mint => false
        }
    }),
    #{id => JobId, spec => Spec}.

prepare_fake_index(BaseDir) ->
    Segment = filename:join(BaseDir, "seg_000001.ecs"),
    Manifest = filename:join(BaseDir, "manifest.term"),
    Docstore = filename:join([BaseDir, "docstore", "ecai_docstore.dets"]),
    ok = filelib:ensure_dir(Segment),
    ok = filelib:ensure_dir(Docstore),
    ok = file:write_file(Segment, <<"deterministic-segment">>, [raw, binary]),
    ok = file:write_file(Docstore, <<"deterministic-docstore">>, [raw, binary]),
    file:write_file(
        Manifest,
        [unicode:characters_to_binary(Segment), <<"\n">>],
        [raw, binary]
    ).

restore_env(Key, {ok, Value}) ->
    application:set_env(ecai, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ecai, Key).

temp_dir() ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(
        Root,
        "ecai-index-artifact-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Child = filename:join(Path, Name),
                    case filelib:is_dir(Child) of
                        true -> remove_tree(Child);
                        false -> _ = file:delete(Child)
                    end
                end,
                Names
            ),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} -> ok;
        {error, _Reason} -> ok
    end.

nft_metadata_rejects_unfinished_job_test() ->
    ?assertEqual(
        {error, artifact_not_ready},
        ecai_index_artifact:nft_metadata(#{
            artifact => undefined,
            spec => #{}
        })
    ).
