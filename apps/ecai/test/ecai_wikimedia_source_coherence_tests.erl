-module(ecai_wikimedia_source_coherence_tests).

-include_lib("eunit/include/eunit.hrl").

runtime_contract_test() ->
    Required = [
        {ecai_http_stream, get_binary, 3},
        {ecai_http_stream, download, 3},
        {ecai_bzip2_stream, fold_lines, 4},
        {ecai_ipfs_activity, open, 2},
        {ecai_ipfs_activity, append, 2},
        {ecai_ipfs_activity, flush, 1},
        {ecai_wikimedia_catalog, resolve, 1},
        {ecai_wikimedia_catalog, write, 3},
        {ecai_wikimedia_selector, spool_month, 4},
        {ecai_wikimedia_selector, aggregate_partition, 3},
        {ecai_wikimedia_selector, merge_selection, 2},
        {ecai_wikimedia_content, extract_shard, 4},
        {ecai_wikimedia_content, finalize_ranked, 2},
        {ecai_wikipedia_loader, load, 2},
        {ecai_search, upsert_record, 3},
        {ecai_search, finalize_roots, 1},
        {ecai_index_job_codec, normalize_spec, 1},
        {ecai_index_job_wikimedia, prepare, 1},
        {ecai_index_job_wikimedia, run_batch, 4},
        {ecai_index_job_wikimedia, result, 4},
        {ecai_wikimedia_search, search, 3},
        {ecai_wikimedia_ops, genesis_spec, 1},
        {ecai_wikimedia_ops, enqueue_genesis, 1},
        {ecai_wikimedia_http, trails, 0},
        {ecai_index_artifact, finalize, 2}
    ],
    lists:foreach(
        fun({Module, Function, Arity}) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module)),
            ?assert(erlang:function_exported(Module, Function, Arity))
        end,
        Required
    ),
    ?assertEqual(
        {ok, ecai_index_job_wikimedia},
        ecai_index_job_adapter:module_for(wikimedia_visibility)
    ),
    {ok, WikimediaSpec} = ecai_index_job_codec:normalize_spec(#{
        <<"schema">> => <<"ecai-index-job/v1">>,
        <<"kind">> => <<"wikimedia_visibility">>,
        <<"source">> => #{
            <<"project">> => <<"enwiki">>,
            <<"pageview_project">> => <<"en.wikipedia">>,
            <<"content_release">> => <<"20260720">>,
            <<"pageview_months">> => [<<"2026-06">>]
        },
        <<"options">> => #{
            <<"minimum_active_months">> => 1,
            <<"selection_shards">> => 8,
            <<"publish_activity_ipfs">> => false
        },
        <<"finalize">> => #{
            <<"build_nft_manifest">> => true,
            <<"publish_ipfs">> => false,
            <<"auto_mint">> => false
        }
    }),
    ?assertEqual(wikimedia_visibility, maps:get(kind, WikimediaSpec)),
    ?assertEqual(
        live_search,
        maps:get(mode, maps:get(target, WikimediaSpec))
    ).

compatibility_modules_remain_available_test() ->
    Required = [
        {ecai_chunker, version, 0},
        {ecai_chunker, validate_utf8, 1},
        {ecai_chunker, fold_utf8, 5},
        {ecai_terms, version, 0},
        {ecai_ingest_event, version, 0},
        {damage_ipfs, cat_binary, 1}
    ],
    lists:foreach(
        fun({Module, Function, Arity}) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module)),
            ?assert(erlang:function_exported(Module, Function, Arity))
        end,
        Required
    ).
