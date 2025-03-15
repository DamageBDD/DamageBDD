-module(lightning_auth_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-define(SESSION_BUCKET, <<"ws_sessions_crdt">>).
-define(AUTH_BUCKET, <<"auth_links_crdt">>).

init(Req, _State) ->
    {cowboy_websocket, Req, #{}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps]) of
        #{<<"action">> := <<"auth_ln">>, <<"lnaddress">> := LnAddress} ->
            handle_ln_auth(LnAddress, State);
        #{<<"action">> := <<"check_payment">>, <<"lnaddress">> := LnAddress} ->
            handle_check_payment(LnAddress, State);
        _ ->
            {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}
    end.

handle_ln_auth(LnAddress, State) ->
    case lightning_auth_logic:generate_ln_invoice(LnAddress) of
        {ok, Invoice} ->
            {reply, {text, jsx:encode(#{status => <<"pending">>, invoice => Invoice})}, State};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{error => Reason})}, State}
    end.

handle_check_payment(LnAddress, State) ->
    case lightning_auth_logic:verify_ln_payment(LnAddress) of
        {ok, verified} ->
            {reply, {text, jsx:encode(#{status => <<"verified">>})}, State};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{error => Reason})}, State}
    end.

websocket_info(_Info, State) ->
    {ok, State}.
