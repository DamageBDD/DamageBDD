-module(damage_aemdw).

-behaviour(gen_server).

%% API Functions

-export(
  [
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% API Functions

-record(
  state,
  {conn_pid = undefined, streamref = undefined, heartbeat_timer = undefined}
).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  ?LOG_INFO("damage_aemdw started"),
  case damage_ae:get_ae_mdw_ws_node() of
    {ok, ConnPid, PathPrefix} ->
      gproc:reg_other({n, l, {?MODULE, aemdw}}, self()),
      StreamRef = gun:ws_upgrade(ConnPid, PathPrefix, []),
      ?LOG_DEBUG("aemdw websocket upgrade successfull ~p", [ConnPid]),
      HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
      {
        ok,
        #state{
          conn_pid = ConnPid,
          streamref = StreamRef,
          heartbeat_timer = HeartbeatTimer
        }
      };

    Err ->
      ?LOG_DEBUG("Finding ae mdw ws node failed ~p", [Err]),
      {reply, {error, not_found}, #{}}
  end.


handle_call(
  ping,
  _From,
  #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
  ok = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode(#{ok => <<"ping">>})}),
  {reply, ok, State};

handle_call(Request, From, State) ->
  ?LOG_ERROR(
    "got unknown on gun websocket Call ~p, From ~p, State ~p",
    [Request, From, State]
  ),
  {reply, err, State}.


handle_cast(Msg, State) ->
  ?LOG_DEBUG("got unknown on gun websocket cast ~p,  State ~p", [Msg, State]),
  {noreply, State}.


handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State)
when StreamRef == State#state.streamref ->
  ?LOG_DEBUG("upgraded ~p ", [StreamRef]),
  {noreply, State#state{conn_pid = ConnPid}};

handle_info(
  {gun_response, ConnPid, _, _, Status, Headers},
  State = #state{conn_pid = ConnPid}
) ->
  ?LOG_DEBUG(
    "got message on gun websocket ConnPid ~p, \nStatus ~p Headers ~p",
    [ConnPid, Status, Headers]
  ),
  {noreply, State};

handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
  ?LOG_ERROR(
    "got error on gun websocket ConnPid ~p, StreamRef ~p, \nReason ~p",
    [ConnPid, StreamRef, Reason]
  ),
  {noreply, State};

handle_info(heartbeat, State) ->
  %% Send a ping message to check the connection
  ok = gun:ws_send(State#state.conn_pid, State#state.streamref, {ping, <<>>}),
  %% Reset the heartbeat timer
  HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
  {noreply, State#state{heartbeat_timer = HeartbeatTimer}};

handle_info({gun_down, ConnPid, _Reason}, State)
when ConnPid =:= State#state.conn_pid ->
  io:format("Connection closed~n"),
  erlang:cancel_timer(State#state.heartbeat_timer),
  {stop, normal, State};

handle_info({gun_ws, _, _, {text, Message0}} = Info, State) ->
  ?LOG_DEBUG("got known on gun websocket Info ~p, State ~p", [Info, State]),
  Message = jsx:decode(Message0, [return_maps, {labels, atom}]),
  ?LOG_DEBUG("got message ~p", [Message]),
  ok = handle_event(Message),
  {noreply, State};

handle_info(Info, State) ->
  ?LOG_DEBUG("got unknown on gun websocket Info ~p, State ~p", [Info, State]),
  {noreply, State}.


terminate(Reason, State) ->
  gun:shutdown(State#state.conn_pid),
  erlang:cancel_timer(State#state.heartbeat_timer),
  ?LOG_ERROR("Terminating lndconnect ~p", [Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_event(#{result := #{state := <<"OPEN">>}} = Event) ->
  ?LOG_DEBUG("Invoice created or updated ~p", [Event]).
