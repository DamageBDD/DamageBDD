-module(cln_ws_mgr).

-behaviour(gen_server).
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
-export([broadcast/2]).
-record(state, {
    conn_pid = undefined,
    streamref = undefined,
    cln_host = undefined,
    cln_port = undefined,
    cln_wspath = undefined,
    cln_certfile = undefined,
    cln_keyfile = undefined,
    rune = undefined,
    readonly_rune = undefined,
    retry_timer = undefined,
    secrets_ready = false,
    options :: map(),
    heartbeat_timer = undefined
}).

-define(CLN_HTTP_TIMEOUT, 300000).
-define(SECRETS_RETRY_MS, 60000).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

get_cln_client_config() ->
    {ok, Host} = application:get_env(damage, cln_host),
    {ok, Port} = application:get_env(damage, cln_port),
    {ok, Path} = application:get_env(damage, cln_wspath),
    {ok, CaCertFile} = application:get_env(damage, cln_cacertfile),
    {ok, CertFile} = application:get_env(damage, cln_certfile),
    {ok, KeyFile} = application:get_env(damage, cln_keyfile),
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
    #state{
        cln_host = Host,
        cln_port = Port,
        cln_wspath = Path,
        cln_certfile = CertFile,
        cln_keyfile = KeyFile,
        options = Options
    }.

start_link([ws]) -> gen_server:start_link(?MODULE, [ws], []).
init([ws]) ->
    case load_runes(get_cln_client_config()) of
        {ok, #state{secrets_ready = true} = State1} ->
            case start_ws(State1) of
                {ok, State2} ->
                    ?LOG_INFO("cln ws started"),
                    {ok, State2};
                Error ->
                    ?LOG_ERROR("cln ws error ~p", [Error]),
                    TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
                    {ok, State1#state{secrets_ready = false, retry_timer = TRef}}
            end;
        {ok, #state{secrets_ready = false, retry_timer = undefined} = State1} ->
            ?LOG_DEBUG("cln ws secrets not ready ~p", [State1]),
            TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
            {ok, State1#state{secrets_ready = false, retry_timer = TRef}};
        {error, Error} ->
            ?LOG_ERROR("cln ws error in init ~p", [Error]),
            TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
            State = get_cln_client_config(),
            {ok, State#state{secrets_ready = false, retry_timer = TRef}}
    end.
handle_call(Request, From, State) ->
    ?LOG_ERROR(
        "handle_call got unknown ~p, From ~p, State ~p",
        [Request, From, State]
    ),
    {reply, err, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("handle_cast got unknown on gun websocket cast ~p,  State ~p", [Msg, State]),
    {noreply, State}.

handle_info({gun_error, _ConnPid, _StreamRef, {badstate, "The stream cannot be found."}}, State) ->
    {noreply, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    ?LOG_ERROR(
        "got gun error ConnPid ~p, StreamRef ~p, \nReason ~p",
        [ConnPid, StreamRef, Reason]
    ),
    {noreply, State};
handle_info({gun_down, ConnPid, _Reason}, State) when
    ConnPid =:= State#state.conn_pid
->
    erlang:cancel_timer(State#state.heartbeat_timer),
    {stop, normal, State};
handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State) when
    StreamRef == State#state.streamref
->
    ?LOG_DEBUG("cln gun_upgrade upgraded ~p ", [StreamRef]),
    {noreply, State#state{conn_pid = ConnPid}};
handle_info({gun_up, _, _} = _Info, State) ->
    {noreply, State};
handle_info({gun_ws, ConnPid, StreamRef, {text, <<"2">>}}, State) ->
    gun:ws_send(
        ConnPid,
        StreamRef,
        {text, <<"3">>}
    ),
    {noreply, State};
handle_info({gun_ws, ConnPid, StreamRef, {text, Message0}}, State) ->
    Message = parse_socketio_message(Message0),
    handle_event(ConnPid, StreamRef, Message),
    {noreply, State};
handle_info({gun_ws, _, _, close} = _Info, State) ->
    {noreply, State};
handle_info(retry_secrets, State0) ->
    case load_runes(State0) of
        {ok, State1} ->
            %% cancel any existing retry timer
            maybe_cancel(State0#state.retry_timer),
            %% now actually connect
            case start_ws(State1#state{retry_timer = undefined, secrets_ready = true}) of
                {ok, State2} ->
                    {noreply, State2};
                {error, _} ->
                    %% if connect fails, you can also backoff here
                    TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
                    {noreply, State1#state{retry_timer = TRef, secrets_ready = false}}
            end;
        {error, _} ->
            TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
            {noreply, State0#state{retry_timer = TRef, secrets_ready = false}}
    end.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(Reason, State) ->
    maybe_close_gun(State#state.conn_pid),
    maybe_cancel(State#state.retry_timer),
    ?LOG_ERROR("Terminating cln_ws_mgr ~p", [Reason]),
    ok.
handle_event(
    _ConnPid,
    _StreamRef,
    [
        <<"message">>,
        #{
            custommsg :=
                #{
                    payload :=
                        _Payload,
                    peer_id :=
                        PeerId
                }
        }
    ] = _Message
) ->
    ?LOG_DEBUG("Unknown custommsg message from ~p", [PeerId]),
    ok;
handle_event(
    ConnPid,
    StreamRef,
    #{
        sid := _SessionId,
        upgrades := [],
        pingTimeout := _PingTimeout,
        pingInterval := _PingInteraval
    } = _Event
) ->
    gun:ws_send(
        ConnPid,
        StreamRef,
        {text, <<"40">>}
    );
handle_event(
    ConnPid,
    StreamRef,
    #{
        sid := _SessionId
    } = Event
) ->
    ?LOG_INFO("cln: subscribe = ~p", [Event]),
    Message0 = jsx:encode([<<"subscribe">>]),
    Message =
        <<"42", Message0/binary>>,
    ok =
        gun:ws_send(
            ConnPid,
            StreamRef,
            {text, Message}
        );
%% Inbound invoice was paid (authoritative)
handle_event(
    _ConnPid,
    _StreamRef,
    [
        <<"message">>,
        #{
            invoice_payment :=
                #{
                    label := Label,
                    preimage := Preimage,
                    msat := MSat
                } = Pay
        }
    ]
) ->
    ?LOG_INFO("cln: invoice_payment label=~p msat=~p", [Label, MSat]),
    %% Prefer matching by label (unique for our created invoices); fall back to hash if needed later.
    case cln:list_invoices_by_label(Label) of
        #{invoices := [Inv | _]} ->
            %% Enrich the invoice record with runtime facts and broadcast a single canonical event.
            PaidInv = Inv#{
                event => invoice_payment,
                details => Pay,
                preimage => Preimage,
                received_msat => MSat,
                paid_at_unix => erlang:system_time(second),
                status_runtime => <<"paid">>
            },
            ?LOG_INFO("received broadcast invoice_payment ~p", [PaidInv]),
            broadcast(invoice_paid, PaidInv);
        _ ->
            %% We didn't create/track this label locally (rare). Still surface a useful payload.
            Inv = #{
                label => Label,
                preimage => Preimage,
                received_msat => MSat,
                details => Pay
            },
            ?LOG_INFO("broadcast invoice_payment ~p", [Inv]),
            broadcast(invoice_paid, Inv)
    end;
handle_event(_ConnPid, _StreamRef, _UnknownEvent) ->
    ok.
load_runes(State) ->
    case {secrets:retrieve_decrypt(cln_rune), secrets:retrieve_decrypt(cln_readonly_rune)} of
        {{ok, Rune}, {ok, ReadOnly}} ->
            {ok, State#state{rune = Rune, readonly_rune = ReadOnly}};
        Error ->
            %% log once per retry tick (or rate-limit)
            {error, Error}
    end.

start_ws(
    #state{cln_host = Host, cln_port = Port, options = Opts, readonly_rune = ReadOnly} = State
) ->
    {ok, ConnPid} = gun:open(Host, Port, Opts),
    StreamRef = gun:ws_upgrade(ConnPid, "/socket.io/?EIO=4&transport=websocket", [
        {<<"rune">>, ReadOnly}
    ]),
    {ok, State#state{conn_pid = ConnPid, streamref = StreamRef}}.

maybe_cancel(undefined) ->
    ok;
maybe_cancel(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
    ok.

%broadcast(invoice_paid, Payload) ->
%    broadcast(invoice_paid, Payload);
broadcast(Topic, Payload) ->
    Message = {cln_event, Topic, Payload},
    ?LOG_DEBUG("Broadcast event ~p ~p", [Topic, Payload]),
    lists:foreach(
        fun(Pid) ->
            Pid ! Message
        end,
        gproc:lookup_pids({p, l, {cln_event, Topic}})
    ).
decode_payload(Payload) ->
    jsx:decode(Payload, [return_maps, {labels, atom}]).
parse_socketio_message(<<"0", Payload/binary>>) ->
    %% "42" is Socket.IO event prefix for normal message
    decode_payload(Payload);
parse_socketio_message(<<"40", Payload/binary>>) ->
    decode_payload(Payload);
parse_socketio_message(<<"42", Payload/binary>>) ->
    %% "42" is Socket.IO event prefix for normal message
    decode_payload(Payload);
parse_socketio_message(Other) ->
    Other.
