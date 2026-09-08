%%-------------------------------------------------------------------
%% damage_ae_node_pool.erl
%%
%% Persistent AE HTTP connection pool.
%%
%% Goals:
%%   * keep Gun/TLS connections alive across requests;
%%   * keep a caller pinned to one AE node while its connection is healthy;
%%   * reconnect dead connections with bounded exponential backoff;
%%   * expose raw/json request helpers without duplicating Gun lifecycle code.
%%
%% The pool is started lazily as a dynamic child of damage_sup so this patch
%% does not require changing the static supervisor child list.
%%-------------------------------------------------------------------
-module(damage_ae_node_pool).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    ensure_started/0,
    session/0,
    clear_session/0,
    info/0,
    get/2,
    get_json/2,
    post_json/3,
    request/6
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SESSION_KEY, {?MODULE, session}).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 5000).
-define(DEFAULT_REQUEST_TIMEOUT_MS, 30000).
-define(DEFAULT_RECONNECT_MIN_MS, 1000).
-define(DEFAULT_RECONNECT_MAX_MS, 30000).

-type session() :: #{
    node_id := term(),
    host := string(),
    port := inet:port_number(),
    path_prefix := string(),
    conn_pid := pid()
}.

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec ensure_started() -> {ok, pid()} | {error, term()}.
ensure_started() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            ensure_started_under_supervisor()
    end.

ensure_started_under_supervisor() ->
    ChildSpec = #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    },
    case whereis(damage_sup) of
        Sup when is_pid(Sup) ->
            case supervisor:start_child(damage_sup, ChildSpec) of
                {ok, Pid} ->
                    {ok, Pid};
                {ok, Pid, _Info} ->
                    {ok, Pid};
                {error, {already_started, Pid}} ->
                    {ok, Pid};
                {error, already_present} ->
                    restart_pool_child();
                {error, {already_present, _}} ->
                    restart_pool_child();
                {error, Reason} ->
                    case whereis(?MODULE) of
                        Pid when is_pid(Pid) -> {ok, Pid};
                        undefined -> {error, {pool_start_failed, Reason}}
                    end
            end;
        undefined ->
            %% Useful for focused shell/eunit use where damage_sup is not up.
            %% Production normally reaches the branch above.
            case start_link() of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, Reason} -> {error, {pool_start_failed, Reason}}
            end
    end.

restart_pool_child() ->
    case supervisor:restart_child(damage_sup, ?MODULE) of
        {ok, Pid} ->
            {ok, Pid};
        {ok, Pid, _Info} ->
            {ok, Pid};
        {error, running} ->
            case whereis(?MODULE) of
                Pid when is_pid(Pid) -> {ok, Pid};
                undefined -> {error, pool_child_running_without_registration}
            end;
        {error, Reason} ->
            {error, {pool_restart_failed, Reason}}
    end.

%% Sticky per-caller session.  A wallet/identity process therefore keeps using
%% the same node for gas-price, nonce and POST requests until that connection
%% dies.  This is the first step toward transaction-scoped node affinity.
-spec session() -> {ok, session()} | {error, term()}.
session() ->
    case get(?SESSION_KEY) of
        Session when is_map(Session) ->
            case session_alive(Session) of
                true ->
                    {ok, Session};
                false ->
                    erase(?SESSION_KEY),
                    checkout_and_cache()
            end;
        _ ->
            checkout_and_cache()
    end.

clear_session() ->
    erase(?SESSION_KEY),
    ok.

checkout_and_cache() ->
    case ensure_started() of
        {ok, _Pid} ->
            case gen_server:call(?MODULE, checkout, request_timeout_ms()) of
                {ok, Session} = Ok ->
                    put(?SESSION_KEY, Session),
                    Ok;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

info() ->
    case ensure_started() of
        {ok, _Pid} ->
            gen_server:call(?MODULE, info, request_timeout_ms());
        Error ->
            Error
    end.

get(Path, Timeout) ->
    request(get, Path, [], <<>>, Timeout, raw).

get_json(Path, Timeout) ->
    request(get, Path, [{<<"accept">>, <<"application/json">>}], <<>>, Timeout, json).

post_json(Path, Value, Timeout) ->
    Body =
        case Value of
            Bin when is_binary(Bin) -> Bin;
            IoList when is_list(IoList) -> iolist_to_binary(IoList);
            _ -> jsx:encode(Value)
        end,
    request(
        post,
        Path,
        [
            {<<"accept">>, <<"application/json">>},
            {<<"content-type">>, <<"application/json">>}
        ],
        Body,
        Timeout,
        raw
    ).

-spec request(
    get | post | put | patch | delete | head | options,
    string() | binary(),
    list(),
    iodata(),
    pos_integer(),
    raw | json | none
) -> {ok, map()} | {error, term()}.
request(Method, Path, Headers, Body, Timeout, Decode) ->
    request(Method, Path, Headers, Body, Timeout, Decode, retry_safe(Method)).

request(Method, Path, Headers, Body, Timeout, Decode, CanRetry) ->
    case session() of
        {ok, Session} ->
            case request_once(Session, Method, Path, Headers, Body, Timeout, Decode) of
                {error, Reason} when CanRetry =:= true ->
                    ?LOG_WARNING(
                        "AE pooled request failed node=~p method=~p path=~p reason=~p; retrying once",
                        [maps:get(node_id, Session), Method, Path, Reason]
                    ),
                    clear_session(),
                    request(Method, Path, Headers, Body, Timeout, Decode, false);
                Result ->
                    Result
            end;
        Error ->
            Error
    end.

retry_safe(get) -> true;
retry_safe(head) -> true;
retry_safe(options) -> true;
retry_safe(_) -> false.

session_alive(#{conn_pid := ConnPid}) when is_pid(ConnPid) ->
    is_process_alive(ConnPid);
session_alive(_) ->
    false.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    Nodes0 = configured_nodes(),
    Nodes1 = [connect_node(Node) || Node <- Nodes0],
    Nodes = [schedule_reconnect_if_down(Node) || Node <- Nodes1],
    case [N || N <- Nodes, node_up(N)] of
        [] ->
            ?LOG_WARNING("AE node pool started without an active node; reconnecting in background");
        Active ->
            ?LOG_INFO("AE node pool started active_nodes=~p configured_nodes=~p", [
                length(Active), length(Nodes)
            ])
    end,
    {ok, #{nodes => Nodes, rr => 0}}.

handle_call(checkout, _From, State0) ->
    State1 = ensure_one_connection(State0),
    Nodes = maps:get(nodes, State1),
    Up = [Node || Node <- Nodes, node_up(Node)],
    case Up of
        [] ->
            {reply, {error, no_active_ae_node}, State1};
        _ ->
            Rr = maps:get(rr, State1, 0),
            Index = (Rr rem length(Up)) + 1,
            Node = lists:nth(Index, Up),
            {reply, {ok, node_session(Node)}, State1#{rr := Rr + 1}}
    end;
handle_call(info, _From, State) ->
    Nodes = [public_node_info(Node) || Node <- maps:get(nodes, State)],
    {reply, #{nodes => Nodes, rr => maps:get(rr, State, 0)}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({reconnect, NodeId}, State0) ->
    {Node0, Rest} = take_node(NodeId, maps:get(nodes, State0)),
    case Node0 of
        undefined ->
            {noreply, State0};
        Node ->
            case node_up(Node) of
                true ->
                    {noreply, State0#{nodes := sort_nodes([Node | Rest])}};
                false ->
                    Node1 = connect_node(Node),
                    Node2 = schedule_reconnect_if_down(Node1),
                    {noreply, State0#{nodes := sort_nodes([Node2 | Rest])}}
            end
    end;
handle_info({'DOWN', Ref, process, ConnPid, Reason}, State0) ->
    {noreply, connection_down(ConnPid, {monitor, Ref, Reason}, State0)};
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}, State0) ->
    {noreply,
        connection_down(
            ConnPid,
            {gun_down, Protocol, Reason, KilledStreams},
            State0
        )};
handle_info({'EXIT', ConnPid, Reason}, State0) when is_pid(ConnPid) ->
    {noreply, connection_down(ConnPid, {exit, Reason}, State0)};
handle_info(Info, State) ->
    ?LOG_DEBUG("AE node pool ignoring message ~p", [Info]),
    {noreply, State}.

terminate(Reason, State) ->
    ?LOG_INFO("AE node pool terminating reason=~p", [Reason]),
    lists:foreach(fun close_node/1, maps:get(nodes, State, [])),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Connection management
%%====================================================================

configured_nodes() ->
    Raw =
        case application:get_env(damage, ae_nodes) of
            {ok, Nodes} when is_list(Nodes) -> Nodes;
            _ -> []
        end,
    configured_nodes(Raw, 1, []).

configured_nodes([], _Index, Acc) ->
    lists:reverse(Acc);
configured_nodes([{Host0, Port, Prefix0} | Rest], Index, Acc) when is_integer(Port) ->
    Host = normalize_host(Host0),
    Prefix = normalize_prefix(Prefix0),
    Node = #{
        id => Index,
        host => Host,
        port => Port,
        path_prefix => Prefix,
        conn_pid => undefined,
        monitor_ref => undefined,
        status => down,
        last_error => undefined,
        reconnect_ms => reconnect_min_ms()
    },
    configured_nodes(Rest, Index + 1, [Node | Acc]);
configured_nodes([Bad | Rest], Index, Acc) ->
    ?LOG_WARNING("Ignoring invalid AE node pool configuration ~p", [Bad]),
    configured_nodes(Rest, Index + 1, Acc).

connect_node(Node0) ->
    close_node(Node0),
    Host = maps:get(host, Node0),
    Port = maps:get(port, Node0),
    Timeout = connect_timeout_ms(),
    case damage_gun:open(Host, Port) of
        {ok, ConnPid} ->
            case damage_gun:await_up(ConnPid, Timeout) of
                {ok, Protocol} ->
                    Ref = erlang:monitor(process, ConnPid),
                    ?LOG_INFO(
                        "AE pooled connection up node=~p host=~p port=~p protocol=~p",
                        [maps:get(id, Node0), Host, Port, Protocol]
                    ),
                    Node0#{
                        conn_pid := ConnPid,
                        monitor_ref := Ref,
                        status := up,
                        last_error := undefined,
                        reconnect_ms := reconnect_min_ms()
                    };
                Error ->
                    catch gun:close(ConnPid),
                    ?LOG_WARNING(
                        "AE pooled connection await_up failed node=~p host=~p port=~p error=~p",
                        [maps:get(id, Node0), Host, Port, Error]
                    ),
                    Node0#{
                        conn_pid := undefined,
                        monitor_ref := undefined,
                        status := down,
                        last_error := Error
                    }
            end;
        Error ->
            ?LOG_WARNING(
                "AE pooled connection failed node=~p host=~p port=~p error=~p",
                [maps:get(id, Node0), Host, Port, Error]
            ),
            Node0#{
                conn_pid := undefined,
                monitor_ref := undefined,
                status := down,
                last_error := Error
            }
    end.

close_node(Node) ->
    case maps:get(monitor_ref, Node, undefined) of
        Ref when is_reference(Ref) ->
            erlang:demonitor(Ref, [flush]);
        _ ->
            ok
    end,
    case maps:get(conn_pid, Node, undefined) of
        Pid when is_pid(Pid) ->
            catch gun:close(Pid);
        _ ->
            ok
    end,
    ok.

schedule_reconnect_if_down(Node) ->
    case node_up(Node) of
        true ->
            Node;
        false ->
            Delay = maps:get(reconnect_ms, Node, reconnect_min_ms()),
            _ = erlang:send_after(Delay, self(), {reconnect, maps:get(id, Node)}),
            Next = erlang:min(Delay * 2, reconnect_max_ms()),
            Node#{reconnect_ms := Next}
    end.

connection_down(ConnPid, Reason, State0) ->
    Nodes0 = maps:get(nodes, State0),
    case take_node_by_pid(ConnPid, Nodes0) of
        {undefined, _Rest} ->
            State0;
        {Node0, Rest} ->
            ?LOG_WARNING(
                "AE pooled connection down node=~p host=~p reason=~p",
                [maps:get(id, Node0), maps:get(host, Node0), Reason]
            ),
            case maps:get(monitor_ref, Node0, undefined) of
                Ref when is_reference(Ref) -> erlang:demonitor(Ref, [flush]);
                _ -> ok
            end,
            Node1 = Node0#{
                conn_pid := undefined,
                monitor_ref := undefined,
                status := down,
                last_error := Reason
            },
            Node2 = schedule_reconnect_if_down(Node1),
            State0#{nodes := sort_nodes([Node2 | Rest])}
    end.

ensure_one_connection(State0) ->
    Nodes0 = maps:get(nodes, State0),
    case lists:any(fun node_up/1, Nodes0) of
        true ->
            State0;
        false ->
            case first_down_node(Nodes0) of
                undefined ->
                    State0;
                Node0 ->
                    {_, Rest} = take_node(maps:get(id, Node0), Nodes0),
                    Node1 = connect_node(Node0),
                    Node2 = schedule_reconnect_if_down(Node1),
                    State0#{nodes := sort_nodes([Node2 | Rest])}
            end
    end.

node_up(Node) ->
    maps:get(status, Node, down) =:= up andalso
        case maps:get(conn_pid, Node, undefined) of
            Pid when is_pid(Pid) -> is_process_alive(Pid);
            _ -> false
        end.

first_down_node([]) ->
    undefined;
first_down_node([Node | Rest]) ->
    case node_up(Node) of
        true -> first_down_node(Rest);
        false -> Node
    end.

node_session(Node) ->
    #{
        node_id => maps:get(id, Node),
        host => maps:get(host, Node),
        port => maps:get(port, Node),
        path_prefix => maps:get(path_prefix, Node),
        conn_pid => maps:get(conn_pid, Node)
    }.

public_node_info(Node) ->
    #{
        node_id => maps:get(id, Node),
        host => maps:get(host, Node),
        port => maps:get(port, Node),
        path_prefix => maps:get(path_prefix, Node),
        status => maps:get(status, Node),
        conn_pid => maps:get(conn_pid, Node),
        last_error => maps:get(last_error, Node, undefined)
    }.

take_node(_NodeId, []) ->
    {undefined, []};
take_node(NodeId, [Node | Rest]) ->
    case maps:get(id, Node) =:= NodeId of
        true -> {Node, Rest};
        false ->
            {Found, Tail} = take_node(NodeId, Rest),
            {Found, [Node | Tail]}
    end.

take_node_by_pid(_Pid, []) ->
    {undefined, []};
take_node_by_pid(Pid, [Node | Rest]) ->
    case maps:get(conn_pid, Node, undefined) =:= Pid of
        true -> {Node, Rest};
        false ->
            {Found, Tail} = take_node_by_pid(Pid, Rest),
            {Found, [Node | Tail]}
    end.

sort_nodes(Nodes) ->
    lists:sort(
        fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end,
        Nodes
    ).

%%====================================================================
%% Request path
%%====================================================================

request_once(Session, Method, Path0, Headers, Body0, Timeout, Decode) ->
    ConnPid = maps:get(conn_pid, Session),
    case is_process_alive(ConnPid) of
        false ->
            {error, pooled_connection_down};
        true ->
            Path = join_path(maps:get(path_prefix, Session), Path0),
            Body = normalize_body(Body0),
            try
                StreamRef =
                    case Method of
                        get -> gun:get(ConnPid, Path, Headers);
                        post -> gun:post(ConnPid, Path, Headers, Body);
                        put -> gun:put(ConnPid, Path, Headers, Body);
                        patch -> gun:patch(ConnPid, Path, Headers, Body);
                        delete -> gun:delete(ConnPid, Path, Headers);
                        head -> gun:head(ConnPid, Path, Headers);
                        options -> gun:options(ConnPid, Path, Headers)
                    end,
                await_response(Session, ConnPid, StreamRef, Timeout, Decode)
            catch
                Class:Reason:Stacktrace ->
                    {error, {pooled_request_failed, Class, Reason, Stacktrace}}
            end
    end.

await_response(Session, ConnPid, StreamRef, Timeout, Decode) ->
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, fin, Status, RespHeaders} ->
            build_response(Session, Status, RespHeaders, <<>>, Decode);
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(ConnPid, StreamRef, Timeout) of
                {ok, Body} ->
                    build_response(Session, Status, RespHeaders, Body, Decode);
                Error ->
                    {error, {pooled_await_body_failed, Error}}
            end;
        {error, Reason} ->
            {error, {pooled_await_response_failed, Reason}};
        Other ->
            {error, {pooled_unexpected_response, Other}}
    end.

build_response(Session, Status, Headers, Body, Decode) ->
    Base = #{
        status => Status,
        headers => Headers,
        body => Body,
        node => session_public_info(Session)
    },
    case Decode of
        raw ->
            {ok, Base};
        none ->
            {ok, maps:remove(body, Base)};
        json ->
            case decode_json(Body) of
                {ok, Json} -> {ok, Base#{json => Json}};
                {error, Reason} -> {error, {invalid_json, Reason, Base}}
            end
    end.

decode_json(<<>>) ->
    {ok, #{}};
decode_json(Body) ->
    try jsx:decode(Body, [{labels, atom}, return_maps]) of
        Json -> {ok, Json}
    catch
        _:Reason -> {error, Reason}
    end.

session_public_info(Session) ->
    maps:with([node_id, host, port, path_prefix], Session).

join_path(Prefix0, Path0) ->
    Prefix = normalize_prefix(Prefix0),
    Path = normalize_path(Path0),
    Full =
        case Prefix of
            "/" -> "/" ++ string:trim(Path, leading, "/");
            "" -> "/" ++ string:trim(Path, leading, "/");
            _ ->
                string:trim(Prefix, trailing, "/") ++ "/" ++
                    string:trim(Path, leading, "/")
        end,
    list_to_binary(Full).

normalize_host(Bin) when is_binary(Bin) -> binary_to_list(Bin);
normalize_host(List) when is_list(List) -> List.

normalize_prefix(Bin) when is_binary(Bin) -> normalize_prefix(binary_to_list(Bin));
normalize_prefix([]) -> "/";
normalize_prefix(List) when is_list(List) ->
    case List of
        "/" -> "/";
        _ ->
            "/" ++ string:trim(List, both, "/") ++ "/"
    end.

normalize_path(Bin) when is_binary(Bin) -> binary_to_list(Bin);
normalize_path(List) when is_list(List) -> List.

normalize_body(undefined) -> <<>>;
normalize_body(Bin) when is_binary(Bin) -> Bin;
normalize_body(IoList) -> iolist_to_binary(IoList).

connect_timeout_ms() ->
    env_pos_int(ae_node_pool_connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT_MS).

request_timeout_ms() ->
    env_pos_int(ae_node_pool_request_timeout_ms, ?DEFAULT_REQUEST_TIMEOUT_MS).

reconnect_min_ms() ->
    env_pos_int(ae_node_pool_reconnect_min_ms, ?DEFAULT_RECONNECT_MIN_MS).

reconnect_max_ms() ->
    Max = env_pos_int(ae_node_pool_reconnect_max_ms, ?DEFAULT_RECONNECT_MAX_MS),
    erlang:max(Max, reconnect_min_ms()).

env_pos_int(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, V} when is_integer(V), V > 0 -> V;
        {ok, V} when is_binary(V) ->
            try binary_to_integer(V) of
                I when I > 0 -> I;
                _ -> Default
            catch
                _:_ -> Default
            end;
        {ok, V} when is_list(V) ->
            try list_to_integer(V) of
                I when I > 0 -> I;
                _ -> Default
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.
