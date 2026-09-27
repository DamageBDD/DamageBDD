-module(ecai_codebase_learner).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    learn_now/0,
    module_changed/2,
    status/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 300000).
-define(STATUS_TABLE, ecai_codebase_learner_status).
-define(STATUS_KEY, status).

-record(state, {
    apps = ?APPS,
    queue = [],
    inflight = #{},
    phase = idle,
    total = 0,
    completed = 0,
    cycle = 0,
    interval_ms = ?DEFAULT_INTERVAL,
    max_parallel = 1,
    changed_apps = #{},
    last_started_at = undefined,
    last_completed_at = undefined,
    last_error = undefined,
    refresh_requested = false,
    ready = false,
    timer_ref = undefined,
    opts = #{}
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
learn_now() -> gen_server:cast(?SERVER, learn_now).
module_changed(App, Module) -> gen_server:cast(?SERVER, {module_changed, App, Module}).
status() -> status_snapshot().

init(Opts) ->
    Interval = maps:get(
        interval_ms,
        Opts,
        application:get_env(ecai, code_learning_interval_ms, ?DEFAULT_INTERVAL)
    ),
    MaxParallel = resolve_parallelism(Opts),
    ok = init_status_table(),
    State = #state{
        interval_ms = Interval,
        max_parallel = MaxParallel,
        opts = Opts
    },
    ok = publish_status(State),
    self() ! start_cycle,
    {ok, State}.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(learn_now, State0 = #state{phase = idle}) ->
    State1 = (cancel_cycle_timer(State0))#state{refresh_requested = false, ready = false},
    self() ! start_cycle,
    ok = publish_status(State1),
    {noreply, State1};
handle_cast(learn_now, State0) ->
    State1 = State0#state{refresh_requested = true},
    ok = publish_status(State1),
    {noreply, State1};
handle_cast({module_changed, App, Module}, State0) ->
    case lists:member(App, State0#state.apps) andalso is_atom(Module) of
        false ->
            {noreply, State0};
        true ->
            enqueue_module_change(App, Module, State0)
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_cycle, State0 = #state{phase = idle}) ->
    StateA = cancel_cycle_timer(State0),
    {Queue, Errors} = build_queue(StateA#state.apps, StateA#state.opts),
    State1 = StateA#state{
        queue = Queue,
        inflight = #{},
        phase = queued,
        total = length(Queue),
        completed = 0,
        cycle = StateA#state.cycle + 1,
        changed_apps = #{},
        last_started_at = now_iso8601(),
        last_error = case Errors of [] -> undefined; _ -> Errors end,
        refresh_requested = false,
        ready = false
    },
    State2 = dispatch(State1),
    ok = publish_status(State2),
    {noreply, maybe_finalize(State2)};
handle_info(start_cycle, State0) ->
    State1 = State0#state{refresh_requested = true},
    ok = publish_status(State1),
    {noreply, State1};

handle_info({learn_result, TaskRef, Result}, State0) ->
    case maps:take(TaskRef, State0#state.inflight) of
        error ->
            {noreply, State0};
        {Task, Inflight1} ->
            _ = erlang:demonitor(maps:get(mref, Task), [flush]),
            Entry = maps:get(entry, Task),
            State1 = apply_learning_result(Entry, Result, State0#state{inflight = Inflight1}),
            State2 = State1#state{completed = min(State1#state.completed + 1, State1#state.total)},
            State3 = dispatch(State2),
            ok = publish_status(State3),
            {noreply, maybe_finalize(State3)}
    end;

handle_info({'DOWN', MRef, process, _Pid, Reason}, State0) ->
    case take_task_by_monitor(MRef, State0#state.inflight) of
        not_found ->
            {noreply, State0};
        {ok, TaskRef, Task, Inflight1} ->
            Entry = maps:get(entry, Task),
            Error = {learning_worker_down, Reason},
            logger:error("ECAI code learning worker failed entry=~p reason=~p", [Entry, Reason]),
            State1 = State0#state{
                inflight = Inflight1,
                completed = min(State0#state.completed + 1, State0#state.total),
                last_error = {Entry, Error}
            },
            _ = TaskRef,
            State2 = dispatch(State1),
            ok = publish_status(State2),
            {noreply, maybe_finalize(State2)}
    end;

handle_info(finalize_cycle, State0 = #state{queue = [], inflight = Inflight})
  when map_size(Inflight) =:= 0 ->
    Finalizing = State0#state{phase = finalizing},
    ok = publish_status(Finalizing),
    State1 = finish_cycle(Finalizing),
    State2 = State1#state{phase = idle},
    State3 =
        case State2#state.refresh_requested of
            true ->
                self() ! start_cycle,
                State2#state{refresh_requested = false};
            false ->
                schedule_next_cycle(State2)
        end,
    ok = publish_status(State3),
    {noreply, State3};
handle_info(finalize_cycle, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cancel_cycle_timer(State),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

enqueue_module_change(App, Module, State0 = #state{phase = idle}) ->
    Entry = {module, App, Module},
    StateA = cancel_cycle_timer(State0),
    State1 = StateA#state{
        queue = [Entry],
        inflight = #{},
        phase = queued,
        total = 1,
        completed = 0,
        cycle = StateA#state.cycle + 1,
        changed_apps = #{},
        last_started_at = now_iso8601(),
        last_error = undefined,
        refresh_requested = false,
        ready = false
    },
    State2 = dispatch(State1),
    ok = publish_status(State2),
    {noreply, maybe_finalize(State2)};
enqueue_module_change(App, Module, State0 = #state{phase = Phase})
  when Phase =:= learning; Phase =:= queued ->
    Entry = {module, App, Module},
    case entry_pending(Entry, State0) of
        true ->
            {noreply, State0};
        false ->
            State1 = State0#state{
                queue = State0#state.queue ++ [Entry],
                total = State0#state.total + 1
            },
            State2 = dispatch(State1),
            ok = publish_status(State2),
            {noreply, State2}
    end;
enqueue_module_change(_App, _Module, State0 = #state{phase = finalizing}) ->
    State1 = State0#state{refresh_requested = true},
    ok = publish_status(State1),
    {noreply, State1}.

entry_pending(Entry, State) ->
    lists:member(Entry, State#state.queue) orelse
        lists:any(
            fun(Task) -> maps:get(entry, Task, undefined) =:= Entry end,
            maps:values(State#state.inflight)
        ).

dispatch(State0) ->
    case can_dispatch(State0) of
        false ->
            normalize_phase(State0);
        true ->
            [Entry | Rest] = State0#state.queue,
            TaskRef = make_ref(),
            Parent = self(),
            Opts = State0#state.opts,
            {Pid, MRef} = spawn_monitor(fun() ->
                Result = safe_learn_entry(Entry, Opts),
                Parent ! {learn_result, TaskRef, Result}
            end),
            Task = #{entry => Entry, pid => Pid, mref => MRef},
            Inflight = (State0#state.inflight)#{TaskRef => Task},
            dispatch(State0#state{queue = Rest, inflight = Inflight, phase = learning})
    end.

can_dispatch(State) ->
    State#state.queue =/= [] andalso
        map_size(State#state.inflight) < State#state.max_parallel.

normalize_phase(State = #state{queue = [], inflight = Inflight}) when map_size(Inflight) =:= 0 ->
    State;
normalize_phase(State = #state{inflight = Inflight}) when map_size(Inflight) > 0 ->
    State#state{phase = learning};
normalize_phase(State) ->
    State#state{phase = queued}.

maybe_finalize(State = #state{queue = [], inflight = Inflight}) when map_size(Inflight) =:= 0 ->
    self() ! finalize_cycle,
    State;
maybe_finalize(State) ->
    State.

apply_learning_result(_Entry, {ok, _App, _Module, unchanged}, State) ->
    State#state{last_error = undefined};
apply_learning_result(_Entry, {ok, App, _Module, changed}, State) ->
    State#state{
        changed_apps = (State#state.changed_apps)#{App => true},
        last_error = undefined
    };
apply_learning_result(Entry, {error, Reason}, State) ->
    logger:error("ECAI code learning failed entry=~p reason=~p", [Entry, Reason]),
    State#state{last_error = {Entry, Reason}}.

take_task_by_monitor(MRef, Inflight) ->
    case [
        {TaskRef, Task}
     || {TaskRef, Task} <- maps:to_list(Inflight),
        maps:get(mref, Task, undefined) =:= MRef
    ] of
        [{TaskRef, Task}] -> {ok, TaskRef, Task, maps:remove(TaskRef, Inflight)};
        _ -> not_found
    end.

status_snapshot() ->
    case ets:whereis(?STATUS_TABLE) of
        undefined ->
            case whereis(?SERVER) of
                undefined -> {error, not_started};
                _Pid -> {error, status_unavailable}
            end;
        _Tid ->
            case ets:lookup(?STATUS_TABLE, ?STATUS_KEY) of
                [{?STATUS_KEY, Status}] -> Status;
                [] -> {error, status_unavailable}
            end
    end.

init_status_table() ->
    case ets:whereis(?STATUS_TABLE) of
        undefined ->
            _ = ets:new(?STATUS_TABLE, [
                named_table,
                set,
                protected,
                {read_concurrency, true}
            ]),
            ok;
        _Tid ->
            ok
    end.

publish_status(State) ->
    case ets:whereis(?STATUS_TABLE) of
        undefined -> ok;
        _Tid ->
            true = ets:insert(?STATUS_TABLE, {?STATUS_KEY, status_map(State)}),
            ok
    end.

status_map(State) ->
    Total = State#state.total,
    Completed = State#state.completed,
    Progress =
        case Total of
            0 -> 0.0;
            _ -> (Completed * 100.0) / Total
        end,
    Inflight = [
        maps:get(entry, Task)
     || {_Ref, Task} <- lists:sort(maps:to_list(State#state.inflight))
    ],
    #{
        cycle => State#state.cycle,
        phase => State#state.phase,
        current => case Inflight of [One] -> One; _ -> undefined end,
        inflight => Inflight,
        inflight_count => length(Inflight),
        max_parallel => State#state.max_parallel,
        completed => Completed,
        total => Total,
        progress_percent => Progress,
        queued => length(State#state.queue),
        changed_apps => maps:keys(State#state.changed_apps),
        refresh_requested => State#state.refresh_requested,
        ready => State#state.ready,
        last_started_at => State#state.last_started_at,
        last_completed_at => State#state.last_completed_at,
        last_error => State#state.last_error
    }.

build_queue(Apps, Opts) ->
    RepoRoot = filename:absname(path_to_list(maps:get(
        repo_root,
        Opts,
        application:get_env(ecai, code_repo_root, ".")
    ))),
    lists:foldl(
        fun(App, {Queue, Errors}) ->
            case ecai_code_analyser:repo_source_files(App, RepoRoot) of
                {ok, Files} ->
                    {Queue ++ [{file, App, Path} || Path <- Files], Errors};
                {error, RepoReason} ->
                    case ecai_code_analyser:application_modules(App) of
                        {ok, Modules} ->
                            {
                                Queue ++ [{module, App, M} || M <- Modules],
                                [{App, {repo_fallback, RepoReason}} | Errors]
                            };
                        {error, RuntimeReason} ->
                            {Queue, [{App, {RepoReason, RuntimeReason}} | Errors]}
                    end
            end
        end,
        {[], []},
        Apps
    ).

safe_learn_entry(Entry, Opts) ->
    try learn_entry(Entry, Opts) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            {error, {learn_entry_exception, Class, Reason, Stack}}
    end.

learn_entry({module, App, Module}, Opts) ->
    case ecai_code_analyser:analyse_module(App, Module) of
        {ok, Analysis} -> learn_analysis(App, Analysis, Opts);
        {error, _} = Error -> Error
    end;
learn_entry({file, App, Path}, Opts) ->
    case ecai_code_analyser:analyse_file(App, Path) of
        {ok, Analysis} -> learn_analysis(App, Analysis, Opts);
        {error, _} = Error -> Error
    end.

learn_analysis(App, Analysis, Opts) ->
    Module = maps:get(module, Analysis),
    Prev = ecai_learning_store:get_analysis(App, Module),
    AnalysisChanged = analysis_changed(Prev, Analysis),
    CardCurrent = module_card_current(App, Module, Analysis, Opts),
    ok = ecai_learning_store:put_analysis(App, Module, Analysis),
    case AnalysisChanged orelse (not CardCurrent) of
        false ->
            {ok, App, Module, unchanged};
        true ->
            case ecai_code_knowledge:learn_module(App, Analysis, ollama_opts(Opts)) of
                {ok, Card} ->
                    ok = ecai_learning_store:put_module_knowledge(App, Module, Card),
                    {ok, App, Module, changed};
                {error, Reason} ->
                    {error, {knowledge_card_failed, App, Module, Reason}}
            end
    end.

module_card_current(App, Module, Analysis, Opts) ->
    Hash = maps:get(source_sha256, Analysis, undefined),
    RequestOpts = ollama_opts(Opts),
    RequestedModel = optional_binary(maps:get(model, RequestOpts, undefined)),
    RequestedProvider = requested_provider(maps:get(provider, RequestOpts, any)),
    case ecai_learning_store:get_module_knowledge(App, Module) of
        not_found ->
            false;
        {ok, Card} ->
            Inference = mget(<<"inference">>, Card, #{}),
            CardProvider = inference_provider(mget(<<"provider">>, Inference, <<"ollama">>)),
            CardModel = to_binary(mget(<<"model">>, Inference, mget(<<"model">>, Card, undefined))),
            CardDigest = to_binary(mget(<<"model_digest">>, Inference, <<>>)),
            SourceCurrent = mget(<<"source_sha256">>, Card, undefined) =:= Hash,
            ProviderCurrent = RequestedProvider =:= any orelse RequestedProvider =:= CardProvider,
            ModelCurrent = RequestedModel =:= undefined orelse RequestedModel =:= CardModel,
            SourceCurrent andalso ProviderCurrent andalso ModelCurrent andalso
                inference_identity_current(CardProvider, CardModel, CardDigest)
    end.

inference_identity_current(Provider, Model, Digest) ->
    case catch ecai_ollama_pool:inference_available(learning, Provider, Model, Digest) of
        true -> true;
        false -> false;
        _ -> true
    end.

requested_provider(any) -> any;
requested_provider(undefined) -> any;
requested_provider(Value) -> inference_provider(Value).

inference_provider(openai) -> openai;
inference_provider(ollama) -> ollama;
inference_provider(<<"openai">>) -> openai;
inference_provider(<<"ollama">>) -> ollama;
inference_provider("openai") -> openai;
inference_provider("ollama") -> ollama;
inference_provider(_) -> ollama.

optional_binary(undefined) -> undefined;
optional_binary(<<>>) -> undefined;
optional_binary(Value) -> to_binary(Value).

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) -> Default.

analysis_changed(not_found, _Analysis) -> true;
analysis_changed({ok, Previous}, Analysis) ->
    maps:get(source_sha256, Previous, undefined) =/=
        maps:get(source_sha256, Analysis, undefined).

finish_cycle(State0) ->
    AppResults = [{App, refresh_application(App, State0)} || App <- State0#state.apps],
    AppErrors = [{App, Reason} || {App, {error, Reason}} <- AppResults],
    GlobalResult = case AppErrors of
        [] -> refresh_global(State0);
        _ -> {error, {application_synthesis_failed, AppErrors}}
    end,
    _ = ecai_learning_snapshot:write(State0#state.opts),
    case GlobalResult of
        ok ->
            State0#state{ready = true, last_completed_at = now_iso8601()};
        {error, Reason} ->
            State0#state{
                ready = false,
                last_error = {finalization_failed, Reason},
                last_completed_at = now_iso8601()
            }
    end.

refresh_application(App, State) ->
    Analyses = ecai_learning_store:analyses(App),
    case Analyses of
        [] ->
            ok;
        _ ->
            Graph = ecai_code_graph:build(Analyses),
            ok = ecai_learning_store:put_graph(App, Graph),
            NeedSummary =
                maps:is_key(App, State#state.changed_apps) orelse
                    (ecai_learning_store:get_app_knowledge(App) =:= not_found),
            case NeedSummary of
                false ->
                    ok;
                true ->
                    Cards = ecai_learning_store:module_knowledge(App),
                    case Cards of
                        [] ->
                            ok;
                        _ ->
                            case ecai_code_knowledge:synthesize_application(
                                App,
                                Cards,
                                ecai_code_graph:summary(Graph),
                                ollama_opts(State#state.opts)
                            ) of
                                {ok, Card} -> ecai_learning_store:put_app_knowledge(App, Card);
                                {error, Reason} ->
                                    logger:error(
                                        "ECAI application synthesis failed app=~p reason=~p",
                                        [App, Reason]
                                    ),
                                    {error, Reason}
                            end
                    end
            end
    end.

refresh_global(State) ->
    NeedGlobal =
        (maps:size(State#state.changed_apps) > 0) orelse
            (ecai_learning_store:get_global_knowledge() =:= not_found),
    case NeedGlobal of
        false ->
            ok;
        true ->
            AppCards = lists:foldl(
                fun(App, Acc) ->
                    case ecai_learning_store:get_app_knowledge(App) of
                        {ok, Card} -> Acc#{App => Card};
                        not_found -> Acc
                    end
                end,
                #{},
                State#state.apps
            ),
            case maps:size(AppCards) =:= length(State#state.apps) of
                false ->
                    logger:warning(
                        "ECAI global synthesis deferred: application cards incomplete have=~p need=~p",
                        [maps:keys(AppCards), State#state.apps]
                    ),
                    {error, {application_cards_incomplete, maps:keys(AppCards)}};
                true ->
                    case ecai_code_knowledge:synthesize_global(
                        AppCards, ollama_opts(State#state.opts)
                    ) of
                        {ok, Card} -> ecai_learning_store:put_global_knowledge(Card);
                        {error, Reason} ->
                            logger:error("ECAI global code synthesis failed reason=~p", [Reason]),
                            {error, Reason}
                    end
            end
    end.

resolve_parallelism(Opts) ->
    Requested = maps:get(
        max_parallel,
        Opts,
        application:get_env(ecai, code_learning_parallelism, auto)
    ),
    case Requested of
        auto ->
            case catch ecai_ollama_pool:capacity(learning) of
                N when is_integer(N), N > 0 -> N;
                _ -> 1
            end;
        N when is_integer(N), N > 0 -> N;
        _ -> 1
    end.

ollama_opts(Opts) ->
    maps:get(ollama, Opts, #{}).

schedule_next_cycle(State0) ->
    TRef = erlang:send_after(State0#state.interval_ms, self(), start_cycle),
    State0#state{timer_ref = TRef}.

cancel_cycle_timer(State = #state{timer_ref = undefined}) -> State;
cancel_cycle_timer(State = #state{timer_ref = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{timer_ref = undefined}.

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P).

to_binary(undefined) -> <<>>;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

now_iso8601() ->
    unicode:characters_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).
