%% nostr_relay_worker.erl
%% One persistent WS connection per relay.
-module(nostr_relay_worker).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    publish/2,
    publish_sync/3,
    parse_wss_url/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PING_MS, 25000).
-define(RECONNECT_MIN_MS, 500).
-define(RECONNECT_MAX_MS, 30000).

-record(state, {
    relay = <<>> :: binary(),
    host :: string(),
    port :: integer(),
    path :: string(),
    tls = true :: boolean(),

    conn_pid = undefined :: pid() | undefined,
    stream_ref = undefined :: any(),
    connected = false :: boolean(),

    %% pending: SubIdBin => #{from := From, timer := TRef}
    pending = #{} :: map(),

    ping_tref = undefined :: reference() | undefined,
    reconnect_tref = undefined :: reference() | undefined,
    backoff_ms = ?RECONNECT_MIN_MS :: non_neg_integer()
}).

%% ---------------------------
%% Public
%% ---------------------------

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(Relay) ->
    gen_server:start_link(?MODULE, #{relay => Relay}, []).

-spec publish(pid(), map()) -> ok.
publish(Pid, Event) ->
    gen_server:cast(Pid, {publish, Event}),
    ok.

%% ---------------------------
%% gen_server
%% ---------------------------

init(#{relay := Relay0}) ->
    process_flag(trap_exit, true),
    Relay = damage_nostr:normalize_relay(Relay0),
    Url = maps:get(url, Relay),
    {Host, Port, Path, Tls} = damage_nostr:parse_ws_url(Url),
    S0 = #state{
        relay = Url,
        host = Host,
        port = Port,
        path = Path,
        tls = Tls
    },
    erlang:send_after(0, self(), reconnect),
    {ok, S0}.

handle_call({publish, Event, _TimeoutMs}, _From, S0) ->
    S = ensure_connected(S0),
    case S#state.connected of
        false ->
            {reply, {error, disconnected}, S};
        true ->
            try
                ok = ws_send_json(S, [<<"EVENT">>, Event]),
                {reply, ok, S}
            catch
                C:R:STrace ->
                    {reply, {error, {publish_failed, C, R, STrace}}, S}
            end
    end;
handle_call({req_one, Filter, TimeoutMs}, From, S0) ->
    case S0#state.connected of
        false ->
            {reply, {error, disconnected}, ensure_connected(S0)};
        true ->
            SubId = make_subid(),
            Req = [<<"REQ">>, SubId, Filter],
            ok = ws_send_json(S0, Req),

            TRef = erlang:send_after(TimeoutMs, self(), {req_timeout, SubId}),
            Pending1 = maps:put(SubId, #{from => From, timer => TRef}, S0#state.pending),
            {noreply, S0#state{pending = Pending1}}
    end;
handle_call(Req, _From, S) ->
    ?LOG_DEBUG("nostr_pool unhandled handle_call ~p", [Req]),
    {reply, {error, unknown_call}, S}.

handle_cast({publish, Event}, S0) ->
    handle_cast({publish, Event, 5000}, S0);
handle_cast({publish, Event, _}, S0) ->
    S = ensure_connected(S0),
    ?LOG_DEBUG("handle_cast publish ~p ~p", [Event, S]),
    case S#state.connected of
        false ->
            {noreply, S};
        true ->
            ?LOG_DEBUG("nostr_relay_worker sending ws ~p", [Event]),
            ok = ws_send_json(S, [<<"EVENT">>, Event]),
            {noreply, S}
    end;
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({req_timeout, SubId}, S0 = #state{pending = Pending0}) ->
    case maps:get(SubId, Pending0, undefined) of
        undefined ->
            {noreply, S0};
        #{from := From, timer := TRef} ->
            _ = erlang:cancel_timer(TRef),
            gen_server:reply(From, {error, timeout}),
            _ = close_sub(S0, SubId),
            Pending = maps:remove(SubId, Pending0),
            {noreply, S0#state{pending = Pending}}
    end;
handle_info(ping, S0) ->
    S1 = ensure_connected(S0),
    S =
        case S1#state.connected of
            false ->
                S1;
            true ->
                %% WebSocket ping frame
                catch gun:ws_send(S1#state.conn_pid, S1#state.stream_ref, {ping, <<>>}),
                S1
        end,
    {noreply, schedule_ping(S)};
handle_info(reconnect, S0) ->
    {noreply, ensure_connected(S0#state{reconnect_tref = undefined})};
handle_info({'EXIT', Pid, Reason}, S0) ->
    %% Connection process died
    case S0#state.conn_pid of
        Pid ->
            ?LOG_WARNING("Relay connection died relay=~p reason=~p", [S0#state.relay, Reason]),
            {noreply, on_disconnect(S0)};
        _ ->
            {noreply, S0}
    end;
%% gun websocket traffic
handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, S0) ->
    S1 = S0#state{
        conn_pid = ConnPid,
        stream_ref = StreamRef,
        connected = true,
        backoff_ms = ?RECONNECT_MIN_MS
    },
    {noreply, schedule_ping(S1)};
handle_info({gun_ws, ConnPid, StreamRef, {pong, _Data}}, S0) when
    ConnPid =:= S0#state.conn_pid, StreamRef =:= S0#state.stream_ref
->
    {noreply, S0};
handle_info({gun_ws, ConnPid, StreamRef, {close, _}}, S0) when
    ConnPid =:= S0#state.conn_pid, StreamRef =:= S0#state.stream_ref
->
    {noreply, on_disconnect(S0)};
handle_info({gun_down, ConnPid, _Proto, _Reason, _Killed, _Unprocessed}, S0) when
    ConnPid =:= S0#state.conn_pid
->
    {noreply, on_disconnect(S0)};
handle_info({gun_ws, ConnPid, StreamRef, {text, Msg}}, S0) when
    ConnPid =:= S0#state.conn_pid, StreamRef =:= S0#state.stream_ref
->
    {noreply, handle_relay_msg(Msg, S0)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    %% Best effort close
    catch gun:close(S#state.conn_pid),
    ok.

%% ---------------------------
%% Relay message handling
%% ---------------------------

handle_relay_msg(MsgBin, S0 = #state{pending = Pending0}) ->
    %% Expect: ["EVENT", subid, event] or ["EOSE", subid]
    try
        Dec = jsx:decode(MsgBin, [{return_maps, true}]),
        case Dec of
            [<<"EVENT">>, SubId, Event] when is_binary(SubId), is_map(Event) ->
                case maps:get(SubId, Pending0, undefined) of
                    undefined ->
                        S0;
                    #{from := From, timer := TRef} ->
                        _ = erlang:cancel_timer(TRef),
                        gen_server:reply(From, {ok, Event}),
                        _ = close_sub(S0, SubId),
                        Pending = maps:remove(SubId, Pending0),
                        S0#state{pending = Pending}
                end;
            [<<"EOSE">>, SubId] when is_binary(SubId) ->
                case maps:get(SubId, Pending0, undefined) of
                    undefined ->
                        S0;
                    #{from := From, timer := TRef} ->
                        _ = erlang:cancel_timer(TRef),
                        gen_server:reply(From, {error, not_found}),
                        Pending = maps:remove(SubId, Pending0),
                        S0#state{pending = Pending}
                end;
            _ ->
                S0
        end
    catch
        _:E ->
            ?LOG_DEBUG("Bad relay msg relay=~p err=~p msg=~p", [S0#state.relay, E, MsgBin]),
            S0
    end.

close_sub(S, SubId) ->
    %% NIP-01: ["CLOSE", <subid>]
    ws_send_json(S, [<<"CLOSE">>, SubId]).
-spec publish_sync(pid(), map(), pos_integer()) -> ok | {error, term()}.
publish_sync(Pid, Event, TimeoutMs) ->
    gen_server:call(Pid, {publish, Event, TimeoutMs}, TimeoutMs + 500).

%% ---------------------------
%% Connection management
%% ---------------------------

ensure_connected(S0 = #state{connected = true}) ->
    S0;
ensure_connected(S0 = #state{reconnect_tref = TRef}) when is_reference(TRef) ->
    %% reconnect already scheduled
    S0;
ensure_connected(S0) ->
    case connect(S0) of
        {ok, S1} ->
            S1;
        {error, Reason} ->
            ?LOG_WARNING("Relay connect failed relay=~p reason=~p", [S0#state.relay, Reason]),
            schedule_reconnect(S0)
    end.

connect(S0 = #state{relay = Relay}) ->
    case damage_nostr:open_relay_ws(Relay, #{connect_timeout => 80000}) of
        {ok, ConnPid, StreamRef} ->
            link(ConnPid),
            {ok, S0#state{
                conn_pid = ConnPid,
                stream_ref = StreamRef,
                connected = true,
                backoff_ms = ?RECONNECT_MIN_MS
            }};
        {error, Reason} ->
            {error, Reason}
    end.

on_disconnect(S0 = #state{pending = Pending0}) ->
    %% Fail all pending
    maps:foreach(
        fun(SubId, #{from := From, timer := TRef}) ->
            _ = erlang:cancel_timer(TRef),
            gen_server:reply(From, {error, disconnected}),
            _ = SubId
        end,
        Pending0
    ),
    catch gun:close(S0#state.conn_pid),
    S1 = S0#state{
        conn_pid = undefined,
        stream_ref = undefined,
        connected = false,
        pending = #{}
    },
    schedule_reconnect(S1).

schedule_ping(S0 = #state{ping_tref = TRef}) when is_reference(TRef) ->
    S0;
schedule_ping(S0) ->
    TRef = erlang:send_after(?PING_MS, self(), ping),
    S0#state{ping_tref = TRef}.

schedule_reconnect(S0 = #state{reconnect_tref = TRef}) when is_reference(TRef) ->
    S0;
schedule_reconnect(S0 = #state{backoff_ms = Backoff}) ->
    Jitter = rand:uniform(250) - 1,
    Wait = min(?RECONNECT_MAX_MS, Backoff + Jitter),
    TRef = erlang:send_after(Wait, self(), reconnect),
    Next = min(?RECONNECT_MAX_MS, max(?RECONNECT_MIN_MS, Backoff * 2)),
    S0#state{reconnect_tref = TRef, backoff_ms = Next}.

ws_send_json(#state{conn_pid = ConnPid, stream_ref = StreamRef}, Term) ->
    %?LOG_DEBUG("nostr_relay_worker ws_send_json ~p", [Term]),
    gun:ws_send(ConnPid, StreamRef, {text, jsx:encode(Term)}),
    ok.

make_subid() ->
    %% Small unique subscription id
    <<I:64/integer>> = crypto:strong_rand_bytes(8),
    list_to_binary(io_lib:format("s~16.16.0b", [I])).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%% Minimal wss:// parser (wss/ws/http/https accepted; ws treated as non-tls)
parse_wss_url(UrlBin) ->
    Url = binary_to_list(to_bin(UrlBin)),
    try
        M = uri_string:parse(Url),
        Scheme = maps:get(scheme, M, "wss"),
        Host = maps:get(host, M, ""),
        Path0 =
            case maps:get(path, M, "/") of
                "" -> "/";
                P -> P
            end,

        Path =
            case maps:get(query, M, undefined) of
                undefined -> Path0;
                "" -> Path0;
                Q -> Path0 ++ "?" ++ Q
            end,
        Port0 = maps:get(port, M, undefined),
        Tls = (Scheme =:= "wss") orelse (Scheme =:= "https"),
        Port =
            case Port0 of
                undefined ->
                    if
                        Tls -> 443;
                        true -> 80
                    end;
                P0 ->
                    P0
            end,
        {ok, #{tls => Tls, host => Host, port => Port, path => Path}}
    catch
        _:E ->
            {error, {bad_relay_url, UrlBin, E}}
    end.
