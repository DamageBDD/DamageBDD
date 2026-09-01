%%--------------------------------------------------------------------
%% Cooperative indexing job worker.
%%--------------------------------------------------------------------
-module(ecai_index_job_worker).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-record(st, {
    job_id
}).

start_link(JobId) when is_binary(JobId) ->
    gen_server:start_link(?MODULE, JobId, []).

init(JobId) ->
    {ok, #st{job_id = JobId}, {continue, run}}.

handle_continue(run, State = #st{job_id = JobId}) ->
    execute(JobId),
    {stop, normal, State}.

handle_call(_Request, _From, State) ->
    {reply, {error, unhandled}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

execute(JobId) ->
    try
        {ok, Job} = ecai_index_jobs_srv:worker_job(JobId),
        {ok, _} = ecai_index_jobs_srv:worker_started(JobId, self()),
        Checkpoint = maps:get(checkpoint, Job, #{}),
        case ecai_index_jobs_srv:control(JobId) of
            pause ->
                _ = ecai_index_jobs_srv:worker_paused(JobId, Checkpoint),
                ok;
            cancel ->
                _ = ecai_index_jobs_srv:worker_canceled(JobId, Checkpoint),
                ok;
            continue ->
                prepare_and_run(Job, Checkpoint)
        end
    catch
        Class:Reason:Stacktrace ->
            _ = safe_worker_failed(
                JobId,
                {worker_exception, Class, Reason, Stacktrace}
            ),
            ok
    end.

prepare_and_run(Job, Checkpoint) ->
    JobId = maps:get(id, Job),
    Spec = maps:get(spec, Job),
    Kind = maps:get(kind, Spec),
    case ecai_index_job_adapter:module_for(Kind) of
        {ok, Adapter} ->
            case Adapter:prepare(Job) of
                {ok, Runtime, InitialProgress} ->
                    {ok, _} = ecai_index_jobs_srv:checkpoint(
                        JobId,
                        Checkpoint,
                        InitialProgress
                    ),
                    BatchSize = maps:get(batch_size, maps:get(options, Spec), 1),
                    run_loop(Job, Adapter, Runtime, Checkpoint, BatchSize);
                {error, Reason} ->
                    _ = ecai_index_jobs_srv:worker_failed(
                        JobId,
                        {adapter_prepare_failed, Reason}
                    ),
                    ok
            end;
        {error, Reason} ->
            _ = ecai_index_jobs_srv:worker_failed(
                JobId,
                {adapter_dispatch_failed, Reason}
            ),
            ok
    end.

run_loop(Job, Adapter, Runtime, Checkpoint, BatchSize) ->
    JobId = maps:get(id, Job),
    case ecai_index_jobs_srv:control(JobId) of
        pause ->
            _ = ecai_index_jobs_srv:worker_paused(JobId, Checkpoint),
            ok;
        cancel ->
            _ = ecai_index_jobs_srv:worker_canceled(JobId, Checkpoint),
            ok;
        continue ->
            case Adapter:run_batch(Job, Runtime, Checkpoint, BatchSize) of
                {continue, Runtime1, Checkpoint1, Progress} ->
                    {ok, _} = ecai_index_jobs_srv:checkpoint(
                        JobId,
                        Checkpoint1,
                        Progress
                    ),
                    run_loop(Job, Adapter, Runtime1, Checkpoint1, BatchSize);
                {complete, Runtime1, Checkpoint1, AdapterResult0} ->
                    case Adapter:result(Job, Runtime1, Checkpoint1, AdapterResult0) of
                        {ok, AdapterResult} ->
                            finish_job(Job, Checkpoint1, AdapterResult);
                        {error, Reason} ->
                            _ = ecai_index_jobs_srv:worker_failed(
                                JobId,
                                {adapter_result_failed, Reason}
                            ),
                            ok
                    end;
                {error, Reason} ->
                    _ = ecai_index_jobs_srv:worker_failed(
                        JobId,
                        {adapter_batch_failed, Reason}
                    ),
                    ok;
                Other ->
                    _ = ecai_index_jobs_srv:worker_failed(
                        JobId,
                        {invalid_adapter_return, Other}
                    ),
                    ok
            end
    end.

finish_job(Job, Checkpoint, AdapterResult) ->
    JobId = maps:get(id, Job),
    case ecai_index_jobs_srv:control(JobId) of
        pause ->
            _ = ecai_index_jobs_srv:worker_paused(JobId, Checkpoint),
            ok;
        cancel ->
            _ = ecai_index_jobs_srv:worker_canceled(JobId, Checkpoint),
            ok;
        continue ->
            case ecai_index_jobs_srv:begin_finalizing(JobId, AdapterResult) of
                {ok, _Ack} ->
                    finalize_artifact(Job, AdapterResult);
                {control, pause} ->
                    _ = ecai_index_jobs_srv:worker_paused(JobId, Checkpoint),
                    ok;
                {control, cancel} ->
                    _ = ecai_index_jobs_srv:worker_canceled(JobId, Checkpoint),
                    ok;
                {error, Reason} ->
                    _ = ecai_index_jobs_srv:worker_failed(
                        JobId,
                        {begin_finalizing_failed, Reason}
                    ),
                    ok
            end
    end.

finalize_artifact(Job, AdapterResult) ->
    JobId = maps:get(id, Job),
    case ecai_index_artifact:finalize(Job, AdapterResult) of
        {ok, Artifact} ->
            case maybe_activate_search(Job, AdapterResult, Artifact) of
                ok ->
                    _ = ecai_index_jobs_srv:artifact_ready(JobId, Artifact, AdapterResult),
                    ok;
                {error, Reason} ->
                    _ = ecai_index_jobs_srv:worker_failed(
                        JobId,
                        {search_activation_failed, Reason}
                    ),
                    ok
            end;
        {error, Reason} ->
            _ = ecai_index_jobs_srv:worker_failed(
                JobId,
                {artifact_finalize_failed, Reason}
            ),
            ok
    end.

maybe_activate_search(#{id := JobId, spec := #{kind := wikimedia_visibility}}, AdapterResult, Artifact) ->
    case maps:get(search_snapshot_path, AdapterResult, undefined) of
        Path when is_binary(Path), byte_size(Path) > 0 ->
            ecai_wikimedia_search_server:activate_snapshot(
                Path,
                maps:with([job_id, index_root, manifest_sha256, manifest_cid], #{
                    job_id => JobId,
                    index_root => maps:get(index_root, Artifact, undefined),
                    manifest_sha256 => maps:get(manifest_sha256, Artifact, undefined),
                    manifest_cid => maps:get(manifest_cid, Artifact, undefined)
                })
            );
        _ ->
            {error, search_snapshot_missing}
    end;
maybe_activate_search(_Job, _AdapterResult, _Artifact) ->
    ok.

safe_worker_failed(JobId, Reason) ->
    try ecai_index_jobs_srv:worker_failed(JobId, Reason) of
        Result -> Result
    catch
        _Class:_Failure -> ok
    end.
