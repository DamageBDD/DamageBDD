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
    default_relays/1,

    req_one/4,
    req_one/3
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-import(damage_utils, [to_bin/1]).

-define(SERVER, ?MODULE).

-record(state, {
    %% RelayUrlBin => WorkerPid
    workers = #{} :: #{binary() => pid()},
    relays = [] :: [binary()]
}).

-spec default_relays(map()) -> [binary()].
default_relays(Ctx) ->
    case maps:get(nostr_relays, Ctx, undefined) of
        R when is_list(R), R =/= [] ->
            [to_bin(X) || X <- R];
        _ ->
            case application:get_env(damage, nostr_relays) of
                {ok, R2} when is_list(R2), R2 =/= [] ->
                    [to_bin(X) || X <- R2];
                _ ->
                    [
                        <<"wss://nos.lol">>,
                        <<"wss://nostr-01.yakihonne.com">>,
                        <<"wss://nostr-02.yakihonne.com">>
                        %<<"wss://relay.damus.io">>,
                        %<<"wss://relay.nostr.band">>
                    ]
            end
    end.
%% ---------------------------
%% Public API
%% ---------------------------

-spec start_link([binary()]) -> {ok, pid()} | {error, term()}.
start_link(#{relays := Relays0}) ->
    Relays = normalize_relays(Relays0),
    gen_server:start_link({local, ?SERVER}, ?MODULE, #{relays => Relays}, []).

-spec ensure_started() -> ok | {error, term()}.
ensure_started() ->
    ensure_started(#{relays => default_relays(#{})}).
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
            gen_server:cast(?SERVER, {set_relays, normalize_relays(Relays)}),
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
    gen_server:cast(?SERVER, {publish, Event, normalize_relays(Relays)}),
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
        {req_one, Filter, normalize_relays(Relays), TimeoutMs, FanoutLimit},
        TimeoutMs + 2000
    ).

%% req_one with pool defaults, fan out to up to 3 by default
-spec req_one(Filter :: map(), TimeoutMs :: pos_integer(), FanoutLimit :: pos_integer()) ->
    {ok, map()} | {error, term()}.
req_one(Filter, TimeoutMs, FanoutLimit) ->
    gen_server:call(?SERVER, {req_one_default, Filter, TimeoutMs, FanoutLimit}, TimeoutMs + 2000).

%% ---------------------------
%% gen_server
%% ---------------------------

init(#{relays := Relays}) ->
    process_flag(trap_exit, true),
    %% Start workers for initial relays
    Workers = start_workers(Relays, #{}),
    {ok, #state{workers = Workers, relays = Relays}}.

handle_call({req_one_default, Filter, TimeoutMs, FanoutLimit}, _From, S = #state{relays = Relays}) ->
    {reply, do_req_one(Filter, Relays, TimeoutMs, FanoutLimit, S), S};
handle_call({req_one, Filter, Relays, TimeoutMs, FanoutLimit}, _From, S) ->
    {reply, do_req_one(Filter, Relays, TimeoutMs, FanoutLimit, S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({set_relays, Relays}, S = #state{workers = Workers0}) ->
    Workers = start_workers(Relays, Workers0),
    {noreply, S#state{relays = Relays, workers = Workers}};
handle_cast({publish, Event, Relays}, S) ->
    _ = ensure_workers(Relays, S),
    lists:foreach(
        fun(R) ->
            case get_worker(R, S) of
                {ok, Pid} -> nostr_relay_worker:publish(Pid, Event);
                _ -> ok
            end
        end,
        Relays
    ),
    {noreply, S};
handle_cast({publish_default, Event, _TimeoutMs}, S = #state{relays = Relays}) ->
    _ = ensure_workers(Relays, S),
    lists:foreach(
        fun(R) ->
            case get_worker(R, S) of
                {ok, Pid} -> nostr_relay_worker:publish(Pid, Event);
                _ -> ok
            end
        end,
        Relays
    ),
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

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
    Relays = take_first(FanoutLimit, normalize_relays(Relays0)),
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
                            catch gen_server:call(
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
start_workers([R | Rest], Workers0) ->
    Workers =
        case maps:get(R, Workers0, undefined) of
            undefined ->
                case nostr_relay_worker:start_link(R) of
                    {ok, Pid} ->
                        maps:put(R, Pid, Workers0);
                    {error, {already_started, Pid}} ->
                        maps:put(R, Pid, Workers0);
                    {error, Reason} ->
                        ?LOG_WARNING("Failed starting worker relay=~p reason=~p", [R, Reason]),
                        Workers0
                end;
            Pid when is_pid(Pid) ->
                Workers0
        end,
    start_workers(Rest, Workers).

get_worker(Relay, #state{workers = Workers}) ->
    case maps:get(Relay, Workers, undefined) of
        undefined -> {error, not_found};
        Pid when is_pid(Pid) -> {ok, Pid}
    end.

normalize_relays(Relays) when is_list(Relays) ->
    [to_bin(R) || R <- Relays, is_binary(to_bin(R))].

take_first(N, _L) when N =< 0 -> [];
take_first(_N, []) -> [];
take_first(N, [H | T]) -> [H | take_first(N - 1, T)].
