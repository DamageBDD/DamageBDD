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
    get_repair/2,
    repairs/0,
    repairs/1,
    put_checkpoint/2,
    get_checkpoint/1,
    delete_checkpoint/1,
    events/2,
    events/3,
    snapshot_data/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ecai_code_learning_dets).
-define(DEFAULT_EVENT_LIMIT, 100).

-ifdef(TEST).
-export([collect_repairs/2, build_snapshot_data/1]).
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
    gen_server:call(?SERVER, {put_transition, {repair, Fp, Version}, repair, {Fp, Version}, Repair}, infinity).
get_repair(Fingerprint, FindingVersion) ->
    gen_server:call(?SERVER,
        {get, {repair, to_binary(Fingerprint), to_binary(FindingVersion)}}).
repairs() -> gen_server:call(?SERVER, repairs, infinity).
repairs(Fingerprint) -> gen_server:call(?SERVER, {repairs, to_binary(Fingerprint)}, infinity).

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
                {error, Reason} -> {stop, {cannot_open_learning_store, File, Reason}}
            end;
        {error, Reason} -> {stop, {cannot_resolve_state_root, Reason}}
    end.

handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(status, _From, State) ->
    Info = case dets:info(State#state.tab) of undefined -> []; I -> I end,
    {reply, #{state_root => State#state.state_root, file => State#state.file,
              event_seq => State#state.event_seq, table_info => Info}, State};
handle_call({put_relations, Scope, Relations, Keys}, _From, State) ->
    Reply = case dets:insert(State#state.tab, [
        {{relations, Scope}, Relations},
        {{relation_keys, Scope}, Keys}
    ]) of
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
handle_call({put_checkpoint, Name, Checkpoint0}, _From, State) ->
    Checkpoint = Checkpoint0#{persisted_at => now_iso8601()},
    Reply = persist_value(State#state.tab, {checkpoint, Name}, Checkpoint),
    {reply, Reply, State};
handle_call({delete, Key}, _From, State) ->
    Reply = case dets:delete(State#state.tab, Key) of
        ok -> dets:sync(State#state.tab);
        Error -> Error
    end,
    {reply, Reply, State};
handle_call({get, Key}, _From, State) ->
    Reply = case dets:lookup(State#state.tab, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> not_found
    end,
    {reply, Reply, State};
handle_call({select_prefix, Type, App}, _From, State) ->
    Values = dets:foldl(
        fun
            ({{Type0, App0, _Module}, Value}, Acc) when Type0 =:= Type, App0 =:= App ->
                [Value | Acc];
            (_, Acc) -> Acc
        end,
        [], State#state.tab),
    {reply, lists:reverse(Values), State};
handle_call(repairs, _From, State) ->
    {reply, collect_repairs(State#state.tab, all), State};
handle_call({repairs, Fingerprint}, _From, State) ->
    {reply, collect_repairs(State#state.tab, Fingerprint), State};
handle_call({events, Type, Id, Limit}, _From, State) ->
    {reply, collect_events(State#state.tab, Type, Id, Limit), State};
handle_call(snapshot_data, _From, State) ->
    {reply, build_snapshot_data(State#state.tab), State};
handle_call(_Request, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    _ = dets:sync(State#state.tab),
    _ = dets:close(State#state.tab),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

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
            case dets:sync(State0#state.tab) of
                ok -> {ok, State0#state{event_seq = Seq}};
                Error -> {Error, State0}
            end;
        Error -> {Error, State0}
    end.

enrich_persisted(Value, Seq, Now) when is_map(Value) ->
    Value#{persist_seq => Seq, persisted_at => Now};
enrich_persisted(Value, _Seq, _Now) -> Value.

event_summary(checkpoint, Value) when is_map(Value) ->
    maps:with([
        schema_version, phase, cycle, completed, total, queued_count,
        inflight_count, ready, last_error, next_run_at_ms, resume_count,
        cycles, state, active_jobs, last_run_at
    ], Value);
event_summary(repair, Value) when is_map(Value) ->
    maps:with([
        status, stage, fingerprint, finding_version, application, module, attempt,
        error, patch_sha256, patch_file, created_at, updated_at, completed_at,
        persist_seq, persisted_at
    ], Value);
event_summary(_Type, Value) -> Value.

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
            (_, Acc) -> Acc
        end,
        [], Tab),
    Sorted = lists:reverse(lists:keysort(1, Events)),
    [Event || {_Seq, Event} <- lists:sublist(Sorted, Limit)].

collect_repairs(Tab, Filter) ->
    lists:reverse(dets:foldl(
        fun
            ({{repair, Fingerprint, Version}, Repair}, Acc) when is_map(Repair) ->
                case (Filter =:= all) orelse (Filter =:= Fingerprint) of
                    true -> [Repair#{fingerprint => Fingerprint, finding_version => Version} | Acc];
                    false -> Acc
                end;
            ({{repair, _Fingerprint, _Version}, _MalformedRepair}, Acc) ->
                Acc;
            (_, Acc) -> Acc
        end,
        [], Tab)).

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
                Acc#{relation_sets => Sets0#{Scope => #{
                    count => length(Keys),
                    key_digest_sha256 => Digest
                }}};
            ({{relation_benchmark, Scope}, Benchmark}, Acc) when is_map(Benchmark) ->
                Benchmarks0 = maps:get(relation_benchmarks, Acc, #{}),
                ThinBenchmark = maps:without([recovered_keys, missing_keys], Benchmark),
                Acc#{relation_benchmarks => Benchmarks0#{Scope => ThinBenchmark}};
            ({{repair, Fingerprint, Version}, Repair}, Acc) when is_map(Repair) ->
                Repairs0 = maps:get(repairs, Acc, []),
                Thin = maps:without([patch, proposal, verifier_output, context], Repair),
                Acc#{repairs => [Thin#{fingerprint => Fingerprint, finding_version => Version} | Repairs0]};
            ({{repair, _Fingerprint, _Version}, _MalformedRepair}, Acc) ->
                Acc;
            ({{checkpoint, Name}, Checkpoint}, Acc) ->
                Runtime0 = maps:get(runtime_checkpoints, Acc, #{}),
                Acc#{runtime_checkpoints => Runtime0#{Name => checkpoint_snapshot(Checkpoint)}};
            (_, Acc) -> Acc
        end,
        #{analyses => [], module_knowledge => [], app_knowledge => #{}, graphs => #{},
          repairs => [], runtime_checkpoints => #{}, global_knowledge => #{},
          relation_sets => #{}, relation_benchmarks => #{}},
        Tab).

relation_key_digest(Keys) ->
    Sorted = lists:sort(Keys),
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Sorted, [deterministic]))).

checkpoint_snapshot(Checkpoint) when is_map(Checkpoint) ->
    maps:without([queue, inflight_entries], Checkpoint);
checkpoint_snapshot(Other) -> Other.

now_iso8601() ->
    unicode:characters_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
