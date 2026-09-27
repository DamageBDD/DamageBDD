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
    snapshot_data/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ecai_code_learning_dets).

-record(state, {tab, state_root, file}).

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
    gen_server:call(?SERVER,
        {put, {repair, to_binary(Fingerprint), to_binary(FindingVersion)}, Repair}, infinity).
get_repair(Fingerprint, FindingVersion) ->
    gen_server:call(?SERVER,
        {get, {repair, to_binary(Fingerprint), to_binary(FindingVersion)}}).
repairs() -> gen_server:call(?SERVER, repairs, infinity).
repairs(Fingerprint) -> gen_server:call(?SERVER, {repairs, to_binary(Fingerprint)}, infinity).

snapshot_data() -> gen_server:call(?SERVER, snapshot_data, infinity).

init(Opts) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, "codebase_learning.dets"),
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 10000}]) of
                {ok, ?TABLE} -> {ok, #state{tab = ?TABLE, state_root = Root, file = File}};
                {error, Reason} -> {stop, {cannot_open_learning_store, File, Reason}}
            end;
        {error, Reason} -> {stop, {cannot_resolve_state_root, Reason}}
    end.

handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(status, _From, State) ->
    Info = case dets:info(State#state.tab) of undefined -> []; I -> I end,
    {reply, #{state_root => State#state.state_root, file => State#state.file,
              table_info => Info}, State};
handle_call({put, Key, Value}, _From, State) ->
    Reply = case dets:insert(State#state.tab, {Key, Value}) of
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

collect_repairs(Tab, Filter) ->
    lists:reverse(dets:foldl(
        fun
            ({{repair, Fingerprint, Version}, Repair}, Acc) ->
                case (Filter =:= all) orelse (Filter =:= Fingerprint) of
                    true -> [Repair#{fingerprint => Fingerprint, finding_version => Version} | Acc];
                    false -> Acc
                end;
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
            ({{repair, Fingerprint, Version}, Repair}, Acc) ->
                Repairs0 = maps:get(repairs, Acc, []),
                Thin = maps:without([patch, verifier_output, context], Repair),
                Acc#{repairs => [Thin#{fingerprint => Fingerprint, finding_version => Version} | Repairs0]};
            (_, Acc) -> Acc
        end,
        #{analyses => [], module_knowledge => [], app_knowledge => #{}, graphs => #{},
          repairs => [], global_knowledge => #{}},
        Tab).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
