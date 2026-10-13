-module(bop_ws).

-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-include_lib("bop.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).
-export([test/0]).


init(Req, State) ->
    {cowboy_websocket, Req, State, #{idle_timeout => 60000}}. %% or higher
    %{cowboy_websocket, Req, #{}}.

websocket_init(State) ->
    erlang:send_after(30000, self(), ping),
    {ok, maps:put(keypair, bop:bop_keypair(),State)}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps, {labels, atom}]) of
        #{action := <<"list_invoices">>} ->
            Total = bop:get_total(?BOP_VAULT_CONTRACT),
            ?LOG_INFO("Total ~p", [Total]),
            GoalTotal = bop:get_goal(?BOP_VAULT_CONTRACT),
            ?LOG_INFO("GoalTotal ~p", [GoalTotal]),
            Invoices = handle_list_payments(State),
            ?LOG_INFO("Invoices ~p", [Invoices]),
            {reply, {text, jsx:encode(
                             #{
                               type => <<"list_invoices">>,
                               invoices => Invoices,
                               total_funds => Total,
                               goal_total_funds => GoalTotal,
                               contract_id => list_to_binary(?BOP_VAULT_CONTRACT)
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
        #{action := <<"get_price">>} ->
            {reply, {text, jsx:encode(#{type => <<"price">>, btc =>price_feed:get_price()})}, State};
        #{action := <<"ping">>} ->
            {reply, {text, jsx:encode(#{type => <<"pong">>})}, State};
        #{action := <<"pong">>} ->
            {reply, {text, jsx:encode(#{type => <<"pong">>})}, State};
        _ ->
            {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}
    end.


%decode_bytearray_fate(EncodedStr) ->
%    ?LOG_INFO("Decode ~p", [EncodedStr]),
%    Encoded = unicode:characters_to_binary(EncodedStr),
%    {contract_bytearray, Binary} = aeser_api_encoder:decode(Encoded),
%    case Binary of
%        <<>> -> {ok, none};
%        <<"Out of gas">> -> {error, out_of_gas};
%        
%        _ ->
%            % FIXME there may be other errors that are encoded directly into
%            % the byte array. We could try and catch to at least return
%            % *something* for cases that we don't already detect.
%            Object = aeb_fate_encoding:deserialize(Binary),
%            {ok, Object}
%    end.
handle_list_payments( #{keypair := KeyPair} =_State) ->
    [
     %decode_bytearray_fate(Data)
     #{msats => binary_to_integer(Msats),
       audm => binary_to_integer(AUDm),
       block_time => BlockTime,
       payment_hash => Data
      } || #{
        data := Data,
        args := [Msats, AUDm],
        block_time := BlockTime
       } <- damage_ae:get_events(
              KeyPair, ?BOP_VAULT_CONTRACT, 10)
    ].

%% websocket_info/2 – ping every 30s
websocket_info(ping, State) ->
    erlang:send_after(30000, self(), ping),
    {reply, {text, jsx:encode(#{type => <<"ping">>})}, State};

websocket_info({invoice_paid,PaymentHash} = Info, State) ->
    ?LOG_INFO("bop ws invoice_paid ~p", [Info]),
    Reply = #{type => <<"paid">>, payment_hash => PaymentHash},
    {reply, {text, jsx:encode(Reply)}, State}.

test() ->
   handle_list_payments(#{keypair =>bop:bop_keypair()}). 
