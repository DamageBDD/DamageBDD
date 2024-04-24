-module(lnd).

-behaviour(gen_server).
-behaviour(poolboy_worker).
-include_lib("kernel/include/logger.hrl").

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

%% API functions

-export(
  [
    create_invoice/2,
    get_invoice/1,
    list_invoices/0,
    list_invoices/1,
    cancel_invoice/1
  ]
).
-export([test/0]).

%% State record

-record(
  state,
  {
    base_url :: string(),
    headers :: list(),
    options :: map(),
    host :: string(),
    port :: integer()
  }
).

-define(DEFAULT_HTTP_TIMEOUT, 60000).

%% Start the server

start_link([]) -> gen_server:start_link(?MODULE, [], []).

%% Initialize the server

init([]) ->
  {ok, Host} = application:get_env(damage, lnd_host),
  {ok, Port} = application:get_env(damage, lnd_port),
  %{ok, CertFile} = application:get_env(damage, lnd_certfile),
  %{ok, KeyFile} = application:get_env(damage, lnd_keyfile),
  Macaroon =
    case os:getenv("MACAROON") of
      false -> exit(invoice_macaroon_env_not_set);
      Other -> Other
    end,
  %% Start the gun HTTP client
  BaseUrl = "https://" ++ Host ++ ":" ++ integer_to_list(Port),
  Headers = [{<<"Grpc-Metadata-Macaroon">>, Macaroon}],
  Options =
    #{
      transport => tls,
      tls_opts
      =>
      [
        {verify, verify_peer},
        {cacertfile, "/etc/ssl/certs/ca-certificates.crt"}
      ]
    },
  {
    ok,
    #state{
      host = Host,
      port = Port,
      base_url = BaseUrl,
      headers = Headers,
      options = Options
    }
  }.

%% API function to create Lightning invoice

create_invoice(Amount, Description) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) -> gen_server:call(Worker, {create_invoice, Amount, Description})
    end
  ).

%% API function to get Lightning invoice

get_invoice(InvoiceId) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {get_invoice, InvoiceId}) end
  ).

%% API function to list all Lightning invoices

list_invoices(Args) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {list_invoices, Args}) end
  ).

list_invoices() ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, list_invoices) end
  ).

cancel_invoice(InvoiceId) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {cancel_invoice, InvoiceId}) end
  ).

%% Handle call requests

handle_call(
  {create_invoice, Amount, Description},
  _From,
  #state{host = Host, port = Port, headers = Headers, options = Options} = State
) ->
  {ok, ConnPid} = gun:open(Host, Port, Options),
  %% Construct the API request URL
  Path = "/v1/invoices",
  %% Construct the request body
  ReqData = #{memo => Description, value => Amount, expiry => 3600},
  ReqJson = json_encode(ReqData),
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
  %% Parse the response JSON
  Invoice = json_decode(Response),
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the invoice details
  {reply, Invoice, State};

handle_call(
  {get_invoice, InvoiceId},
  _From,
  #state{host = Host, port = Port, options = Options, headers = Headers} = State
) ->
  {ok, ConnPid} = gun:open(Host, Port, Options),
  %% Construct the API request URL
  Path = lists:concat(["/v1/invoice/", binary_to_list(InvoiceId)]),
  ?LOG_DEBUG("path ~p", [Path]),
  %% Send the HTTP GET request
  StreamRef = gun:get(ConnPid, Path, Headers),
  Response =
    case gun:await(ConnPid, StreamRef) of
      {response, fin, _Status, _Headers0} -> no_data;

      {response, nofin, _Status, _Headers0} ->
        {ok, Body} = gun:await_body(ConnPid, StreamRef),
        Body
    end,
  %% Parse the response JSON
  ?LOG_DEBUG("Got invoices ~p ", [Response]),
  Invoice = json_decode(Response),
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the invoice details
  {reply, Invoice, State};

handle_call(list_invoices, From, State) ->
  handle_call({list_invoices, []}, From, State);

handle_call(
  {list_invoices, Args},
  _From,
  #state{host = Host, port = Port, options = Options, headers = Headers} = State
) ->
  {ok, ConnPid} = gun:open(Host, Port, Options),
  QueryString =
    lists:flatten(["?" ++ Key ++ "=" ++ Value ++ "&" || {Key, Value} <- Args]),
  %% Construct the API request URL
  Path = "/v1/invoices" ++ QueryString,
  %% Send the HTTP GET request
  StreamRef = gun:get(ConnPid, Path, Headers),
  Response =
    case gun:await(ConnPid, StreamRef) of
      {response, fin, _Status, _Headers0} -> no_data;

      {response, nofin, _Status, _Headers0} ->
        {ok, Body} = gun:await_body(ConnPid, StreamRef),
        Body
    end,
  %% Parse the response JSON
  ?LOG_DEBUG("Got invoices ~p ", [Response]),
  #{<<"invoices">> := Invoices} = json_decode(Response),
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the list of invoices
  {reply, Invoices, State};

handle_call(
  {cancel_invoice, PaymentHash},
  _From,
  #state{host = Host, port = Port, headers = Headers, options = Options} = State
) ->
  {ok, ConnPid} = gun:open(Host, Port, Options),
  %% Construct the API request URL
  Path = "/v2/invoices/cancel/",
  %% Construct the request body
  ReqData = #{payment_hash => PaymentHash},
  ReqJson = json_encode(ReqData),
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
  %% Parse the response JSON
  Invoice = json_decode(Response),
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  %% Return the invoice details
  {reply, Invoice, State}.

%% Handle cast requests

handle_cast(_Msg, State) -> {noreply, State}.

%% Handle system messages

handle_info(Info, State) ->
  ?LOG_DEBUG("Got info ~p ", [Info]),
  {noreply, State}.

%% Terminate the server

terminate(_Reason, _State) -> ok.

%% Handles code changes

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Encodes Erlang terms to JSON

json_encode(Term) -> iolist_to_binary(jsx:encode(Term)).

%% Decodes JSON to Erlang terms

json_decode(Json) -> jsx:decode(Json).

test() ->
  URL = "https://127.0.0.1:8011/v1/invoices",
  Macaroon =
    case os:getenv("MACAROON") of
      false -> exit(invoice_macaroon_env_not_set);
      Other -> Other
    end,
  Headers = [{"Grpc-Metadata-Macaroon", Macaroon}],
  Options = [{ssl, [{depth, 1}, {cacerts, "/var/lib/lnd/tls.cert"}]}],
  %Request = {URL, Headers, "application/json", [], get, [], Options},
  case httpc:request(get, {URL, Headers}, Options, []) of
    {ok, {{_Status, _Headers, _Version}, Body}} ->
      io:format("Response Body: ~p~n", [Body]);

    {error, Reason} -> io:format("Request failed: ~p~n", [Reason])
  end.
