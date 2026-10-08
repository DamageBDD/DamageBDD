-module(ecai_learning_store).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    stop/0,
    status/0,
    put_analysis/3,
    get_analysis/2,
    analyses/1,
    put_graph/2,
    get_graph/1,
    put_relations/2,
    get_relations/1,
    relation_keys/1,
    put_relation_benchmark/2,
    get_relation_benchmark/1,
    put_module_knowledge/3,
    get_module_knowledge/2,
    module_knowledge/1,
    put_app_knowledge/2,
    get_app_knowledge/1,
    put_global_knowledge/1,
    get_global_knowledge/0,
    put_repair/3,
    compare_and_put_repair/4,
    get_repair/2,
    repairs/0,
    repairs/1,
    put_log_incident/2,
    get_log_incident/1,
    log_incidents/0,
    log_incidents/1,
    log_incidents/2,
    put_checkpoint/2,
    get_checkpoint/1,
    delete_checkpoint/1,
    events/2,
    events/3,
    snapshot_data/0
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
-define(TABLE, ecai_code_learning_dets).
-define(DEFAULT_EVENT_LIMIT, 100).

-ifdef(TEST).
-export([collect_repairs/2, collect_log_incidents/2, build_snapshot_data/1]).
-endif.

-record(state, {tab, state_root, file, event_seq = 0}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
stop() -> gen_server:call(?SERVER, stop).
status() -> gen_server:call(?SERVER, status).

put_analysis(App, Module, Analysis) ->
    gen_server:call(?SERVER, {put, {analysis, App, Module}, Analysis}, infinity).
get_analysis(App, Module) ->
    gen_server:call(?SERVER, {get, {analysis, App, Module}}).
analyses(App) ->
    gen_server:call(?SERVER, {select_prefix, analysis, App}, infinity).

put_graph(App, Graph) -> gen_server:call(?SERVER, {put, {graph, App}, Graph}, infinity).
get_graph(App) -> gen_server:call(?SERVER, {get, {graph, App}}).

put_relations(Scope, Relations) when is_atom(Scope), is_list(Relations) ->
    Deduped = ecai_relation:dedupe(Relations),
    Keys = [ecai_relation:key(Relation) || Relation <- Deduped],
    gen_server:call(?SERVER, {put_relations, Scope, Deduped, Keys}, infinity).
get_relations(Scope) when is_atom(Scope) ->
    gen_server:call(?SERVER, {get, {relations, Scope}}, infinity).
relation_keys(Scope) when is_atom(Scope) ->
    gen_server:call(?SERVER, {get, {relation_keys, Scope}}, infinity).

put_relation_benchmark(Scope, Benchmark) when is_atom(Scope), is_map(Benchmark) ->
    gen_server:call(?SERVER, {put, {relation_benchmark, Scope}, Benchmark}, infinity).
get_relation_benchmark(Scope) when is_atom(Scope) ->
    gen_server:call(?SERVER, {get, {relation_benchmark, Scope}}, infinity).

put_module_knowledge(App, Module, Card) ->
    gen_server:call(?SERVER, {put, {module_knowledge, App, Module}, Card}, infinity).
get_module_knowledge(App, Module) ->
    gen_server:call(?SERVER, {get, {module_knowledge, App, Module}}).
module_knowledge(App) ->
    gen_server:call(?SERVER, {select_prefix, module_knowledge, App}, infinity).

put_app_knowledge(App, Card) ->
    gen_server:call(?SERVER, {put, {app_knowledge, App}, Card}, infinity).
get_app_knowledge(App) -> gen_server:call(?SERVER, {get, {app_knowledge, App}}).

put_global_knowledge(Card) -> gen_server:call(?SERVER, {put, global_knowledge, Card}, infinity).
get_global_knowledge() -> gen_server:call(?SERVER, {get, global_knowledge}).

put_repair(Fingerprint, FindingVersion, Repair) ->
    Fp = to_binary(Fingerprint),
    Version = to_binary(FindingVersion),
    gen_server:call(
        ?SERVER, {put_transition, {repair, Fp, Version}, repair, {Fp, Version}, Repair}, infinity
    ).
%% Expected is a previously read repair map (or not_found for admission).
%% The persisted sequence, not a wall-clock timestamp, is the revision fence.
compare_and_put_repair(Fingerprint, FindingVersion, Expected, Repair)
  when is_map(Repair) ->
    Fp = to_binary(Fingerprint),
    Version = to_binary(FindingVersion),
    gen_server:call(?SERVER,
        {compare_and_put_repair, Fp, Version, Expected, Repair}, infinity).

get_repair(Fingerprint, FindingVersion) ->
    gen_server:call(
        ?SERVER,
        {get, {repair, to_binary(Fingerprint), to_binary(FindingVersion)}}
    ).
repairs() -> gen_server:call(?SERVER, repairs, infinity).
repairs(Fingerprint) -> gen_server:call(?SERVER, {repairs, to_binary(Fingerprint)}, infinity).

put_log_incident(Fingerprint, Incident) when is_map(Incident) ->
    Fp = to_binary(Fingerprint),
    gen_server:call(
        ?SERVER,
        {put_transition, {log_incident, Fp}, log_incident, Fp, Incident},
        infinity
    ).
get_log_incident(Fingerprint) ->
    gen_server:call(?SERVER, {get, {log_incident, to_binary(Fingerprint)}}).
log_incidents() -> gen_server:call(?SERVER, log_incidents, infinity).
log_incidents(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?SERVER, {log_incidents, Limit}, infinity).
log_incidents(App, Module) when is_atom(App), is_atom(Module) ->
    gen_server:call(?SERVER, {log_incidents, App, Module}, infinity).

put_checkpoint(Name, Checkpoint) when is_atom(Name), is_map(Checkpoint) ->
    gen_server:call(?SERVER, {put_checkpoint, Name, Checkpoint}, infinity).
get_checkpoint(Name) when is_atom(Name) ->
    gen_server:call(?SERVER, {get, {checkpoint, Name}}).
delete_checkpoint(Name) when is_atom(Name) ->
    gen_server:call(?SERVER, {delete, {checkpoint, Name}}, infinity).

events(Type, Id) -> events(Type, Id, ?DEFAULT_EVENT_LIMIT).
events(Type, Id, Limit) when is_atom(Type), is_integer(Limit), Limit > 0 ->
    gen_server:call(?SERVER, {events, Type, Id, Limit}, infinity).

snapshot_data() -> gen_server:call(?SERVER, snapshot_data, infinity).

init(Opts) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, "codebase_learning.dets"),
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 10000}]) of
                {ok, ?TABLE} ->
                    Seq = load_event_seq(?TABLE),
                    {ok, #state{tab = ?TABLE, state_root = Root, file = File, event_seq = Seq}};
                {error, Reason} ->
                    {stop, {cannot_open_learning_store, File, Reason}}
            end;
        {error, Reason} ->
            {stop, {cannot_resolve_state_root, Reason}}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(status, _From, State) ->
    Info =
        case dets:info(State#state.tab) of
            undefined -> [];
            I -> I
        end,
    {reply,
        #{
            state_root => State#state.state_root,
            file => State#state.file,
            event_seq => State#state.event_seq,
            table_info => Info
        },
        State};
handle_call({put_relations, Scope, Relations, Keys}, _From, State) ->
    Reply =
        case
            dets:insert(State#state.tab, [
                {{relations, Scope}, Relations},
                {{relation_keys, Scope}, Keys}
            ])
        of
            ok -> dets:sync(State#state.tab);
            Error -> Error
        end,
    {reply, Reply, State};
handle_call({put, Key, Value}, _From, State) ->
    Reply = persist_value(State#state.tab, Key, Value),
    {reply, Reply, State};
handle_call({put_transition, Key, Type, Id, Value0}, _From, State0) ->
    {Reply, State1} = persist_transition(Key, Type, Id, Value0, State0),
    {reply, Reply, State1};
handle_call({compare_and_put_repair, Fp, Version, Expected, Repair}, _From, State0) ->
    Key = {repair, Fp, Version},
    Current = case dets:lookup(State0#state.tab, Key) of
        [{Key, Value}] -> Value;
        [] -> not_found
    end,
    case same_repair_revision(Expected, Current) of
        false ->
            {reply, {error, conflict}, State0};
        true ->
            {Reply, State1} = persist_transition(Key, repair, {Fp, Version},
                Repair#{fingerprint => Fp, finding_version => Version}, State0),
            Result = case Reply of
                ok ->
                    [{Key, Stored}] = dets:lookup(State1#state.tab, Key),
                    {ok, Stored};
                _ -> Reply
            end,
            {reply, Result, State1}
    end;
handle_call({put_checkpoint, Name, Checkpoint0}, _From, State) ->
    Checkpoint = Checkpoint0#{persisted_at => now_iso8601()},
    Reply = persist_value(State#state.tab, {checkpoint, Name}, Checkpoint),
    {reply, Reply, State};
handle_call({delete, Key}, _From, State) ->
    Reply =
        case dets:delete(State#state.tab, Key) of
            ok -> dets:sync(State#state.tab);
            Error -> Error
        end,
    {reply, Reply, State};
handle_call({get, Key}, _From, State) ->
    Reply =
        case dets:lookup(State#state.tab, Key) of
            [{Key, Value}] -> {ok, Value};
            [] -> not_found
        end,
    {reply, Reply, State};
handle_call({select_prefix, Type, App}, _From, State) ->
    Values = dets:foldl(
        fun
            ({{Type0, App0, _Module}, Value}, Acc) when Type0 =:= Type, App0 =:= App ->
                [Value | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        State#state.tab
    ),
    {reply, lists:reverse(Values), State};
handle_call(repairs, _From, State) ->
    {reply, collect_repairs(State#state.tab, all), State};
handle_call({repairs, Fingerprint}, _From, State) ->
    {reply, collect_repairs(State#state.tab, Fingerprint), State};
handle_call(log_incidents, _From, State) ->
    {reply, collect_log_incidents(State#state.tab, all), State};
handle_call({log_incidents, Limit}, _From, State) ->
    Incidents = collect_log_incidents(State#state.tab, all),
    {reply, lists:sublist(Incidents, Limit), State};
handle_call({log_incidents, App, Module}, _From, State) ->
    {reply, collect_log_incidents(State#state.tab, {App, Module}), State};
handle_call({events, Type, Id, Limit}, _From, State) ->
    {reply, collect_events(State#state.tab, Type, Id, Limit), State};
handle_call(snapshot_data, _From, State) ->
    {reply, build_snapshot_data(State#state.tab), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    _ = dets:sync(State#state.tab),
    _ = dets:close(State#state.tab),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

same_repair_revision(not_found, not_found) -> true;
same_repair_revision(#{persist_seq := Seq}, #{persist_seq := Seq}) -> true;
same_repair_revision(Expected, Current) when is_map(Expected), is_map(Current) ->
    %% Old records may predate event sequences. Fold results add identity keys.
    maps:without([fingerprint, finding_version], Expected) =:=
        maps:without([fingerprint, finding_version], Current);
same_repair_revision(_, _) -> false.

persist_value(Tab, Key, Value) ->
    case dets:insert(Tab, {Key, Value}) of
        ok -> dets:sync(Tab);
        Error -> Error
    end.

persist_transition(Key, Type, Id, Value0, State0) ->
    Seq = State0#state.event_seq + 1,
    Now = now_iso8601(),
    Value = enrich_persisted(Value0, Seq, Now),
    Event = #{
        seq => Seq,
        type => Type,
        id => Id,
        at => Now,
        state => event_summary(Type, Value)
    },
    Objects = [
        {Key, Value},
        {{event, Type, Id, Seq}, Event},
        {{meta, event_seq}, Seq}
    ],
    case dets:insert(State0#state.tab, Objects) of
        ok ->
            %% Insert already changed the in-memory table. Never reuse its
            %% revision if sync fails: stale snapshots must still conflict.
            State1 = State0#state{event_seq = Seq},
            case dets:sync(State0#state.tab) of
                ok -> {ok, State1};
                Error -> {Error, State1}
            end;
        Error ->
            {Error, State0}
    end.

enrich_persisted(Value, Seq, Now) when is_map(Value) ->
    Value#{persist_seq => Seq, persisted_at => Now};
enrich_persisted(Value, _Seq, _Now) ->
    Value.

event_summary(checkpoint, Value) when is_map(Value) ->
    maps:with(
        [
            schema_version,
            phase,
            cycle,
            completed,
            total,
            queued_count,
            inflight_count,
            ready,
            last_error,
            next_run_at_ms,
            resume_count,
            cycles,
            state,
            active_jobs,
            last_run_at
        ],
        Value
    );
event_summary(repair, Value) when is_map(Value) ->
    maps:with(
        [
            status,
            stage,
            fingerprint,
            finding_version,
            application,
            module,
            attempt,
            retry_count,
            retryable,
            next_retry_at_ms,
            failure_class,
            last_error,
            last_failed_at,
            worker_started_at,
            error,
            patch_sha256,
            patch_file,
            created_at,
            updated_at,
            completed_at,
            persist_seq,
            persisted_at
        ],
        Value
    );
event_summary(log_incident, Value) when is_map(Value) ->
    maps:with(
        [
            status,
            fingerprint,
            application,
            module,
            level,
            observed_at,
            learned_at,
            error,
            persist_seq,
            persisted_at
        ],
        Value
    );
event_summary(_Type, Value) ->
    Value.

load_event_seq(Tab) ->
    case dets:lookup(Tab, {meta, event_seq}) of
        [{{meta, event_seq}, Seq}] when is_integer(Seq), Seq >= 0 -> Seq;
        _ -> 0
    end.

collect_events(Tab, Type, Id, Limit) ->
    Events = dets:foldl(
        fun
            ({{event, Type0, Id0, Seq}, Event}, Acc) when Type0 =:= Type, Id0 =:= Id ->
                [{Seq, Event} | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ),
    Sorted = lists:reverse(lists:keysort(1, Events)),
    [Event || {_Seq, Event} <- lists:sublist(Sorted, Limit)].

collect_repairs(Tab, Filter) ->
    lists:reverse(
        dets:foldl(
            fun
                ({{repair, Fingerprint, Version}, Repair}, Acc) when is_map(Repair) ->
                    case (Filter =:= all) orelse (Filter =:= Fingerprint) of
                        true ->
                            [Repair#{fingerprint => Fingerprint, finding_version => Version} | Acc];
                        false ->
                            Acc
                    end;
                ({{repair, _Fingerprint, _Version}, _MalformedRepair}, Acc) ->
                    Acc;
                (_, Acc) ->
                    Acc
            end,
            [],
            Tab
        )
    ).

collect_log_incidents(Tab, Filter) ->
    Incidents = dets:foldl(
        fun
            ({{log_incident, Fingerprint}, Incident}, Acc) when is_map(Incident) ->
                App = maps:get(application, Incident, undefined),
                Module = maps:get(module, Incident, undefined),
                Include =
                    case Filter of
                        all -> true;
                        {App0, Module0} -> App =:= App0 andalso Module =:= Module0
                    end,
                case Include of
                    true -> [Incident#{fingerprint => Fingerprint} | Acc];
                    false -> Acc
                end;
            ({{log_incident, _Fingerprint}, _Malformed}, Acc) ->
                Acc;
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ),
    lists:sort(
        fun(A, B) -> maps:get(persist_seq, A, 0) >= maps:get(persist_seq, B, 0) end,
        Incidents
    ).

build_snapshot_data(Tab) ->
    dets:foldl(
        fun
            ({{analysis, App, Module}, Analysis}, Acc) ->
                Analyses0 = maps:get(analyses, Acc, []),
                A = maps:without([source], Analysis),
                Acc#{analyses => [A#{application => App, module => Module} | Analyses0]};
            ({{module_knowledge, App, Module}, Card}, Acc) ->
                Cards0 = maps:get(module_knowledge, Acc, []),
                Acc#{module_knowledge => [Card#{application => App, module => Module} | Cards0]};
            ({{app_knowledge, App}, Card}, Acc) ->
                Apps0 = maps:get(app_knowledge, Acc, #{}),
                Acc#{app_knowledge => Apps0#{App => Card}};
            ({global_knowledge, Card}, Acc) ->
                Acc#{global_knowledge => Card};
            ({{graph, App}, Graph}, Acc) ->
                Graphs0 = maps:get(graphs, Acc, #{}),
                Acc#{graphs => Graphs0#{App => ecai_code_graph:summary(Graph)}};
            ({{relation_keys, Scope}, Keys}, Acc) when is_list(Keys) ->
                Sets0 = maps:get(relation_sets, Acc, #{}),
                Digest = relation_key_digest(Keys),
                Acc#{
                    relation_sets => Sets0#{
                        Scope => #{
                            count => length(Keys),
                            key_digest_sha256 => Digest
                        }
                    }
                };
            ({{relation_benchmark, Scope}, Benchmark}, Acc) when is_map(Benchmark) ->
                Benchmarks0 = maps:get(relation_benchmarks, Acc, #{}),
                ThinBenchmark = maps:without([recovered_keys, missing_keys], Benchmark),
                Acc#{relation_benchmarks => Benchmarks0#{Scope => ThinBenchmark}};
            ({{repair, Fingerprint, Version}, Repair}, Acc) when is_map(Repair) ->
                Repairs0 = maps:get(repairs, Acc, []),
                Thin = maps:without([patch, proposal, verifier_output, context], Repair),
                Acc#{
                    repairs => [
                        Thin#{fingerprint => Fingerprint, finding_version => Version} | Repairs0
                    ]
                };
            ({{repair, _Fingerprint, _Version}, _MalformedRepair}, Acc) ->
                Acc;
            ({{log_incident, Fingerprint}, Incident}, Acc) when is_map(Incident) ->
                Incidents0 = maps:get(log_incidents, Acc, []),
                ThinIncident = maps:without([observed_event, inference], Incident),
                Acc#{log_incidents => [ThinIncident#{fingerprint => Fingerprint} | Incidents0]};
            ({{log_incident, _Fingerprint}, _MalformedIncident}, Acc) ->
                Acc;
            ({{checkpoint, Name}, Checkpoint}, Acc) ->
                Runtime0 = maps:get(runtime_checkpoints, Acc, #{}),
                Acc#{runtime_checkpoints => Runtime0#{Name => checkpoint_snapshot(Checkpoint)}};
            (_, Acc) ->
                Acc
        end,
        #{
            analyses => [],
            module_knowledge => [],
            app_knowledge => #{},
            graphs => #{},
            repairs => [],
            log_incidents => [],
            runtime_checkpoints => #{},
            global_knowledge => #{},
            relation_sets => #{},
            relation_benchmarks => #{}
        },
        Tab
    ).

relation_key_digest(Keys) ->
    Sorted = lists:sort(Keys),
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Sorted, [deterministic]))).

checkpoint_snapshot(
    #{schema := <<"ecai.health-monitor-checkpoint">>} = Checkpoint
) ->
    Latest = thin_health_report(maps:get(latest_report, Checkpoint, undefined)),
    (maps:without([latest_report, queue, inflight_entries, current_item], Checkpoint))#{
        latest_report => Latest
    };
checkpoint_snapshot(Checkpoint) when is_map(Checkpoint) ->
    maps:without([queue, inflight_entries, current_item], Checkpoint);
checkpoint_snapshot(Other) ->
    Other.

thin_health_report(Report) when is_map(Report) ->
    Resolution =
        case maps:get(resolution, Report, undefined) of
            R when is_map(R) ->
                Steps =
                    case maps:get(steps, R, []) of
                        Value when is_list(Value) -> Value;
                        _ -> []
                    end,
                #{
                    summary => maps:get(summary, R, <<>>),
                    step_ids => [
                        maps:get(id, Step, undefined)
                     || Step <- Steps,
                        is_map(Step)
                    ],
                    automatic_execution => maps:get(automatic_execution, R, false)
                };
            _ ->
                undefined
        end,
    (maps:with(
        [
            checked_at,
            status,
            all_systems_go,
            patch_ready,
            resolution_source,
            automatic_execution
        ],
        Report
    ))#{
        resolution => Resolution
    };
thin_health_report(_) ->
    undefined.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
