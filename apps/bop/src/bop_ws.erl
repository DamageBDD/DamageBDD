-module(bop_ws).

-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-include_lib("bop.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-define(SESSION_BUCKET, <<"ws_sessions_crdt">>).
-define(AUTH_BUCKET, <<"auth_links_crdt">>).

init(Req, _State) ->
    {cowboy_websocket, Req, #{}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps, {labels, atom}]) of
        #{action := <<"list_invoices">>} ->
            {reply, {text, jsx:encode(
                             #{
                               type => <<"list_invoices">>,
                               invoices => handle_list_payments(State),
                               total_funds => get_total()
                              })}, State};
        #{action := <<"request_invoice">>, amount:= Amount0} ->
            Amount = Amount0 * 1000,
            {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
            Label = list_to_binary("bop:" ++ Timestamp),
            %?LOG_INFO("creating invoice for ~p", [Amount]),
            #{
              payment_hash := PaymentHash,
              expires_at := _Expiry,
              bolt11 := Bolt11,
              payment_secret := _PaymentSecret,
              created_index := _CreatedIndex
             } = _Invoice = cln:create_invoice(Amount , <<"Bitcoin Only Party Australia Invoice">>, 3600, Label),
            %?LOG_INFO("invoice ws ~p", [Invoice]),
            gproc:reg_other({n, l, {?MODULE, PaymentHash}}, self()),
            {reply, {text, jsx:encode(#{type => <<"invoice">>, payment_request => Bolt11, payment_hash => PaymentHash})},  State};
        _ ->
            {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}
    end.

handle_list_payments( _State) ->
    Invoices = damage_ae:events(?BOP_VAULT_CONTRACT, 10),
    Invoices.

get_total() ->
    Result = bop:contract_call(
      "LightningProofRegistry",
      ?BOP_VAULT_CONTRACT,
      "get_total_sats",
      []).

websocket_info({invoice_paid,PaymentHash} = Info, State) ->
    ?LOG_INFO("bop ws info ~p", [Info]),
Reply = #{type => <<"paid">>, payment_hash => PaymentHash},
    {reply, {text, jsx:encode(Reply)}, State}.

