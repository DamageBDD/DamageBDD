-module(cln).


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
    cln_host = undefined,
    cln_port = undefined,
    cln_wspath = undefined,
    cln_certfile = undefined,
    cln_keyfile = undefined,
    macaroon = undefined,
    heartbeat_timer = undefined
  }
).

%% API Functions

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  ?LOG_INFO("clnconnect started"),
  {ok, Host} = application:get_env(damage, cln_host),
  {ok, Port} = application:get_env(damage, cln_port),
  {ok, Path} = application:get_env(damage, cln_wspath),
  {ok, CaCertFile} = application:get_env(damage, cln_cacertfile),
  {ok, CertFile} = application:get_env(damage, cln_certfile),
  {ok, KeyFile} = application:get_env(damage, cln_keyfile),
  Macaroon =
    case os:getenv("MACAROON") of
      false -> exit(invoice_macaroon_env_not_set);
      Other -> Other
    end,
  State =
    #state{
      cln_host = Host,
      cln_port = Port,
      cln_wspath = Path,
      cln_certfile = CertFile,
      cln_keyfile = KeyFile,
      macaroon = Macaroon
    },
  ?LOG_DEBUG("State ~p ", [State]),
    TLSOptions = [
        {certfile, CertFile},
        {keyfile, KeyFile},
        {cacertfile, CaCertFile},
        {verify, verify_peer},   % This ensures the server's certificate is verified
        {versions, ['tlsv1.2', 'tlsv1.3']},  % Ensure compatibility with recent TLS versions
        {alpn_protocols, ['http/1.1', 'h2']} % HTTP2 or HTTP/1.1, depending on your setup
    ],
  Options =
    case Host of
      "localhost" -> #{};
      _ ->
        #{
          transport => tls,
          tls_opts => TLSOptions
        }
    end,
  {ok, ConnPid} = gun:open(Host, Port, Options),
  gproc:reg_other({n, l, {?MODULE, cln}}, self()),
  StreamRef =
    gun:ws_upgrade(
      ConnPid,
      Path,
      [
      ]
    ),
  %ok = gun:ws_send(ConnPid, StreamRef,  {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
  ?LOG_DEBUG("cln websocket upgrade successfull ~p", [ConnPid]),
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
  ?LOG_ERROR(
    "got getinfo on gun websocket  State ~p",
    [ State]
  ),
  ok = gun:ws_send(ConnPid, StreamRef, {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
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
  ok = gun:ws_send(State#state.conn_pid, State#state.streamref,  {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
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
  ?LOG_ERROR("Terminating clnconnect ~p", [Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

getinfo() -> gen_server:call(gproc:lookup_local_name({?MODULE, cln}), getinfo).

subscribe_invoice(AddIndex, SettleIndex) ->
  gen_server:call(
    gproc:lookup_local_name({?MODULE, cln}),
    {subscribe_invoice, AddIndex, SettleIndex}
  ).
