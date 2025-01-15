-module(cln).

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export(
  [
    create_invoice/2,
    create_invoice/3,
    get_invoice/1,
    list_invoices/0,
    list_invoices/1,
    cancel_invoice/1,
    settle_invoice/1,
    add_hold_invoice/3
  ]
).
-export([test/0]).

-include_lib("kernel/include/logger.hrl").

init(Req, Opts) -> {cowboy_websocket, Req, Opts}.

websocket_init(State) ->
  ?LOG_INFO("websocket_handle init ~p", [State]),
  gproc:reg_other({n, l, {?MODULE, cln}}, self()),
  {[], #{}}.


websocket_handle({text, Data}, State) ->
  ?LOG_DEBUG("websocket_handle text ~p", [Data]),
  #{id := Id} = Msg = jsx:decode(Data, [{labels, atom}]),
  ?LOG_DEBUG("websocket_handle text decoded ~p", [Msg]),
  {[{text, jsonrpc_handle(Msg)}], maps:put(jsonrpc_id, Id, State)}.


websocket_info({timeout, _Ref, Msg}, State) ->
  ?LOG_DEBUG("websocket_info ~p ~p", [Msg, State]),
  {reply, {text, Msg}, State};

websocket_info(Info, State) ->
  ?LOG_DEBUG("Unknown websocket_info ~p ~p", [Info, State]),
  {[], State}.


jsonrpc_handle(
  #{
    id := Id,
    params
    :=
    #{
      options := #{},
      configuration
      :=
      #{
        'lightning-dir' := LightningDir,
        'rpc-file' := RpcFile,
        startup := true,
        network := <<"bitcoin">>,
        feature_set
        :=
        #{
          init := <<"08a0880a8a59a1">>,
          node := <<"88a0880a8a59a1">>,
          invoice := <<"02000002024100">>,
          channel := <<>>
        }
      }
    },
    method := <<"init">>,
    jsonrpc := <<"2.0">>
  }
) ->
  ?LOG_DEBUG("Got init from cln ~p ~p", [LightningDir, RpcFile]),
  jsx:encode(#{jsonrpc => <<"2.0">>, result => [], id => Id});

jsonrpc_handle(
  #{
    id := Id,
    params := #{'allow-deprecated-apis' := true},
    method := <<"getmanifest">>,
    jsonrpc := <<"2.0">>
  }
) ->
  Manifest =
    #{
      options => [],
      rpcmethods => [],
      subscriptions
      =>
      [<<"deprecated_oneshot">>, <<"connect">>, <<"disconnect">>],
      hooks => [],
      featurebits => #{},
      notifications => [],
      custommessages => [],
      nonnumericids => true,
      cancheck => true,
      dynamic => true
    },
  jsx:encode(#{jsonrpc => <<"2.0">>, result => Manifest, id => Id}).

%% API function to create Lightning invoice

add_hold_invoice(Amount, Label, Description) ->
  Lnd = gproc:lookup_local_name({?MODULE, cln}),
  Msg =
    jsx:encode(
      #{
        jsonrpc => <<"2.0">>,
        method => <<"invoice">>,
        params => [Amount, Label, Description],
        id => "22"
      }
    ),
  Lnd ! Msg.


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

settle_invoice(PaymentRequest) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) -> gen_server:call(Worker, {settle_invoice, PaymentRequest})
    end
  ).

test() -> ok.
