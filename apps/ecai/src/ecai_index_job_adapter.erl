%%--------------------------------------------------------------------
%% Closed adapter dispatch for indexing jobs.
%%--------------------------------------------------------------------
-module(ecai_index_job_adapter).

-export([module_for/1]).

-callback prepare(Job :: map()) ->
    {ok, Runtime :: term(), Progress :: map()} | {error, term()}.

-callback run_batch(
    Job :: map(),
    Runtime :: term(),
    Checkpoint :: map(),
    BatchSize :: pos_integer()
) ->
    {continue, Runtime1 :: term(), Checkpoint1 :: map(), Progress :: map()}
    | {complete, Runtime1 :: term(), Checkpoint1 :: map(), Result :: map()}
    | {error, term()}.

-callback result(Job :: map(), Runtime :: term(), Checkpoint :: map(), Result :: map()) ->
    {ok, map()} | {error, term()}.

-spec module_for(atom()) -> {ok, module()} | {error, term()}.
module_for(yelp_ndjson) -> {ok, ecai_index_job_yelp};
module_for(wikipedia_jsonl) -> {ok, ecai_index_job_wikipedia};
module_for(ipfs_cid) -> {ok, ecai_index_job_ipfs};
module_for(ipfs_manifest) -> {ok, ecai_index_job_ipfs};
module_for(wikimedia_visibility) -> {ok, ecai_index_job_wikimedia};
module_for(Other) -> {error, {unsupported_job_kind, Other}}.
