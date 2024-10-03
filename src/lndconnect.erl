-module(lndconnect).

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
-export([getinfo/0]).
-export([subscribe_invoice/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-record(
  state,
  {
    conn_pid = undefined,
    streamref = undefined,
    lnd_host = undefined,
    lnd_port = undefined,
    lnd_wspath = undefined,
    lnd_certfile = undefined,
    lnd_keyfile = undefined,
    macaroon = undefined,
    heartbeat_timer = undefined
  }
).

%% API Functions

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  ?LOG_INFO("lndconnect started"),
  {ok, Host} = application:get_env(damage, lnd_host),
  {ok, Port} = application:get_env(damage, lnd_port),
  {ok, Path} = application:get_env(damage, lnd_wspath),
  {ok, CertFile} = application:get_env(damage, lnd_certfile),
  {ok, KeyFile} = application:get_env(damage, lnd_keyfile),
  Macaroon =
    case os:getenv("MACAROON") of
      false -> exit(invoice_macaroon_env_not_set);
      Other -> Other
    end,
  State =
    #state{
      lnd_host = Host,
      lnd_port = Port,
      lnd_wspath = Path,
      lnd_certfile = CertFile,
      lnd_keyfile = KeyFile,
      macaroon = Macaroon
    },
  ?LOG_DEBUG("State ~p ", [State]),
  MacaroonBin = list_to_binary(Macaroon),
  % https://github.com/lightningnetwork/lnd/blob/master/docs/rest/websockets.md
  ProtocolString = <<"Grpc-Metadata-Macaroon+", MacaroonBin/binary>>,
  Options =
    case Host of
      "localhost" -> #{};
      %#{transport => tls, tls_opts => [{verify, none}, {cacertfile, CertFile}]};
      _ ->
        #{
          transport => tls,
          tls_opts => [{verify, verify_peer}, {cacertfile, CertFile}]
        }
    end,
  {ok, ConnPid} = gun:open(Host, Port, Options),
  gproc:reg_other({n, l, {?MODULE, lnd}}, self()),
  StreamRef =
    gun:ws_upgrade(
      ConnPid,
      Path,
      [
        {<<"Grpc-Metadata-Macaroon">>, MacaroonBin},
        {<<"sec-websocket-protocol">>, ProtocolString}
      ]
    ),
  %gun:ws_send(ConnPid, StreamRef, {text, "{}"}),
  ?LOG_DEBUG("lnd websocket upgrade successfull ~p", [ConnPid]),
  HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
  {
    ok,
    #state{
      conn_pid = ConnPid,
      streamref = StreamRef,
      heartbeat_timer = HeartbeatTimer
    }
  }.


handle_call(
  {subscribe_invoice, AddIndex, SettleIndex},
  _From,
  #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
  ok =
    gun:ws_send(
      ConnPid,
      StreamRef,
      {text, jsx:encode(#{add_index => AddIndex, settle_index => SettleIndex})}
    ),
  {reply, ok, State};

handle_call(
  getinfo,
  _From,
  #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
  ok = gun:ws_send(ConnPid, StreamRef, {text, "{}"}),
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


handle_event(#{result := #{state := <<"OPEN">>}} = Event) ->
  ?LOG_DEBUG("Invoice created or updated ~p", [Event]);

handle_event(
  #{
    result
    :=
    #{state := <<"SETTLED">>, memo := Memo, amt_paid_sat := AmountPaid0}
  } = Event
) ->
  [_, AeAccount] = string:split(Memo, " ", trailing),
  ?LOG_INFO("Invoice paid for ~p ~p", [AeAccount, Event]),
  AmountPaid = binary_to_integer(AmountPaid0),
  damage_ae:transfer_damage_tokens(AeAccount, damage:sats_to_damage(AmountPaid)),
  ?LOG_INFO("Damage Tokens transfered to ~p for ~p", [AeAccount]),
  {ok, SaleWebhook} = application:get_env(damage, sale_webhook),
  damage_webhooks:trigger_webhook(
    SaleWebhook,
    #{content => <<"Damage Tokens purchsased by ">>, ae_account => AeAccount}
  ),
  ok.


terminate(Reason, State) ->
  gun:shutdown(State#state.conn_pid),
  erlang:cancel_timer(State#state.heartbeat_timer),
  ?LOG_ERROR("Terminating lndconnect ~p", [Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

getinfo() -> gen_server:call(gproc:lookup_local_name({?MODULE, lnd}), getinfo).

subscribe_invoice(AddIndex, SettleIndex) ->
  gen_server:call(
    gproc:lookup_local_name({?MODULE, lnd}),
    {subscribe_invoice, AddIndex, SettleIndex}
  ).
