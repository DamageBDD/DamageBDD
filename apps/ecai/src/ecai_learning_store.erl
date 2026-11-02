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
    put_release_change/2,
    get_release_change/1,
    release_changes/0,
    put_release_baseline/2,
    get_release_baseline/1,
    release_baselines/0,
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

%% Only collection keys are indexed. Graph/source/relation payloads remain on disk.
%% At most two collection readers share DETS; point reads and writes stay serialized.
-record(state, {tab, state_root, file, event_seq = 0, index,
                queries = #{}, pending = [], write_revision = 0}).
-define(MAX_QUERIES, 32).
-define(QUERY_WORKERS, 2).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
stop() -> gen_server:call(?SERVER, stop).
status() -> gen_server:call(?SERVER, status).

put_analysis(App, Module, Analysis) ->
    gen_server:call(?SERVER, {put, {analysis, App, Module}, Analysis}, infinity).
get_analysis(App, Module) ->
    read({analysis, App, Module}).
analyses(App) ->
    gen_server:call(?SERVER, {select_prefix, analysis, App}, infinity).

put_graph(App, Graph) -> gen_server:call(?SERVER, {put, {graph, App}, Graph}, infinity).
get_graph(App) -> read({graph, App}).

put_relations(Scope, Relations) when is_atom(Scope), is_list(Relations) ->
    Deduped = ecai_relation:dedupe(Relations),
    Keys = [ecai_relation:key(Relation) || Relation <- Deduped],
    gen_server:call(?SERVER, {put_relations, Scope, Deduped, Keys}, infinity).
get_relations(Scope) when is_atom(Scope) ->
    read({relations, Scope}).
relation_keys(Scope) when is_atom(Scope) ->
    read({relation_keys, Scope}).

put_relation_benchmark(Scope, Benchmark) when is_atom(Scope), is_map(Benchmark) ->
    gen_server:call(?SERVER, {put, {relation_benchmark, Scope}, Benchmark}, infinity).
get_relation_benchmark(Scope) when is_atom(Scope) ->
    read({relation_benchmark, Scope}).

put_module_knowledge(App, Module, Card) ->
    gen_server:call(?SERVER, {put, {module_knowledge, App, Module}, Card}, infinity).
get_module_knowledge(App, Module) ->
    read({module_knowledge, App, Module}).
module_knowledge(App) ->
    gen_server:call(?SERVER, {select_prefix, module_knowledge, App}, infinity).

put_app_knowledge(App, Card) ->
    gen_server:call(?SERVER, {put, {app_knowledge, App}, Card}, infinity).
get_app_knowledge(App) -> read({app_knowledge, App}).

put_global_knowledge(Card) -> gen_server:call(?SERVER, {put, global_knowledge, Card}, infinity).
get_global_knowledge() -> read(global_knowledge).

put_repair(Fingerprint, FindingVersion, Repair) ->
    Fp = to_binary(Fingerprint),
    Version = to_binary(FindingVersion),
    gen_server:call(
        ?SERVER, {put_transition, {repair, Fp, Version}, repair, {Fp, Version}, Repair}, infinity
    ).
%% Expected is a previously read repair map (or not_found for admission).
%% The persisted sequence, not a wall-clock timestamp, is the revision fence.
compare_and_put_repair(Fingerprint, FindingVersion, Expected, Repair) when
    is_map(Repair)
->
    Fp = to_binary(Fingerprint),
    Version = to_binary(FindingVersion),
    gen_server:call(
        ?SERVER,
        {compare_and_put_repair, Fp, Version, Expected, Repair},
        infinity
    ).

get_repair(Fingerprint, FindingVersion) ->
    read({repair, to_binary(Fingerprint), to_binary(FindingVersion)}).
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
    read({log_incident, to_binary(Fingerprint)}).
log_incidents() -> gen_server:call(?SERVER, log_incidents, infinity).
log_incidents(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?SERVER, {log_incidents, Limit}, infinity).
log_incidents(App, Module) when is_atom(App), is_atom(Module) ->
    gen_server:call(?SERVER, {log_incidents, App, Module}, infinity).

put_release_change(Commit, Change) when is_map(Change) ->
    CommitBin = to_binary(Commit),
    gen_server:call(?SERVER, {put, {release_change, CommitBin}, Change}, infinity).
get_release_change(Commit) ->
    read({release_change, to_binary(Commit)}).
release_changes() ->
    gen_server:call(?SERVER, release_changes, infinity).

put_release_baseline(Environment, Baseline) when is_map(Baseline) ->
    Name = to_binary(Environment),
    gen_server:call(?SERVER, {put, {release_baseline, Name}, Baseline}, infinity).
get_release_baseline(Environment) ->
    read({release_baseline, to_binary(Environment)}).
release_baselines() ->
    gen_server:call(?SERVER, release_baselines, infinity).

put_checkpoint(Name, Checkpoint) when is_atom(Name), is_map(Checkpoint) ->
    gen_server:call(?SERVER, {put_checkpoint, Name, Checkpoint}, infinity).
get_checkpoint(Name) when is_atom(Name) ->
    read({checkpoint, Name}).
delete_checkpoint(Name) when is_atom(Name) ->
    gen_server:call(?SERVER, {delete, {checkpoint, Name}}, infinity).

events(Type, Id) -> events(Type, Id, ?DEFAULT_EVENT_LIMIT).
events(Type, Id, Limit) when is_atom(Type), is_integer(Limit), Limit > 0 ->
    gen_server:call(?SERVER, {events, Type, Id, Limit}, infinity).

snapshot_data() -> snapshot_data(2).
snapshot_data(Retries) ->
    case gen_server:call(?SERVER, snapshot_data, infinity) of
        {error, learning_store_snapshot_busy} when Retries > 0 -> snapshot_data(Retries - 1);
        Reply -> Reply
    end.

init(Opts) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, "codebase_learning.dets"),
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 10000}]) of
                {ok, ?TABLE} ->
                    try
                        Index = build_index(?TABLE),
                        Seq = load_event_seq(?TABLE),
                        {ok, #state{tab = ?TABLE, state_root = Root, file = File,
                                    event_seq = Seq, index = Index}}
                    catch
                        _:_ ->
                            _ = dets:close(?TABLE),
                            {stop, learning_store_index_failed}
                    end;
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
            write_revision => State#state.write_revision,
            active_queries => active_queries(State),
            queued_queries => length(State#state.pending),
            index_entries => ets:info(State#state.index, size),
            read_timeout_ms => read_timeout(),
            query_timeout_ms => query_timeout(),
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
            ok ->
                index_insert(State#state.index, {relations, Scope}),
                index_insert(State#state.index, {relation_keys, Scope}),
                dets:sync(State#state.tab);
            Error -> Error
        end,
    {reply, Reply, changed(State)};
handle_call({put, Key, Value}, _From, State) ->
    Reply = persist_value(State, Key, Value),
    {reply, Reply, changed(State)};
handle_call({put_transition, Key, Type, Id, Value0}, _From, State0) ->
    {Reply, State1} = persist_transition(Key, Type, Id, Value0, State0),
    {reply, Reply, State1};
handle_call({compare_and_put_repair, Fp, Version, Expected, Repair}, _From, State0) ->
    Key = {repair, Fp, Version},
    Current =
        case dets:lookup(State0#state.tab, Key) of
            [{Key, Value}] -> Value;
            [] -> not_found
        end,
    case same_repair_revision(Expected, Current) of
        false ->
            {reply, {error, conflict}, State0};
        true ->
            {Reply, State1} = persist_transition(
                Key,
                repair,
                {Fp, Version},
                Repair#{fingerprint => Fp, finding_version => Version},
                State0
            ),
            Result =
                case Reply of
                    ok ->
                        [{Key, Stored}] = dets:lookup(State1#state.tab, Key),
                        {ok, Stored};
                    _ ->
                        Reply
                end,
            {reply, Result, State1}
    end;
handle_call({put_checkpoint, Name, Checkpoint0}, _From, State) ->
    Checkpoint = Checkpoint0#{persisted_at => now_iso8601()},
    Reply = persist_value(State, {checkpoint, Name}, Checkpoint),
    {reply, Reply, changed(State)};
handle_call({delete, Key}, _From, State) ->
    Reply =
        case dets:delete(State#state.tab, Key) of
            ok ->
                index_delete(State#state.index, Key),
                dets:sync(State#state.tab);
            Error -> Error
        end,
    {reply, Reply, changed(State)};
handle_call({get, Key}, _From, State) ->
    Reply =
        case dets:lookup(State#state.tab, Key) of
            [{Key, Value}] -> {ok, Value};
            [] -> not_found
        end,
    {reply, Reply, State};
handle_call({select_prefix, _, _} = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(repairs = Q, From, State) -> enqueue_query(Q, From, State);
handle_call({repairs, _} = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(log_incidents = Q, From, State) -> enqueue_query(Q, From, State);
handle_call({log_incidents, _} = Q, From, State) -> enqueue_query(Q, From, State);
handle_call({log_incidents, _, _} = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(release_changes = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(release_baselines = Q, From, State) -> enqueue_query(Q, From, State);
handle_call({events, _, _, _} = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(snapshot_data = Q, From, State) -> enqueue_query(Q, From, State);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info({query_result, Ref, Result}, State) ->
    {noreply, finish_query(Ref, Result, State)};
handle_info({query_timeout, Ref}, State) ->
    {noreply, finish_query(Ref, {error, learning_store_query_timeout}, State)};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    Matches = [Ref || {Ref, Q} <- maps:to_list(State#state.queries),
        maps:get(caller_monitor, Q) =:= Monitor orelse
        case maps:get(worker, Q, undefined) of {_, Monitor} -> true; _ -> false end],
    New = lists:foldl(fun(Ref, S) ->
        finish_query(Ref, {error, learning_store_reader_stopped}, S)
    end, State, Matches),
    {noreply, New};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_, Q) ->
        cancel_query(Q),
        gen_server:reply(maps:get(from, Q), {error, learning_store_stopping})
    end, State#state.queries),
    _ = dets:sync(State#state.tab),
    _ = dets:close(State#state.tab),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

same_repair_revision(not_found, not_found) ->
    true;
same_repair_revision(#{persist_seq := Seq}, #{persist_seq := Seq}) ->
    true;
same_repair_revision(Expected, Current) when is_map(Expected), is_map(Current) ->
    %% Old records may predate event sequences. Fold results add identity keys.
    maps:without([fingerprint, finding_version], Expected) =:=
        maps:without([fingerprint, finding_version], Current);
same_repair_revision(_, _) ->
    false.

persist_value(#state{tab = Tab, index = Index}, Key, Value) ->
    case dets:insert(Tab, {Key, Value}) of
        ok ->
            %% Match DETS visibility even when the subsequent sync fails.
            index_insert(Index, Key),
            dets:sync(Tab);
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
            [index_insert(State0#state.index, K) || {K, _} <- Objects],
            State1 = (changed(State0))#state{event_seq = Seq},
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
    Events = fold_records(
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


collect_release_changes(Tab) ->
    Changes = fold_records(
        fun
            ({{release_change, Commit}, Change}, Acc) when is_map(Change) ->
                [Change#{commit => Commit} | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ),
    lists:sort(
        fun(A, B) ->
            {maps:get(authored_at, A, <<>>), maps:get(commit, A, <<>>)} =<
                {maps:get(authored_at, B, <<>>), maps:get(commit, B, <<>>)}
        end,
        Changes
    ).

collect_release_baselines(Tab) ->
    fold_records(
        fun
            ({{release_baseline, Name}, Baseline}, Acc) when is_map(Baseline) ->
                Acc#{Name => Baseline};
            (_, Acc) ->
                Acc
        end,
        #{},
        Tab
    ).

collect_repairs(Tab, Filter) ->
    lists:reverse(
        fold_records(
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
    Incidents = fold_records(
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
    fold_records(
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
            ({{release_change, Commit}, Change}, Acc) when is_map(Change) ->
                Release0 = maps:get(release_memory, Acc, #{}),
                Count = maps:get(change_count, Release0, 0) + 1,
                Latest0 = maps:get(latest, Release0, #{}),
                Latest = latest_release_snapshot(
                    Latest0,
                    (maps:with([authored_at, subject, evidence_sha256], Change))#{commit => Commit}
                ),
                Acc#{release_memory => Release0#{change_count => Count, latest => Latest}};
            ({{release_baseline, Name}, Baseline}, Acc) when is_map(Baseline) ->
                Release0 = maps:get(release_memory, Acc, #{}),
                Baselines0 = maps:get(baselines, Release0, #{}),
                Acc#{release_memory => Release0#{baselines => Baselines0#{Name => Baseline}}};
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
            relation_benchmarks => #{},
            release_memory => #{change_count => 0, baselines => #{}, latest => #{}}
        },
        Tab
    ).


latest_release_snapshot(
    #{authored_at := ExistingAt, commit := ExistingCommit} = Existing,
    #{authored_at := CandidateAt, commit := CandidateCommit} = Candidate
) ->
    case {CandidateAt, CandidateCommit} >= {ExistingAt, ExistingCommit} of
        true -> Candidate;
        false -> Existing
    end;
latest_release_snapshot(_Existing, Candidate) ->
    Candidate.

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

%% Collection APIs are best-effort listings, not transactions: membership is
%% captured when a reader starts and values may advance during the listing.
%% Repair state transitions continue to require the persisted CAS revision.
%% Snapshots are different: reject a result if ANY store mutation overlapped it.
%% The public snapshot API retries twice, then fails rather than exporting a mix.
read(Key) -> gen_server:call(?SERVER, {get, Key}, read_timeout()).
read_timeout() -> positive_env(learning_store_read_timeout_ms, 30000).
query_timeout() -> positive_env(learning_store_query_timeout_ms, 60000).
positive_env(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        N when is_integer(N), N > 0, N =< 3600000 -> N;
        _ -> Default
    end.

build_index(Tab) ->
    Index = ets:new(ecai_learning_collection_keys, [ordered_set, protected, {read_concurrency, true}]),
    ok = dets:safe_fixtable(Tab, true),
    try
        %% Project keys only; never copy huge relation/source values into ETS.
        index_page(dets:select(Tab, [{{'$1', '_'}, [], ['$1']}], 256), Index),
        Index
    after dets:safe_fixtable(Tab, false) end.
index_page('$end_of_table', _Index) -> ok;
index_page({Keys, Continuation}, Index) when is_list(Keys) ->
    [index_insert(Index, K) || K <- Keys],
    index_page(dets:select(Continuation), Index);
index_page({error, Reason}, _) -> error({index_read_failed, Reason}).

index_insert(Index, Key) ->
    [ets:insert(Index, {{Bucket, Key}}) || Bucket <- index_buckets(Key)], ok.
index_delete(Index, Key) ->
    [ets:delete(Index, {Bucket, Key}) || Bucket <- index_buckets(Key)], ok.
index_buckets({analysis, App, _}) -> [{select_prefix, analysis, App}, snapshot_data];
index_buckets({module_knowledge, App, _}) -> [{select_prefix, module_knowledge, App}, snapshot_data];
index_buckets({repair, Fp, _}) -> [repairs, {repairs, Fp}, snapshot_data];
index_buckets({log_incident, _}) -> [log_incidents, snapshot_data];
index_buckets({event, Type, Id, _}) -> [{events, Type, Id}];
index_buckets({release_change, _}) -> [release_changes, snapshot_data];
index_buckets({release_baseline, _}) -> [release_baselines, snapshot_data];
index_buckets({Type, _}) when Type =:= graph; Type =:= app_knowledge;
    Type =:= relation_keys; Type =:= relation_benchmark; Type =:= checkpoint -> [snapshot_data];
index_buckets(global_knowledge) -> [snapshot_data];
index_buckets(_) -> [].

query_bucket({log_incidents, _}) -> log_incidents;
query_bucket({log_incidents, _, _}) -> log_incidents;
query_bucket({events, T, Id, _}) -> {events, T, Id};
query_bucket(Q) -> Q.

enqueue_query(Request, From = {Caller, _}, State) ->
    case map_size(State#state.queries) >= ?MAX_QUERIES of
        true -> {reply, {error, learning_store_busy}, State};
        false ->
            Ref = make_ref(),
            Q = #{request => Request, from => From,
                  caller_monitor => erlang:monitor(process, Caller),
                  timer => erlang:send_after(query_timeout(), self(), {query_timeout, Ref})},
            S = State#state{queries = (State#state.queries)#{Ref => Q},
                            pending = State#state.pending ++ [Ref]},
            {noreply, dispatch_queries(S)}
    end.
active_queries(State) ->
    length([ok || Q <- maps:values(State#state.queries), maps:is_key(worker, Q)]).
dispatch_queries(#state{pending = []} = State) -> State;
dispatch_queries(State) ->
    case active_queries(State) < ?QUERY_WORKERS of
        false -> State;
        true ->
            [Ref | Rest] = State#state.pending,
            Q = maps:get(Ref, State#state.queries),
            Tab = State#state.tab, Index = State#state.index, Parent = self(),
            Request = maps:get(request, Q),
            Worker = spawn_opt(fun() ->
                Result = try
                    Bucket = query_bucket(Request),
                    Keys = ets:select(Index, [{{{Bucket, '$1'}}, [], ['$1']}]),
                    %% Fold each selected value as it is read. Snapshot thinning
                    %% must not retain full source/graph payloads for all keys.
                    query_result(Request, {indexed, Tab, Keys})
                catch _:_ -> {error, learning_store_query_failed} end,
                Parent ! {query_result, Ref, Result}
            end, [link, monitor]),
            dispatch_queries(State#state{pending = Rest,
                queries = (State#state.queries)#{Ref := Q#{worker => Worker, revision => State#state.write_revision}}})
    end.
finish_query(Ref, Result, State) ->
    case maps:take(Ref, State#state.queries) of
        error -> State;
        {Q, Queries} ->
            cancel_query(Q),
            Reply = case Q of
                #{request := snapshot_data, revision := Revision}
                  when Revision =/= State#state.write_revision, is_map(Result) ->
                    {error, learning_store_snapshot_busy};
                _ -> Result
            end,
            gen_server:reply(maps:get(from, Q), Reply),
            dispatch_queries(State#state{queries = Queries,
                                        pending = lists:delete(Ref, State#state.pending)})
    end.
cancel_query(Q) ->
    erlang:cancel_timer(maps:get(timer, Q)),
    erlang:demonitor(maps:get(caller_monitor, Q), [flush]),
    case maps:get(worker, Q, undefined) of
        {Pid, Monitor} -> unlink(Pid), exit(Pid, kill), erlang:demonitor(Monitor, [flush]);
        undefined -> ok
    end.
query_result({select_prefix, _, _}, Rows) ->
    lists:reverse(fold_records(fun({_, V}, Acc) -> [V | Acc] end, [], Rows));
query_result(repairs, Rows) -> collect_repairs(Rows, all);
query_result({repairs, Fp}, Rows) -> collect_repairs(Rows, Fp);
query_result(log_incidents, Rows) -> collect_log_incidents(Rows, all);
query_result({log_incidents, Limit}, Rows) -> lists:sublist(collect_log_incidents(Rows, all), Limit);
query_result({log_incidents, App, Module}, Rows) -> collect_log_incidents(Rows, {App, Module});
query_result(release_changes, Rows) -> collect_release_changes(Rows);
query_result(release_baselines, Rows) -> collect_release_baselines(Rows);
query_result({events, Type, Id, Limit}, Rows) -> collect_events(Rows, Type, Id, Limit);
query_result(snapshot_data, Rows) -> build_snapshot_data(Rows).
fold_records(Fun, Acc, {indexed, Tab, Keys}) ->
    lists:foldl(fun(Key, A) ->
        case dets:lookup(Tab, Key) of
            Objects when is_list(Objects) -> lists:foldl(Fun, A, Objects);
            _ -> error(collection_lookup_failed)
        end
    end, Acc, Keys);
fold_records(Fun, Acc, {rows, Rows}) -> lists:foldl(Fun, Acc, Rows);
fold_records(Fun, Acc, Tab) -> dets:foldl(Fun, Acc, Tab).

changed(State) -> State#state{write_revision = State#state.write_revision + 1}.
