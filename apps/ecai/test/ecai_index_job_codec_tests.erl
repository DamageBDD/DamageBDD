-module(ecai_index_job_codec_tests).

-include_lib("eunit/include/eunit.hrl").

canonical_map_order_test() ->
    A = #{a => 1, b => <<"two">>},
    B = maps:from_list([{b, <<"two">>}, {a, 1}]),
    ?assertEqual(
        ecai_index_job_codec:canonical_binary(A),
        ecai_index_job_codec:canonical_binary(B)
    ).

binary_and_atom_specs_hash_identically_test() ->
    AtomSpec = #{
        kind => ipfs_cid,
        owner => <<"ak_owner">>,
        source => #{cid => <<"bafy-test">>, title => <<"Test">>},
        target => #{base_dir => <<"/tmp/ecai-index">>},
        finalize => #{build_nft_manifest => true, publish_ipfs => false}
    },
    BinarySpec = #{
        <<"kind">> => <<"ipfs_cid">>,
        <<"owner">> => <<"ak_owner">>,
        <<"source">> => #{
            <<"cid">> => <<"bafy-test">>,
            <<"title">> => <<"Test">>
        },
        <<"target">> => #{<<"base_dir">> => <<"/tmp/ecai-index">>},
        <<"finalize">> => #{
            <<"build_nft_manifest">> => true,
            <<"publish_ipfs">> => false
        }
    },
    {ok, HashA} = ecai_index_job_codec:spec_hash(AtomSpec),
    {ok, HashB} = ecai_index_job_codec:spec_hash(BinarySpec),
    ?assertEqual(HashA, HashB).

unsupported_kind_rejected_test() ->
    ?assertMatch(
        {error, {unsupported_job_kind, _}},
        ecai_index_job_codec:normalize_spec(#{
            kind => malicious_module,
            source => #{}
        })
    ).

path_list_is_normalized_test() ->
    {ok, Spec} = ecai_index_job_codec:normalize_spec(#{
        kind => yelp_ndjson,
        source => #{paths => ["/tmp/a.ndjson", <<"/tmp/b.ndjson">>]}
    }),
    ?assertEqual(
        [<<"/tmp/a.ndjson">>, <<"/tmp/b.ndjson">>],
        maps:get(paths, maps:get(source, Spec))
    ).

normalization_binds_event_pipeline_version_test() ->
    {ok, Spec} = ecai_index_job_codec:normalize_spec(#{
        kind => ipfs_cid,
        source => #{cid => <<"bafy-test">>}
    }),
    Pipeline = maps:get(pipeline, Spec),
    ?assertEqual(ecai_ingest_event:version(), maps:get(event, Pipeline)).

auto_mint_is_rejected_until_step4b_test() ->
    ?assertEqual(
        {error, {unsupported_option, auto_mint, step4b_required}},
        ecai_index_job_codec:normalize_spec(#{
            kind => ipfs_cid,
            source => #{cid => <<"bafy-test">>},
            finalize => #{auto_mint => true}
        })
    ).

previous_manifest_is_bound_into_target_test() ->
    {ok, Spec} = ecai_index_job_codec:normalize_spec(#{
        kind => ipfs_cid,
        source => #{cid => <<"bafy-current">>},
        target => #{previous_manifest_cid => <<"bafy-previous">>}
    }),
    Target = maps:get(target, Spec),
    ?assertEqual(
        <<"bafy-previous">>,
        maps:get(previous_manifest_cid, Target)
    ).

externalize_is_json_safe_for_runtime_terms_test() ->
    External = ecai_index_job_codec:externalize(#{
        pid => self(),
        reference => make_ref(),
        reason => {worker_down, self()}
    }),
    ?assert(is_binary(maps:get(<<"pid">>, External))),
    ?assert(is_binary(maps:get(<<"reference">>, External))),
    ?assert(is_list(maps:get(<<"reason">>, External))),
    _Encoded = jsx:encode(External),
    ok.

ledger_only_requires_manifest_finalization_to_be_disabled_test() ->
    ?assertEqual(
        {error, {unsupported_artifact_mode, ledger_only}},
        ecai_index_job_codec:normalize_spec(#{
            kind => ipfs_cid,
            source => #{cid => <<"bafy-ledger">>},
            target => #{mode => ledger_only}
        })
    ),
    ?assertMatch(
        {ok, _},
        ecai_index_job_codec:normalize_spec(#{
            kind => ipfs_cid,
            source => #{cid => <<"bafy-ledger">>},
            target => #{mode => ledger_only},
            finalize => #{
                build_nft_manifest => false,
                publish_ipfs => false
            }
        })
    ).

publish_requires_manifest_test() ->
    ?assertEqual(
        {error, {invalid_finalize_options, publish_requires_manifest}},
        ecai_index_job_codec:normalize_spec(#{
            kind => ipfs_cid,
            source => #{cid => <<"bafy-test">>},
            finalize => #{
                build_nft_manifest => false,
                publish_ipfs => true
            }
        })
    ).
