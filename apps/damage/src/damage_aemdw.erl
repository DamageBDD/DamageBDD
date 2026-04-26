-module(damage_aemdw).

-behaviour(gen_server).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(AEMDW_WEBSOCKET_HEARTBEAT, 60000).

-record(state, {
    conn_pid = undefined,
    streamref = undefined,
    heartbeat_timer = undefined,
    upgraded = false,
    host = undefined,
    port = undefined,
    path = undefined
}).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    ?LOG_INFO("damage_aemdw started"),
    case open_aemdw_ws() of
        {ok, Host, Port, ConnPid, StreamRef, PathPrefix} ->
            gproc:reg_other({n, l, {?MODULE, aemdw}}, self()),
            ?LOG_INFO(
                "aemdw websocket opened host=~p port=~p conn=~p stream=~p path=~p",
                [Host, Port, ConnPid, StreamRef, PathPrefix]
            ),
            HeartbeatTimer =
                erlang:send_after(?AEMDW_WEBSOCKET_HEARTBEAT, self(), heartbeat),
            {ok, #state{
                conn_pid = ConnPid,
                streamref = StreamRef,
                heartbeat_timer = HeartbeatTimer,
                upgraded = true,
                host = Host,
                port = Port,
                path = PathPrefix
            }};
        Err ->
            ?LOG_ERROR("Finding ae mdw ws node failed ~p", [Err]),
            {stop, {aemdw_ws_node_not_found, Err}}
    end.

open_aemdw_ws() ->
    {ok, Nodes} = application:get_env(damage, ae_mdw_ws_nodes),
    open_aemdw_ws(Nodes).

open_aemdw_ws([]) ->
    {error, no_aemdw_ws_nodes};
open_aemdw_ws([{Host, Port, PathPrefix} | Rest]) ->
    Opts = aemdw_ws_opts(Host, Port),
    case damage_gun:open_ws(Host, Port, PathPrefix, Opts) of
        {ok, ConnPid, StreamRef} ->
            {ok, Host, Port, ConnPid, StreamRef, PathPrefix};
        Error ->
            ?LOG_WARNING(
                "aemdw websocket open failed host=~p port=~p path=~p error=~p trying=~p",
                [Host, Port, PathPrefix, Error, Rest]
            ),
            open_aemdw_ws(Rest)
    end.

aemdw_ws_opts(Host, Port) ->
    Transport = aemdw_transport(Host, Port),
    #{
        transport => Transport,
        proxy => direct,
        connect_timeout => 15000,
        protocols => [http]
    }.

aemdw_transport(_Host, 443) -> tls;
aemdw_transport(_Host, 8443) -> tls;
aemdw_transport(_Host, _) -> tcp.

handle_call(
    ping,
    _From,
    #state{upgraded = true, conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Reply = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode(#{ok => <<"ping">>})}),
    {reply, Reply, State};
handle_call(ping, _From, State) ->
    {reply, {error, websocket_not_upgraded}, State};
handle_call(Request, From, State) ->
    ?LOG_ERROR(
        "got unknown on gun websocket Call ~p, From ~p, State ~p",
        [Request, From, State]
    ),
    {reply, err, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("got unknown on gun websocket cast ~p, State ~p", [Msg, State]),
    {noreply, State}.

handle_info(
    {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers},
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    %% damage_gun:open_ws/4 already waited for this during init,
    %% but keep this clause harmless if Gun delivers it later.
    ?LOG_INFO("aemdw websocket upgraded conn=~p stream=~p", [ConnPid, StreamRef]),
    {noreply, State#state{upgraded = true}};
handle_info(
    {gun_response, ConnPid, _, _, Status, Headers},
    State = #state{conn_pid = ConnPid}
) ->
    ?LOG_DEBUG(
        "got message on gun websocket ConnPid ~p, Status ~p Headers ~p",
        [ConnPid, Status, Headers]
    ),
    {noreply, State};
handle_info(
    {gun_error, ConnPid, StreamRef, Reason},
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    ?LOG_ERROR(
        "aemdw websocket error conn=~p stream=~p reason=~p",
        [ConnPid, StreamRef, Reason]
    ),
    {stop, {websocket_error, Reason}, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    ?LOG_DEBUG(
        "ignoring stale gun_error conn=~p stream=~p reason=~p state=~p",
        [ConnPid, StreamRef, Reason, State]
    ),
    {noreply, State};
handle_info(
    heartbeat,
    #state{upgraded = true, conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    case gun:ws_send(ConnPid, StreamRef, {ping, <<>>}) of
        ok ->
            Timer = erlang:send_after(?AEMDW_WEBSOCKET_HEARTBEAT, self(), heartbeat),
            {noreply, State#state{heartbeat_timer = Timer}};
        Error ->
            ?LOG_ERROR("aemdw heartbeat failed ~p", [Error]),
            {stop, {heartbeat_failed, Error}, State}
    end;
handle_info(heartbeat, State) ->
    ?LOG_DEBUG("aemdw heartbeat skipped; websocket not upgraded yet"),
    {noreply, State};
handle_info(
    {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
    #state{conn_pid = ConnPid} = State
) ->
    ?LOG_ERROR("aemdw gun_down conn=~p reason=~p", [ConnPid, Reason]),
    cancel_timer(State#state.heartbeat_timer),
    {stop, {gun_down, Reason}, State};
handle_info(
    {gun_ws, ConnPid, StreamRef, {text, Message0}},
    #state{
        conn_pid = ConnPid,
        streamref = StreamRef
    } = State
) ->
    Message = jsx:decode(Message0, [return_maps, {labels, atom}]),
    ?LOG_DEBUG("got aemdw message ~p", [Message]),
    ok = handle_event(Message),
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("damage_aemdw got unknown on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State}.

terminate(Reason, State) ->
    maybe_close_gun(State#state.conn_pid),
    cancel_timer(State#state.heartbeat_timer),
    ?LOG_ERROR("Terminating damage_aemdw ~p", [Reason]),
    ok.

maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
    ok.

cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_event(#{result := #{state := <<"OPEN">>}} = Event) ->
    ?LOG_DEBUG("Invoice created or updated ~p", [Event]),
    ok;
handle_event(Event) ->
    ?LOG_DEBUG("Unhandled aemdw event ~p", [Event]),
    ok.
