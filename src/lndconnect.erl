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
-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TIMEOUT, 5000).

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
    macaroon = undefined
  }
).

%% API Functions

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  logger:info("lndconnect started"),
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
  case
  gun:open(
    Host,
    Port,
    #{
      transport => tls,
      tls_opts
      =>
      [
        {verify, verify_peer},
        {cacertfile, "/etc/ssl/certs/ca-certificates.crt"}
      ]
    }
  ) of
    {ok, ConnPid} ->
      gproc:reg_other({n, l, {?MODULE, lnd}}, ConnPid),
      StreamRef =
        gun:ws_upgrade(
          ConnPid,
          Path,
          [
            {<<"Grpc-Metadata-Macaroon">>, MacaroonBin},
            {<<"sec-websocket-protocol">>, ProtocolString}
          ]
        ),
      gun:ws_send(ConnPid, StreamRef, {text, <<"{}">>}),
      ?LOG_DEBUG("Got success ~p", [ConnPid]),
      {ok, State#state{streamref = StreamRef}};

    {error, Reason} ->
      ?LOG_DEBUG("Got error ~p", [Reason]),
      {{error, Reason}, State};

    Reason ->
      ?LOG_DEBUG("Got error ~p", [Reason]),
      {{error, Reason}, State}
  end.


handle_call(
  getinfo,
  _From,
  #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
  case gun:ws_send(ConnPid, StreamRef, {text, "{}"}) of
    {ok, ConnPid} ->
      ?LOG_DEBUG("gun send ~p ", [ConnPid]),
      {reply, ok, State};

    Other ->
      ?LOG_DEBUG("gun send error  ~p ", [Other]),
      {reply, Other, State}
  end;

handle_call(Request, From, State) ->
  logger:error(
    "got unknown on gun websocket Call ~p, From ~p, State ~p",
    [Request, From, State]
  ),
  {reply, ok, State}.


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
  logger:error(
    "got message on gun websocket ConnPid ~p, \nStatus ~p Headers ~p",
    [ConnPid, Status, Headers]
  ),
  {noreply, State};

handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
  logger:error(
    "got error on gun websocket ConnPid ~p, StreamRef ~p, \nReason ~p",
    [ConnPid, StreamRef, Reason]
  ),
  {noreply, State};

handle_info(Info, State) ->
  logger:error("got unknown on gun websocket Info ~p, State ~p", [Info, State]),
  {noreply, State}.


terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

getinfo() -> gen_server:call(gproc:lookup_local_name({?MODULE, lnd}), getinfo).
