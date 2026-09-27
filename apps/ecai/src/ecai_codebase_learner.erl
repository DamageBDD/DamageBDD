-module(ecai_codebase_learner).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    learn_now/0,
    module_changed/2,
    status/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 300000).
-define(STATUS_TABLE, ecai_codebase_learner_status).
-define(STATUS_KEY, status).

-record(state, {
    apps = ?APPS,
    queue = [],
    current = undefined,
    phase = idle,
    total = 0,
    completed = 0,
    cycle = 0,
    interval_ms = ?DEFAULT_INTERVAL,
    changed_apps = #{},
    last_started_at = undefined,
    last_completed_at = undefined,
    last_error = undefined,
    opts = #{}
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
learn_now() -> gen_server:cast(?SERVER, learn_now).
module_changed(App, Module) -> gen_server:cast(?SERVER, {module_changed, App, Module}).
status() ->
    status_snapshot().

init(Opts) ->
    Interval = maps:get(interval_ms, Opts,
        application:get_env(ecai, code_learning_interval_ms, ?DEFAULT_INTERVAL)),
    ok = init_status_table(),
    State = #state{interval_ms = Interval, opts = Opts},
    ok = publish_status(State),
    self() ! start_cycle,
    {ok, State}.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Request, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(learn_now, State) ->
    self() ! start_cycle,
    State1 = State#state{queue = [], current = undefined, phase = queued, total = 0, completed = 0},
    ok = publish_status(State1),
    {noreply, State1};
handle_cast({module_changed, App, Module}, State) ->
    case lists:member(App, State#state.apps) andalso is_atom(Module) of
        true ->
            self() ! learn_next,
            Queue = [{module, App, Module} | State#state.queue],
            State1 = State#state{queue = Queue, total = State#state.total + 1},
            ok = publish_status(State1),
            {noreply, State1};
        false ->
            {noreply, State}
    end;
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(start_cycle, State0) ->
    {Queue, Errors} = build_queue(State0#state.apps, State0#state.opts),
    State1 = State0#state{
        queue = Queue,
        current = undefined,
        phase = queued,
        total = length(Queue),
        completed = 0,
        cycle = State0#state.cycle + 1,
        changed_apps = #{},
        last_started_at = now_iso8601(),
        last_error = case Errors of [] -> undefined; _ -> Errors end
    },
    ok = publish_status(State1),
    self() ! learn_next,
    {noreply, State1};
handle_info(learn_next, State = #state{queue = []}) ->
    Finalizing = State#state{phase = finalizing, current = finalizing},
    ok = publish_status(Finalizing),
    State1 = finish_cycle(Finalizing),
    State2 = State1#state{phase = idle, current = undefined},
    ok = publish_status(State2),
    erlang:send_after(State2#state.interval_ms, self(), start_cycle),
    {noreply, State2};
handle_info(learn_next, State0 = #state{queue = [Entry | Rest]}) ->
    State1 = State0#state{queue = Rest, current = Entry, phase = learning},
    ok = publish_status(State1),
    State2 = case safe_learn_entry(Entry, State1) of
        {ok, App, _Module, unchanged} ->
            State1#state{last_error = undefined};
        {ok, App, _Module, changed} ->
            State1#state{
                changed_apps = (State1#state.changed_apps)#{App => true},
                last_error = undefined
            };
        {error, Reason} ->
            logger:error("ECAI code learning failed entry=~p reason=~p", [Entry, Reason]),
            State1#state{last_error = {Entry, Reason}}
    end,
    State3 = State2#state{
        current = undefined,
        completed = min(State2#state.completed + 1, State2#state.total)
    },
    ok = publish_status(State3),
    self() ! learn_next,
    {noreply, State3};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

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
    Progress = case Total of
        0 -> 0.0;
        _ -> (Completed * 100.0) / Total
    end,
    #{
        cycle => State#state.cycle,
        phase => State#state.phase,
        current => State#state.current,
        completed => Completed,
        total => Total,
        progress_percent => Progress,
        queued => length(State#state.queue),
        changed_apps => maps:keys(State#state.changed_apps),
        last_started_at => State#state.last_started_at,
        last_completed_at => State#state.last_completed_at,
        last_error => State#state.last_error
    }.

build_queue(Apps, Opts) ->
    RepoRoot = filename:absname(path_to_list(maps:get(repo_root, Opts,
        application:get_env(ecai, code_repo_root, ".")))),
    lists:foldl(
        fun(App, {Queue, Errors}) ->
            case ecai_code_analyser:repo_source_files(App, RepoRoot) of
                {ok, Files} ->
                    {Queue ++ [{file, App, Path} || Path <- Files], Errors};
                {error, RepoReason} ->
                    case ecai_code_analyser:application_modules(App) of
                        {ok, Modules} ->
                            {Queue ++ [{module, App, M} || M <- Modules],
                             [{App, {repo_fallback, RepoReason}} | Errors]};
                        {error, RuntimeReason} ->
                            {Queue, [{App, {RepoReason, RuntimeReason}} | Errors]}
                    end
            end
        end,
        {[], []}, Apps).

safe_learn_entry(Entry, State) ->
    try learn_entry(Entry, State) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            {error, {learn_entry_exception, Class, Reason, Stack}}
    end.

learn_entry({module, App, Module}, State) ->
    case ecai_code_analyser:analyse_module(App, Module) of
        {ok, Analysis} -> learn_analysis(App, Analysis, State);
        {error, _} = Error -> Error
    end;
learn_entry({file, App, Path}, State) ->
    case ecai_code_analyser:analyse_file(App, Path) of
        {ok, Analysis} -> learn_analysis(App, Analysis, State);
        {error, _} = Error -> Error
    end.

learn_analysis(App, Analysis, State) ->
    Module = maps:get(module, Analysis),
    Prev = ecai_learning_store:get_analysis(App, Module),
    AnalysisChanged = analysis_changed(Prev, Analysis),
    CardCurrent = module_card_current(App, Module, Analysis),
    ok = ecai_learning_store:put_analysis(App, Module, Analysis),
    case AnalysisChanged orelse (not CardCurrent) of
        false -> {ok, App, Module, unchanged};
        true ->
            case ecai_code_knowledge:learn_module(App, Analysis, ollama_opts(State)) of
                {ok, Card} ->
                    ok = ecai_learning_store:put_module_knowledge(App, Module, Card),
                    {ok, App, Module, changed};
                {error, Reason} ->
                    {error, {knowledge_card_failed, App, Module, Reason}}
            end
    end.

module_card_current(App, Module, Analysis) ->
    Hash = maps:get(source_sha256, Analysis, undefined),
    case ecai_learning_store:get_module_knowledge(App, Module) of
        not_found -> false;
        {ok, Card} -> mget(<<"source_sha256">>, Card, undefined) =:= Hash
    end.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

analysis_changed(not_found, _Analysis) -> true;
analysis_changed({ok, Previous}, Analysis) ->
    maps:get(source_sha256, Previous, undefined) =/= maps:get(source_sha256, Analysis, undefined).

finish_cycle(State0) ->
    lists:foreach(fun(App) -> refresh_application(App, State0) end, State0#state.apps),
    refresh_global(State0),
    _ = ecai_learning_snapshot:write(State0#state.opts),
    State0#state{current = undefined, last_completed_at = now_iso8601()}.

refresh_application(App, State) ->
    Analyses = ecai_learning_store:analyses(App),
    case Analyses of
        [] -> ok;
        _ ->
            Graph = ecai_code_graph:build(Analyses),
            ok = ecai_learning_store:put_graph(App, Graph),
            NeedSummary = maps:is_key(App, State#state.changed_apps) orelse
                          (ecai_learning_store:get_app_knowledge(App) =:= not_found),
            case NeedSummary of
                false -> ok;
                true ->
                    Cards = ecai_learning_store:module_knowledge(App),
                    case Cards of
                        [] -> ok;
                        _ ->
                            case ecai_code_knowledge:synthesize_application(
                                App, Cards, ecai_code_graph:summary(Graph), ollama_opts(State)) of
                                {ok, Card} -> ecai_learning_store:put_app_knowledge(App, Card);
                                {error, Reason} ->
                                    logger:error("ECAI application synthesis failed app=~p reason=~p",
                                                 [App, Reason]),
                                    ok
                            end
                    end
            end
    end.

refresh_global(State) ->
    NeedGlobal = (maps:size(State#state.changed_apps) > 0) orelse
                 (ecai_learning_store:get_global_knowledge() =:= not_found),
    case NeedGlobal of
        false -> ok;
        true ->
            AppCards = lists:foldl(fun(App, Acc) ->
                case ecai_learning_store:get_app_knowledge(App) of
                    {ok, Card} -> Acc#{App => Card};
                    not_found -> Acc
                end
            end, #{}, State#state.apps),
            case maps:size(AppCards) of
                0 -> ok;
                _ ->
                    case ecai_code_knowledge:synthesize_global(AppCards, ollama_opts(State)) of
                        {ok, Card} -> ecai_learning_store:put_global_knowledge(Card);
                        {error, Reason} ->
                            logger:error("ECAI global code synthesis failed reason=~p", [Reason]),
                            ok
                    end
            end
    end.

ollama_opts(State) ->
    maps:get(ollama, State#state.opts, #{}).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P).

now_iso8601() ->
    unicode:characters_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).
