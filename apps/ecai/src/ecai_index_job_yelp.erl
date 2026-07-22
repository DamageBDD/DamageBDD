-module(ecai_index_job_yelp).
-behaviour(ecai_index_job_adapter).

-export([prepare/1, run_batch/4, result/4]).

prepare(#{spec := Spec}) ->
    Source = maps:get(source, Spec),
    Paths = maps:get(paths, Source),
    case ecai_index_source:describe_paths(Paths) of
        {ok, SourceIdentity} ->
            try ecai_search_server:get_ctx() of
                undefined ->
                    {error, search_index_not_ready};
                Ctx ->
                    {ok,
                        #{
                            ctx => Ctx,
                            paths => Paths,
                            total => length(Paths),
                            source_identity => SourceIdentity
                        },
                        #{
                            phase => preparing,
                            unit => sources,
                            completed => 0,
                            total => length(Paths),
                            sources_completed => 0,
                            sources_total => length(Paths),
                            records_indexed => 0,
                            source_verified => true
                        }}
            catch
                Class:Reason -> {error, {search_context_failed, Class, Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

run_batch(Job, Runtime, Checkpoint0, BatchSize) ->
    Index0 = maps:get(source_index, Checkpoint0, 0),
    Total = maps:get(total, Runtime),
    case Index0 >= Total of
        true ->
            {complete, Runtime, Checkpoint0, final_result(Runtime, Checkpoint0)};
        false ->
            process_paths(Job, Runtime, Checkpoint0, BatchSize, 0)
    end.

result(_Job, _Runtime, _Checkpoint, Result) ->
    {ok, Result}.

process_paths(_Job, Runtime, Checkpoint, BatchSize, Processed) when Processed >= BatchSize ->
    {continue, Runtime, Checkpoint, progress(Runtime, Checkpoint)};
process_paths(Job, Runtime, Checkpoint0, BatchSize, Processed) ->
    Index0 = maps:get(source_index, Checkpoint0, 0),
    Total = maps:get(total, Runtime),
    case Index0 >= Total of
        true ->
            {complete, Runtime, Checkpoint0, final_result(Runtime, Checkpoint0)};
        false ->
            Paths = maps:get(paths, Runtime),
            Path = lists:nth(Index0 + 1, Paths),
            Ctx = maps:get(ctx, Runtime),
            Limit = maps:get(
                limit_per_chunk,
                maps:get(options, maps:get(spec, Job)),
                infinity
            ),
            Before = search_docs(Ctx),
            try ecai_yelp_loader:index_chunks(Ctx, [Path], Limit) of
                ok ->
                    After = search_docs(Ctx),
                    Delta = erlang:max(After - Before, 0),
                    Checkpoint1 = Checkpoint0#{
                        source_index => Index0 + 1,
                        current_source => Path,
                        records_indexed => maps:get(records_indexed, Checkpoint0, 0) + Delta
                    },
                    process_paths(
                        Job,
                        Runtime,
                        Checkpoint1,
                        BatchSize,
                        Processed + 1
                    );
                Other ->
                    {error, {unexpected_yelp_loader_result, Other}}
            catch
                Class:Reason:Stacktrace ->
                    {error, {yelp_index_failed, Path, Class, Reason, Stacktrace}}
            end
    end.

progress(Runtime, Checkpoint) ->
    Completed = maps:get(source_index, Checkpoint, 0),
    Total = maps:get(total, Runtime),
    #{
        phase => indexing,
        unit => sources,
        completed => Completed,
        total => Total,
        sources_completed => Completed,
        sources_total => Total,
        current_source => maps:get(current_source, Checkpoint, undefined),
        records_indexed => maps:get(records_indexed, Checkpoint, 0)
    }.

final_result(Runtime, Checkpoint) ->
    Ctx = maps:get(ctx, Runtime),
    #{
        kind => yelp_ndjson,
        sources_indexed => maps:get(source_index, Checkpoint, 0),
        records_indexed => maps:get(records_indexed, Checkpoint, 0),
        search_size => ecai_search:size(Ctx),
        source_identity => maps:get(source_identity, Runtime)
    }.

search_docs(Ctx) ->
    case ecai_search:size(Ctx) of
        #{docs := Count} when is_integer(Count) -> Count;
        _ -> 0
    end.
