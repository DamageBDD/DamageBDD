-module(ecai_content_manager).
-behaviour(gen_server).

-export([start_link/0, start_link/1, generate/0, generate/1, run/0, run/1,
         publish/1, resume/0, retry/1, learning_updated/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {running = #{}, retry_interval_ms = 60000}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
generate() -> generate(#{}).
generate(Scope) when is_map(Scope) -> gen_server:call(?SERVER, {enqueue, Scope, false}, infinity).
run() -> run(#{}).
run(Scope) when is_map(Scope) -> gen_server:call(?SERVER, {enqueue, Scope, true}, infinity).
publish(JobId) -> gen_server:call(?SERVER, {publish, ecai_content_util:to_binary(JobId)}, infinity).
resume() -> gen_server:call(?SERVER, resume, infinity).
retry(JobId) -> gen_server:call(?SERVER, {retry, ecai_content_util:to_binary(JobId)}, infinity).
learning_updated() -> gen_server:cast(?SERVER, learning_updated).
status() -> gen_server:call(?SERVER, status).

init(_Opts) ->
    process_flag(trap_exit, true),
    Retry = application:get_env(ecai, content_retry_interval_ms, 60000),
    erlang:send_after(0, self(), resume_pending),
    erlang:send_after(Retry, self(), retry_tick),
    {ok, #state{retry_interval_ms = Retry}}.

handle_call(status, _From, State) ->
    Jobs = ecai_content_store:jobs(),
    Counts = lists:foldl(fun(Job, Acc) ->
        S = maps:get(status, Job, unknown),
        maps:update_with(S, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, Jobs),
    {reply, #{running => maps:keys(State#state.running), counts => Counts,
              total_jobs => length(Jobs)}, State};
handle_call({enqueue, Scope, Publish}, _From, State0) ->
    case create_or_reuse_job(Scope, Publish) of
        {ok, Job} ->
            State1 = maybe_start(Job, State0),
            {reply, {ok, Job}, State1};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({publish, JobId}, _From, State0) ->
    case ecai_content_store:update_job(JobId, #{publish_requested => true, status => queued}) of
        {ok, Job} -> {reply, {ok, Job}, maybe_start(Job, State0)};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({retry, JobId}, _From, State0) ->
    case ecai_content_store:update_job(JobId, #{status => queued, last_error => undefined}) of
        {ok, Job} -> {reply, {ok, Job}, maybe_start(Job, State0)};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call(resume, _From, State0) ->
    State1 = resume_jobs(State0),
    {reply, ok, State1};
handle_call(_Other, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(learning_updated, State0) ->
    case application:get_env(ecai, content_auto_generate, false) of
        true ->
            Publish = application:get_env(ecai, content_auto_publish, false),
            case create_or_reuse_job(#{}, Publish) of
                {ok, Job} -> {noreply, maybe_start(Job, State0)};
                {error, Reason} ->
                    logger:error("ECAI content auto-generation enqueue failed reason=~p", [Reason]),
                    {noreply, State0}
            end;
        false -> {noreply, State0}
    end;
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(resume_pending, State) -> {noreply, resume_jobs(State)};
handle_info(retry_tick, State0) ->
    State1 = resume_jobs(State0),
    erlang:send_after(State1#state.retry_interval_ms, self(), retry_tick),
    {noreply, State1};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State0) ->
    Running1 = maps:filter(fun(_JobId, V) -> maps:get(ref, V) =/= Ref end, State0#state.running),
    {noreply, State0#state{running = Running1}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

create_or_reuse_job(Scope, Publish) ->
    case ecai_content_evidence:build(Scope) of
        {ok, Evidence} ->
            SnapshotId = ecai_content_util:to_binary(maps:get(snapshot_id, Evidence)),
            ScopeNorm = maps:get(scope, Evidence, #{}),
            JobId = ecai_content_util:sha256_hex(term_to_binary(
                {SnapshotId, ScopeNorm, 1}, [deterministic])),
            case ecai_content_store:get_job(JobId) of
                {ok, Existing} ->
                    case Publish andalso not maps:get(publish_requested, Existing, false) of
                        true -> ecai_content_store:update_job(JobId, #{publish_requested => true, status => queued});
                        false -> {ok, Existing}
                    end;
                not_found ->
                    Now = ecai_content_util:now_iso8601(),
                    Job = #{
                        id => JobId,
                        schema_version => 1,
                        stage => evidence_ready,
                        status => queued,
                        scope => ScopeNorm,
                        snapshot_id => SnapshotId,
                        evidence_sha256 => maps:get(evidence_sha256, Evidence),
                        evidence => Evidence,
                        publish_requested => Publish,
                        retry_count => 0,
                        options => #{},
                        created_at => Now,
                        updated_at => Now
                    },
                    case write_evidence(JobId, Evidence) of
                        ok -> ecai_content_store:put_job(Job);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

write_evidence(JobId, Evidence) ->
    case ecai_content_store:artifact_path(JobId, <<"evidence.json">>) of
        {ok, Path} -> ecai_content_util:atomic_write(Path,
            jsx:encode(ecai_content_util:json_safe(Evidence)));
        {error, _} = Error -> Error
    end.

resume_jobs(State0) ->
    lists:foldl(fun(Job, State) -> maybe_start(Job, State) end,
                State0, ecai_content_store:resumable_jobs()).

maybe_start(Job, State = #state{running = Running}) ->
    JobId = maps:get(id, Job),
    Status = maps:get(status, Job, queued),
    Terminal = lists:member(Status, [awaiting_publish, complete, cancelled, manual_reconcile]),
    case maps:is_key(JobId, Running) orelse Terminal of
        true -> State;
        false ->
            {Pid, Ref} = spawn_monitor(fun() -> ecai_content_worker:run(JobId) end),
            State#state{running = Running#{JobId => #{pid => Pid, ref => Ref}}}
    end.
