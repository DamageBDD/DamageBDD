%% A single upstream unit, without constructing a search ETS context.
-module(ecai_index_job_wikimedia_unit).
-behaviour(ecai_index_job_adapter).
-export([prepare/1, run_batch/4, result/4]).
prepare(#{spec := #{source := #{plan_root := Root, unit_id := Id}}}) ->
    case ecai_wikimedia_work:unit(Root, Id) of
        {ok, Plan, Unit} ->
            {ok, #{root => Root, unit_id => Id, plan => Plan, unit => Unit},
             #{phase => maps:get(stage, Unit), unit => work_units, total => 1, completed => 0}};
        Error -> Error
    end.
run_batch(#{id := JobId}, Runtime, _Checkpoint, _Batch) ->
    %% Heap limit excludes ETS and external decompression processes. Selector
    %% table size/memory caps are independently checked by the selector.
    Words = maps:get(worker_heap_words, maps:get(limits, maps:get(plan, Runtime))),
    Old = process_flag(max_heap_size, #{size => Words, kill => true, error_logger => true}),
    Progress = fun(P) ->
        %% Work-unit progress is deliberately indeterminate inside one month or
        %% compressed shard. Never invent a percentage from downloaded bytes.
        _ = ecai_index_jobs_srv:checkpoint(JobId,
            #{unit_id => maps:get(unit_id, Runtime), phase => maps:get(phase, P, running)},
            P#{unit => work_units, total => 1, completed => 0}), ok
    end,
    try ecai_wikimedia_work:execute(maps:get(root, Runtime), maps:get(unit_id, Runtime), Progress) of
        {ok, Receipt} ->
            {complete, Runtime, #{receipt_sha256 => maps:get(receipt_sha256, Receipt)}, Receipt};
        Error -> Error
    after process_flag(max_heap_size, Old) end.
result(_Job, _Runtime, _Checkpoint, Result) -> {ok, Result}.
