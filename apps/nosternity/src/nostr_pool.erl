%% nostr_pool.erl
%% Pooled relay access: persistent WS connections + fanout queries.
-module(nostr_pool).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    ensure_started/0,
    ensure_started/1,
    stop/0,
    publish/3,
    publish/2,
    publish_sync/3,
    default_relays/1,
    req_one/4,
    req_one/3
]).
-export([
    reset/0,
    reset/1,
    kill_worker/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-import(damage_utils, [to_bin/1]).

-define(SERVER, ?MODULE).

-record(state, {
    %% RelayUrlBin => WorkerPid
    workers = #{} :: #{binary() => pid()},
    relays = [] :: [binary()]
}).

-spec default_relays(map()) -> [map()].
default_relays(Ctx) ->
    case maps:get(nostr_relays, Ctx, undefined) of
        R when is_list(R), R =/= [] ->
            damage_nostr:normalize_relays(R);
        _ ->
            damage_nostr:configured_relays()
    end.
%% ---------------------------
%% Public API
%% ---------------------------
-spec reset() -> ok.
reset() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:call(?SERVER, reset)
    end.

-spec reset([binary()]) -> ok.
reset(Relays) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:call(?SERVER, {reset_relays, damage_nostr:normalize_relays(Relays)})
    end.

start_link(Relays0) when is_list(Relays0) ->
    Relays = damage_nostr:normalize_relays(Relays0),
    gen_server:start_link({local, ?SERVER}, ?MODULE, #{relays => Relays}, []);
start_link(#{relays := Relays0}) ->
    Relays = damage_nostr:normalize_relays(Relays0),
    gen_server:start_link({local, ?SERVER}, ?MODULE, #{relays => Relays}, []).

-spec ensure_started() -> ok | {error, term()}.
ensure_started() ->
    ensure_started(default_relays(#{})).
-spec ensure_started([binary()]) -> ok | {error, term()}.
ensure_started(Relays) ->
    case whereis(?SERVER) of
        undefined ->
            case start_link(Relays) of
                {ok, _Pid} -> ok;
                {error, {already_started, _}} -> ok;
                Other -> Other
            end;
        _Pid ->
            %% Update relay set if needed
            ?LOG_DEBUG("ensure_started ~p", [Relays]),
            gen_server:cast(?SERVER, {set_relays, damage_nostr:normalize_relays(Relays)}),
            ok
    end.

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:stop(?SERVER)
    end.

%% Publish with explicit relays
-spec publish(Event :: map(), Relays :: [binary()], TimeoutMs :: pos_integer()) -> ok.
publish(Event, Relays, _TimeoutMs) ->
    ensure_started(Relays),
    gen_server:cast(?SERVER, {publish, Event, damage_nostr:normalize_relays(Relays)}),
    ok.

%% Publish to whatever relays pool has configured
-spec publish(Event :: map(), TimeoutMs :: pos_integer()) -> ok.
publish(Event, TimeoutMs) ->
    gen_server:cast(?SERVER, {publish_default, Event, TimeoutMs}),
    ok.

%% req_one with explicit relays
-spec req_one(
    Filter :: map(), Relays :: [binary()], TimeoutMs :: pos_integer(), FanoutLimit :: pos_integer()
) ->
    {ok, map()} | {error, term()}.
req_one(Filter, Relays, TimeoutMs, FanoutLimit) ->
    %ensure_started(Relays),
    gen_server:call(
        ?SERVER,
        {req_one, Filter, damage_nostr:normalize_relays(Relays), TimeoutMs, FanoutLimit},
        TimeoutMs + 2000
    ).

%% req_one with pool defaults, fan out to up to 3 by default
-spec req_one(Filter :: map(), TimeoutMs :: pos_integer(), FanoutLimit :: pos_integer()) ->
    {ok, map()} | {error, term()}.
req_one(Filter, TimeoutMs, FanoutLimit) ->
    gen_server:call(?SERVER, {req_one_default, Filter, TimeoutMs, FanoutLimit}, TimeoutMs + 2000).
-spec publish_sync(Event :: map(), Relays :: [binary()], TimeoutMs :: pos_integer()) ->
    ok | {error, term()}.
publish_sync(Event, Relays, TimeoutMs) ->
    ensure_started(Relays),
    gen_server:call(
        ?SERVER,
        {publish_sync, Event, damage_nostr:normalize_relays(Relays), TimeoutMs},
        TimeoutMs + 2000
    ).
-spec kill_worker(binary()) -> ok.
kill_worker(Relay) ->
    gen_server:call(?SERVER, {kill_worker, Relay}).

%% ---------------------------
%% gen_server
%% ---------------------------

init(#{relays := Relays}) ->
    process_flag(trap_exit, true),
    %% Start workers for initial relays
    Workers = start_workers(Relays, #{}),
    {ok, #state{workers = Workers, relays = Relays}}.

handle_call(reset, _From, S = #state{workers = Workers}) ->
    ?LOG_WARNING("nostr_pool reset: killing all workers (~p)", [maps:size(Workers)]),

    lists:foreach(
        fun({_R, Pid}) ->
            catch exit(Pid, kill)
        end,
        maps:to_list(Workers)
    ),

    {reply, ok, S#state{workers = #{}}};
handle_call({reset_relays, Relays}, _From, S = #state{workers = Workers0}) ->
    ?LOG_WARNING("nostr_pool reset_relays: ~p", [Relays]),

    %% kill all existing workers
    lists:foreach(
        fun({_R, Pid}) ->
            catch exit(Pid, kill)
        end,
        maps:to_list(Workers0)
    ),

    %% restart fresh
    Workers = start_workers(Relays, #{}),

    {reply, ok, S#state{workers = Workers, relays = Relays}};
handle_call({kill_worker, Relay}, _From, S = #state{workers = Workers}) ->
    Key = relay_key(Relay),
    case maps:get(Key, Workers, undefined) of
        Pid when is_pid(Pid) ->
            catch exit(Pid, kill),
            {reply, ok, S#state{workers = maps:remove(Key, Workers)}};
        _ ->
            {reply, ok, S}
    end;
handle_call({publish_sync, Event, Relays, TimeoutMs}, _From, S0) ->
    S = ensure_workers(Relays, S0),
    Results =
        [
            case get_worker(R, S) of
                {ok, Pid} ->
                    {R, catch nostr_relay_worker:publish_sync(Pid, Event, TimeoutMs)};
                Error ->
                    {R, Error}
            end
         || R <- Relays
        ],
    Reply =
        case [ok || {_R, ok} <- Results] of
            [_ | _] ->
                ok;
            [] ->
                {error, {all_failed, Results}}
        end,
    {reply, Reply, S};
handle_call({req_one_default, Filter, TimeoutMs, FanoutLimit}, _From, S = #state{relays = Relays}) ->
    {reply, do_req_one(Filter, Relays, TimeoutMs, FanoutLimit, S), S};
handle_call({req_one, Filter, Relays, TimeoutMs, FanoutLimit}, _From, S) ->
    {reply, do_req_one(Filter, Relays, TimeoutMs, FanoutLimit, S), S};
handle_call(Req, _From, S) ->
    ?LOG_DEBUG("nostr_pool unhandled handle_call ~p", [Req]),
    {reply, {error, unknown_call}, S}.

handle_cast({set_relays, Relays}, S = #state{workers = Workers0}) ->
    Workers = start_workers(Relays, Workers0),
    {noreply, S#state{relays = Relays, workers = Workers}};
handle_cast({publish, Event, Relays}, S0) ->
    S = ensure_workers(Relays, S0),
    lists:foreach(
        fun(R) ->
            case get_worker(R, S) of
                {ok, Pid} ->
                    nostr_relay_worker:publish(Pid, Event);
                _ ->
                    ok
            end
        end,
        Relays
    ),
    {noreply, S};
handle_cast({publish_default, Event, _TimeoutMs}, S0 = #state{relays = Relays}) ->
    S = ensure_workers(Relays, S0),
    lists:foreach(
        fun(R) ->
            case get_worker(R, S) of
                {ok, Pid} ->
                    nostr_relay_worker:publish(Pid, Event);
                _ ->
                    ok
            end
        end,
        Relays
    ),
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'EXIT', Pid, normal}, S = #state{workers = Workers0}) ->
    %% If a worker dies, remove it; it will be restarted on next request/publish
    Workers = maps:filter(fun(_R, WPid) -> WPid =/= Pid end, Workers0),
    {noreply, S#state{workers = Workers}};
handle_info({'EXIT', Pid, Reason}, S = #state{workers = Workers0}) ->
    %% If a worker dies, remove it; it will be restarted on next request/publish
    Workers = maps:filter(fun(_R, WPid) -> WPid =/= Pid end, Workers0),
    ?LOG_WARNING("nostr_pool worker exit pid=~p reason=~p", [Pid, Reason]),
    {noreply, S#state{workers = Workers}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% ---------------------------
%% Internal
%% ---------------------------

do_req_one(Filter, Relays0, TimeoutMs, FanoutLimit, S0) ->
    Relays = take_first(FanoutLimit, damage_nostr:normalize_relays(Relays0)),
    S = ensure_workers(Relays, S0),

    %% Fan out concurrently; first {ok, Event} wins.
    Parent = self(),
    Helpers =
        [
            spawn_link(fun() ->
                Res =
                    case get_worker(R, S) of
                        {ok, Pid} ->
                            %% We let worker handle timeouts; gen_server call gets TimeoutMs
                            gen_server:call(
                                Pid, {req_one, Filter, TimeoutMs}, TimeoutMs + 500
                            );
                        _ ->
                            {error, no_worker}
                    end,
                Parent ! {nostr_req_one_result, self(), R, normalize_result(Res)}
            end)
         || R <- Relays
        ],

    collect_first_ok(Helpers, TimeoutMs, []).

collect_first_ok([], _TimeoutMs, Errors) ->
    %% No successes
    case Errors of
        [] -> {error, no_relays};
        _ -> {error, {all_failed, lists:reverse(Errors)}}
    end;
collect_first_ok(Helpers, TimeoutMs, Errors) ->
    receive
        {nostr_req_one_result, HPid, _Relay, {ok, Event}} ->
            %% Kill other helpers to stop waiting
            lists:foreach(
                fun(P) ->
                    if
                        P =/= HPid -> exit(P, kill);
                        true -> ok
                    end
                end,
                Helpers
            ),
            {ok, Event};
        {nostr_req_one_result, HPid, Relay, Err} ->
            collect_first_ok(lists:delete(HPid, Helpers), TimeoutMs, [{Relay, Err} | Errors])
    after TimeoutMs ->
        %% Timeout: kill helpers
        lists:foreach(fun(P) -> exit(P, kill) end, Helpers),
        {error, timeout}
    end.

normalize_result({'EXIT', _}) -> {error, worker_call_failed};
normalize_result(Res) -> Res.

ensure_workers(Relays, S = #state{workers = Workers0}) ->
    Workers = start_workers(Relays, Workers0),
    S#state{workers = Workers}.

start_workers([], Workers) ->
    Workers;
start_workers([R0 | Rest], Workers0) ->
    R = damage_nostr:normalize_relay(R0),
    Key = relay_key(R),
    Workers =
        case maps:get(Key, Workers0, undefined) of
            undefined ->
                case nostr_relay_worker:start_link(R) of
                    {ok, Pid} ->
                        maps:put(Key, Pid, Workers0);
                    {error, {already_started, Pid}} ->
                        maps:put(Key, Pid, Workers0);
                    {error, Reason} ->
                        ?LOG_WARNING("Failed starting worker relay=~p reason=~p", [R, Reason]),
                        Workers0
                end;
            Pid when is_pid(Pid) ->
                Workers0
        end,
    start_workers(Rest, Workers).

get_worker(Relay0, #state{workers = Workers}) ->
    Key = relay_key(Relay0),
    case maps:get(Key, Workers, undefined) of
        undefined -> {error, not_found};
        Pid when is_pid(Pid) -> {ok, Pid}
    end.

relay_key(Relay0) ->
    Relay = damage_nostr:normalize_relay(Relay0),
    maps:get(url, Relay).
take_first(N, _L) when N =< 0 -> [];
take_first(_N, []) -> [];
take_first(N, [H | T]) -> [H | take_first(N - 1, T)].
