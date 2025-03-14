-module(lightning_auth_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-define(SESSION_BUCKET, <<"ws_sessions_crdt">>).
-define(AUTH_BUCKET, <<"auth_links_crdt">>).
-record(state, {riak_conn}).

init(Req, _State) ->
    {cowboy_websocket, Req, #state{}}.

websocket_init(State) ->
    {ok, Pid} = riakc_pb_socket:start_link("127.0.0.1", 8087),
    {ok, State#state{riak_conn = Pid}}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps]) of
        #{<<"action">> := <<"auth_ln">>, <<"lnaddress">> := LnAddress} ->
            handle_ln_auth(LnAddress, State);
        #{<<"action">> := <<"check_payment">>, <<"lnaddress">> := LnAddress} ->
            handle_check_payment(LnAddress, State);
        #{<<"action">> := <<"link_nostr">>, <<"lnaddress">> := LnAddress, <<"npub">> := NostrPub} ->
            handle_link_nostr(LnAddress, NostrPub, State);
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
        {ok, SessionID} ->
            riakc_pb_socket:update_type(
                State#state.riak_conn,
                ?AUTH_BUCKET,
                LnAddress,
                {update, {map, [{update, <<"session">>, {assign, SessionID}}]}}
            ),
            {reply, {text, jsx:encode(#{status => <<"verified">>, session => SessionID})}, State};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{error => Reason})}, State}
    end.

handle_link_nostr(LnAddress, NostrPub, State) ->
    riakc_pb_socket:update_type(
        State#state.riak_conn,
        ?AUTH_BUCKET,
        LnAddress,
        {update, {map, [{update, <<"npub">>, {assign, NostrPub}}]}}
    ),
    {reply, {text, jsx:encode(#{status => <<"nostr_linked">>, npub => NostrPub})}, State}.

websocket_info(_Info, State) ->
    {ok, State}.
