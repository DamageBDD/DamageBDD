-module(ecai_step04a_source_coherence_tests).

-include_lib("eunit/include/eunit.hrl").

step04a_runtime_contract_test() ->
    Required = [
        {ecai_index_job_codec, normalize_spec, 1},
        {ecai_index_job_store, open, 1},
        {ecai_index_job_store, create_job, 5},
        {ecai_index_job_store, replace_idempotency, 2},
        {ecai_index_source, describe_paths, 1},
        {ecai_index_source, verify_paths, 2},
        {ecai_index_job_events, subscribe, 2},
        {ecai_index_job_worker_sup, start_job, 1},
        {ecai_index_job_worker, start_link, 1},
        {ecai_index_job_adapter, module_for, 1},
        {ecai_index_job_yelp, run_batch, 4},
        {ecai_index_job_wikipedia, run_batch, 4},
        {ecai_index_job_ipfs, run_batch, 4},
        {ecai_index_artifact, finalize, 2},
        {ecai_index_artifact, nft_metadata, 1},
        {ecai_index_jobs_sse, init, 2},
        {ecai_index_jobs_sup, start_link, 1},
        {ecai_index_jobs_srv, enqueue, 2},
        {ecai_index_jobs_srv, checkpoint, 3},
        {ecai_index_jobs_srv, pause, 1},
        {ecai_index_jobs_srv, resume, 1},
        {ecai_index_jobs_srv, cancel, 1},
        {ecai_index_jobs_srv, events, 3},
        {ecai_index_jobs_http, trails, 0},
        {damage_ipfs, cat_binary, 1},
        {ecai_ipfs_ingest, ingest_cid, 4},
        {ecai_ipfs_ingest, ingest_cid_result, 4},
        {ecai_disk_indexer, abort, 1},
        {ecai_search, finalize_roots, 1},
        {ecai_terms, version, 0}
    ],
    lists:foreach(
        fun({Module, Function, Arity}) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module)),
            ?assert(erlang:function_exported(Module, Function, Arity))
        end,
        Required
    ).
