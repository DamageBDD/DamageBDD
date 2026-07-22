%%%-------------------------------------------------------------------
%%% ecai_indexer compatibility facade.
%%%
%%% Legacy Yelp admin callers retain start/3, status/0 and cancel/0 while the
%%% actual work is executed by the durable ecai_index_jobs_srv queue.
%%%-------------------------------------------------------------------
-module(ecai_indexer).
-behaviour(gen_server).

-export([start_link/0, start/3, status/0, cancel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    last_job_id = undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start(Ctx, Paths, Limit) ->
    gen_server:call(?MODULE, {start, Ctx, Paths, Limit}, 30000).

status() ->
    gen_server:call(?MODULE, status, 30000).

cancel() ->
    gen_server:call(?MODULE, cancel, 30000).

init([]) ->
    {ok, #state{}}.

handle_call({start, _Ctx, Paths0, Limit0}, _From, State0) ->
    case active_legacy_job(State0) of
        {ok, _Job} ->
            {reply, {error, busy}, State0};
        not_found ->
            case normalize_request(Paths0, Limit0) of
                {ok, Paths, Limit} ->
                    Spec = #{
                        schema => <<"ecai-index-job/v1">>,
                        kind => yelp_ndjson,
                        owner => <<"legacy-yelp-admin">>,
                        source => #{paths => Paths},
                        target => #{mode => live_search},
                        options => #{
                            priority => 100,
                            max_retries => 3,
                            batch_size => 1,
                            limit_per_chunk => Limit
                        },
                        finalize => #{
                            build_nft_manifest => true,
                            publish_ipfs => false,
                            auto_mint => false
                        }
                    },
                    case safe_enqueue(Spec) of
                        {ok, Job} ->
                            JobId = maps:get(<<"id">>, Job),
                            {reply, {ok, JobId}, State0#state{last_job_id = JobId}};
                        {error, _Reason} = Error ->
                            {reply, Error, State0}
                    end;
                {error, _Reason} = Error ->
                    {reply, Error, State0}
            end
    end;
handle_call(status, _From, State0) ->
    case current_legacy_job(State0) of
        {ok, Job, State1} ->
            {reply, legacy_status(Job), State1};
        not_found ->
            {reply, idle_status(), State0}
    end;
handle_call(cancel, _From, State0) ->
    case current_legacy_job(State0) of
        {ok, Job, State1} ->
            JobId = maps:get(<<"id">>, Job),
            case safe_control(cancel, JobId) of
                {ok, _Updated} -> {reply, ok, State1};
                {error, _Reason} = Error -> {reply, Error, State1}
            end;
        not_found ->
            {reply, {error, nojob}, State0}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unhandled}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

active_legacy_job(State) ->
    case current_legacy_job(State) of
        {ok, Job, _State1} ->
            case is_active_state(maps:get(<<"state">>, Job)) of
                true -> {ok, Job};
                false -> not_found
            end;
        not_found -> not_found
    end.

current_legacy_job(State = #state{last_job_id = JobId}) when is_binary(JobId) ->
    case safe_get(JobId) of
        {ok, Job} -> {ok, Job, State};
        {error, _Reason} -> latest_legacy_job(State)
    end;
current_legacy_job(State) ->
    latest_legacy_job(State).

latest_legacy_job(State) ->
    try ecai_index_jobs_srv:list(#{
        kind => <<"yelp_ndjson">>,
        owner => <<"legacy-yelp-admin">>
    }) of
        {ok, [Job | _]} ->
            JobId = maps:get(<<"id">>, Job),
            {ok, Job, State#state{last_job_id = JobId}};
        {ok, []} -> not_found;
        _ -> not_found
    catch
        _Class:_Reason -> not_found
    end.

legacy_status(Job) ->
    Progress = map_or_empty(maps:get(<<"progress">>, Job, #{})),
    State = maps:get(<<"state">>, Job, <<"failed">>),
    #{
        status => legacy_state(State),
        job_id => maps:get(<<"id">>, Job),
        started_at => maps:get(<<"started_at_ms">>, Job, 0),
        finished_at => maps:get(<<"finished_at_ms">>, Job, 0),
        files_total => maps:get(<<"sources_total">>, Progress, maps:get(<<"total">>, Progress, 0)),
        files_done => maps:get(<<"sources_completed">>, Progress, maps:get(<<"completed">>, Progress, 0)),
        docs_done => maps:get(<<"records_indexed">>, Progress, 0),
        percent => maps:get(<<"percent">>, Progress, null),
        rate_per_second => maps:get(<<"rate_per_second">>, Progress, 0.0),
        eta_ms => maps:get(<<"eta_ms">>, Progress, null),
        phase => maps:get(<<"phase">>, Progress, State),
        error => maps:get(<<"error">>, Job, null)
    }.

legacy_state(<<"queued">>) -> running;
legacy_state(<<"preparing">>) -> running;
legacy_state(<<"running">>) -> running;
legacy_state(<<"pause_requested">>) -> running;
legacy_state(<<"paused">>) -> canceled;
legacy_state(<<"cancel_requested">>) -> running;
legacy_state(<<"canceled">>) -> canceled;
legacy_state(<<"finalizing">>) -> running;
legacy_state(<<"completed">>) -> done;
legacy_state(<<"ready_to_mint">>) -> done;
legacy_state(<<"minted">>) -> done;
legacy_state(<<"failed">>) -> error;
legacy_state(_) -> error.

idle_status() ->
    #{
        status => idle,
        job_id => undefined,
        started_at => 0,
        finished_at => 0,
        files_total => 0,
        files_done => 0,
        docs_done => 0,
        percent => 0.0,
        rate_per_second => 0.0,
        eta_ms => undefined,
        phase => idle,
        error => undefined
    }.

normalize_request(Paths0, Limit0) when is_list(Paths0) ->
    try
        Paths = [ecai_chunker:chunk_path(Path) || Path <- Paths0],
        case Paths of
            [] -> {error, empty_paths};
            _ -> {ok, Paths, normalize_limit(Limit0)}
        end
    catch
        error:badarg -> {error, badarg}
    end;
normalize_request(_Paths, _Limit) ->
    {error, badarg}.

normalize_limit(infinity) -> infinity;
normalize_limit(N) when is_integer(N), N > 0 -> N;
normalize_limit(_Other) -> erlang:error(badarg).

safe_enqueue(Spec) ->
    try ecai_index_jobs_srv:enqueue(Spec) of
        Result -> Result
    catch
        exit:Reason -> {error, {index_jobs_unavailable, Reason}}
    end.

safe_get(JobId) ->
    try ecai_index_jobs_srv:get(JobId) of
        Result -> Result
    catch
        exit:Reason -> {error, {index_jobs_unavailable, Reason}}
    end.

safe_control(cancel, JobId) ->
    try ecai_index_jobs_srv:cancel(JobId) of
        Result -> Result
    catch
        exit:Reason -> {error, {index_jobs_unavailable, Reason}}
    end.

is_active_state(<<"queued">>) -> true;
is_active_state(<<"preparing">>) -> true;
is_active_state(<<"running">>) -> true;
is_active_state(<<"pause_requested">>) -> true;
is_active_state(<<"cancel_requested">>) -> true;
is_active_state(<<"finalizing">>) -> true;
is_active_state(_) -> false.

map_or_empty(Map) when is_map(Map) -> Map;
map_or_empty(_Other) -> #{}.
