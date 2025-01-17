-module(cln).

-behaviour(gen_server).

%% API Functions

-export(
  [
    start_link/1,
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
-export([create_invoice/2, create_invoice/3]).

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
    rune = undefined,
    options :: map(),
    heartbeat_timer = undefined
  }
).

-define(DEFAULT_HTTP_TIMEOUT, 60000).

%% API Functions

start_link([]) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  ?LOG_INFO("clnconnect started"),
  {ok, Host} = application:get_env(damage, cln_host),
  {ok, Port} = application:get_env(damage, cln_port),
  {ok, Path} = application:get_env(damage, cln_wspath),
  {ok, CaCertFile} = application:get_env(damage, cln_cacertfile),
  {ok, CertFile} = application:get_env(damage, cln_certfile),
  {ok, KeyFile} = application:get_env(damage, cln_keyfile),
  Rune =
    case os:getenv("RUNE") of
      false -> exit(invoice_macaroon_env_not_set);
      Other -> Other
    end,
  RuneBin = list_to_binary(Rune),
  TLSOptions =
    [
      {certfile, CertFile},
      {keyfile, KeyFile},
      {cacertfile, CaCertFile},
      % This ensures the server's certificate is verified
      {verify, verify_peer},
      % Ensure compatibility with recent TLS versions
      {versions, ['tlsv1.2', 'tlsv1.3']},
      % HTTP2 or HTTP/1.1, depending on your setup
      {alpn_protocols, ['http/1.1', h2]}
    ],
  Options =
    case Host of
      "localhost" -> #{};
      _ -> #{transport => tls, tls_opts => TLSOptions}
    end,
  {ok, ConnPid} = gun:open(Host, Port, Options),
  StreamRef = gun:ws_upgrade(ConnPid, Path, [{<<"rune">>, RuneBin}]),
  %ok = gun:ws_send(ConnPid, StreamRef,  {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
  ?LOG_DEBUG("cln websocket upgrade successfull ~p", [ConnPid]),
  HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
  State =
    #state{
      cln_host = Host,
      cln_port = Port,
      cln_wspath = Path,
      cln_certfile = CertFile,
      cln_keyfile = KeyFile,
      rune = RuneBin,
      conn_pid = ConnPid,
      streamref = StreamRef,
      heartbeat_timer = HeartbeatTimer,
      options = Options
    },
  ?LOG_DEBUG("State ~p ", [State]),
  {ok, State}.


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
  #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
    State
) ->
  ?LOG_ERROR("got getinfo on gun websocket  State ~p", [State]),
  Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
  {ok, ConnPid} = gun:open(Host, Port, Options),
  %% Construct the API request URL
  Path = "/v1/getinfo",
  %% Construct the request body
  ReqJson = jsx:encode(#{}),
  %% Send the HTTP POST request
  StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
  {ok, Response} =
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
      {response, fin, Status, _RespHeaders} ->
        ?LOG_DEBUG("Got fin ~p", [Status]),
        no_data;

      {response, nofin, _Status, _RespHeaders} ->
        gun:await_body(ConnPid, StreamRef);

      {response, nofin, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
      Default -> ?LOG_DEBUG("Got unknown ~p ", [Default])
    end,
  ?LOG_DEBUG("Got getinfo response ~p", [Response]),
  Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
  %% Parse the response JSON
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the invoice details
  {reply, Invoice, State};

handle_call(
  {create_invoice, Amount, Description, Expiry},
  _From,
  #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
    State
) ->
  Headers = [{<<"Rune">>, Rune}, {<<"Content-Type">>, <<"application/json">>}],
  {ok, ConnPid} = gun:open(Host, Port, Options),
  %% Construct the API request URL
  Path = "/v1/invoice",
  %% Construct the request body
  {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
  Label = list_to_binary("asyncmind" ++ Timestamp),
  ReqJson =
    jsx:encode(
      #{
        amount_msat => Amount,
        label => Label,
        description => Description,
        expiry => Expiry
      }
    ),
  ?LOG_DEBUG("sending req head ~p ~p", [Headers, ReqJson]),
  %% Send the HTTP POST request
  StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
  {ok, Response} =
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
      {response, fin, Status, _RespHeaders} ->
        ?LOG_DEBUG("Got fin ~p", [Status]),
        no_data;

      {response, nofin, _Status, _RespHeaders} ->
        gun:await_body(ConnPid, StreamRef);

      {response, nofin, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
      Default -> ?LOG_DEBUG("Got unknown ~p ", [Default])
    end,
  ?LOG_DEBUG("Got create_invoice response ~p", [Response]),
  Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
  %% Parse the response JSON
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the invoice details
  {reply, Invoice, State};

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
  %ok = gun:ws_send(State#state.conn_pid, State#state.streamref,  {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
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

getinfo() ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, getinfo) end
  ).

subscribe_invoice(AddIndex, SettleIndex) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {subscribe_invoice, AddIndex, SettleIndex})
    end
  ).

create_invoice(Amount, Description) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {create_invoice, Amount, Description, 3600})
    end
  ).

create_invoice(Amount, Description, Expiry) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {create_invoice, Amount, Description, Expiry})
    end
  ).
