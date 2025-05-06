-module(lightning_auth_ws).
-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-export([
         authenticate_socket/2
]).

-define(SESSION_BUCKET, <<"ws_sessions_crdt">>).
-define(AUTH_BUCKET, <<"auth_links_crdt">>).
-define(LNURL_AUTH_DOMAIN, "bitcoinonly.party").

init(Req, _State) ->
    {cowboy_websocket, Req, #{}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps]) of
        #{<<"action">> := <<"auth_ln">>} ->
            handle_ln_auth(State);
        #{<<"action">> := <<"check_payment">>, <<"lnaddress">> := LnAddress} ->
            handle_check_payment(LnAddress, State);
        Invalid ->
            ?LOG_DEBUG("Unhandled data on lightning_auth_ws ~p", [Invalid]),
            {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}
    end;
websocket_handle(Data, State) ->
    ?LOG_DEBUG("Unhandled data on lightning_auth_ws ~p", [Data]),
    {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}.

    

handle_ln_auth(State) ->
    case lightning_auth_logic:generate_lnurl_auth(?LNURL_AUTH_DOMAIN, "login") of
        {error, Reason} ->
            {reply, {text, jsx:encode(#{error => Reason})}, State};
        {K1, Url} ->
            lightning_auth_cache:store(K1, #{}),
            Reply = jsx:encode(#{status => <<"pending">>, invoice =>list_to_binary(Url) }),
            ?LOG_DEBUG("Reply ~p",[Reply]),
            gproc:reg_other({n, l, {?MODULE, K1}}, self()),
            {reply, {text, Reply}, State}
    end.

handle_check_payment(LnAddress, State) ->
    case lightning_auth_logic:verify_ln_payment(LnAddress) of
        {ok, verified} ->
            {reply, {text, jsx:encode(#{status => <<"verified">>})}, State};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{error => Reason})}, State}
    end.
websocket_info({authenticate, Key}, State) ->
    %% You can look up session metadata, register user, etc.
    ?LOG_INFO("Confirmed login via LNAuth for ~s", [Key]),
            Response = jsx:encode(#{status => <<"unregistered">>, pubkey => Key}),
            {reply, {text, Response}, State};
            


websocket_info(_Info, State) ->
    {ok, State}.
terminate(_Reason, _Req, _State) ->
    ok.

authenticate_socket(Challenge, Key) ->  
    
    case gproc:lookup_local_name({?MODULE, Challenge}) of
        undefined ->
            error;
        Pid ->
            Pid ! {authenticate, Key},
            ok
end.
