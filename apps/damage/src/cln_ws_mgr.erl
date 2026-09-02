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
-define(SECRETS_RETRY_MS, 10000).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-export([
    get_cln_client_config/0
]).

get_cln_client_config() ->
    case damage_cln:missing_websocket_config() of
        [] ->
            Host = application:get_env(damage, cln_host, undefined),
            Port = application:get_env(damage, cln_port, undefined),
            Path = application:get_env(damage, cln_wspath, undefined),
            CaCertFile = application:get_env(damage, cln_cacertfile, undefined),
            CertFile = application:get_env(damage, cln_certfile, undefined),
            KeyFile = application:get_env(damage, cln_keyfile, undefined),
            TLSOptions =
                [
                    {certfile, CertFile},
                    {keyfile, KeyFile},
                    {cacertfile, CaCertFile},
                    {verify, verify_peer},
                    {versions, ['tlsv1.2', 'tlsv1.3']},
                    {alpn_protocols, ['http/1.1', h2]}
                ],
            Options =
                case Host of
                    "localhost" -> #{};
                    <<"localhost">> -> #{};
                    "127.0.0.1" -> #{};
                    <<"127.0.0.1">> -> #{};
                    _ -> #{transport => tls, tls_opts => TLSOptions}
                end,
            {ok,
                #state{
                    cln_host = Host,
                    cln_port = Port,
                    cln_wspath = Path,
                    cln_certfile = CertFile,
                    cln_keyfile = KeyFile,
                    options = Options
                }};
        Missing ->
            {error, {missing_cln_websocket_config, Missing}}
    end.

start_link([ws]) -> gen_server:start_link(?MODULE, [ws], []).

%% init/1 deliberately never connects synchronously. A dead CLN websocket must
%% not be able to fail damage_cln_sup startup or consume supervisor intensity.
init([ws]) ->
    self() ! retry_secrets,
    {ok, #state{}}.

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
handle_info({gun_down, ConnPid, _Reason}, State = #state{conn_pid = ConnPid}) ->
    ?LOG_WARNING("cln websocket connection down; reconnecting", []),
    {noreply, schedule_retry(clear_connection(State))};
handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State) when
    StreamRef == State#state.streamref
->
    ?LOG_DEBUG("cln gun_upgrade upgraded ~p ", [StreamRef]),
    {noreply, State#state{conn_pid = ConnPid}};
handle_info({gun_up, _, _}, State) ->
    {noreply, State};
handle_info(
    {gun_ws, ConnPid, StreamRef, {text, <<"2">>}},
    State = #state{conn_pid = ConnPid, streamref = StreamRef}
) ->
    _ = catch gun:ws_send(ConnPid, StreamRef, {text, <<"3">>}),
    {noreply, State};
handle_info(
    {gun_ws, ConnPid, StreamRef, {text, Message0}},
    State = #state{conn_pid = ConnPid, streamref = StreamRef}
) ->
    Message = parse_socketio_message(Message0),
    handle_event(ConnPid, StreamRef, Message),
    {noreply, State};

handle_info(
    {gun_ws, ConnPid, StreamRef, close},
    State = #state{conn_pid = ConnPid, streamref = StreamRef}
) ->
    ?LOG_WARNING("cln websocket closed; reconnecting", []),
    {noreply, schedule_retry(clear_connection(State))};
handle_info(
    {gun_down, ConnPid, ws, _Reason, _Ref},
    State = #state{conn_pid = ConnPid}
) ->
    ?LOG_WARNING("cln websocket gun_down; reconnecting", []),
    {noreply, schedule_retry(clear_connection(State))};
handle_info(retry_secrets, State0) ->
    State1 = cancel_retry(State0),
    case get_cln_client_config() of
        {ok, ConfigState0} ->
            case load_runes(ConfigState0) of
                {ok, ConfigState1} ->
                    case start_ws(ConfigState1#state{secrets_ready = true}) of
                        {ok, State2} ->
                            ?LOG_INFO("cln websocket connected"),
                            {noreply, State2};
                        {error, Reason} ->
                            ?LOG_WARNING("cln websocket unavailable; retrying: ~p", [Reason]),
                            {noreply, schedule_retry(ConfigState1#state{secrets_ready = true})}
                    end;
                {error, Reason} ->
                    ?LOG_DEBUG("cln websocket secrets unavailable: ~p", [Reason]),
                    {noreply, schedule_retry(ConfigState0#state{secrets_ready = false})}
            end;
        {error, Reason} ->
            ?LOG_WARNING("cln websocket disabled/unconfigured for now: ~p", [Reason]),
            {noreply, schedule_retry(State1#state{secrets_ready = false})}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

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
                        _PeerId
                }
        }
    ] = _Message
) ->
    %?LOG_DEBUG("Unknown custommsg message from ~p", [PeerId]),
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
    case damage_cln:list_invoices_by_label(Label) of
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
            ?LOG_INFO("received broadcast invoice_payment ~p", [Pay]),
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
    case damage_gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            case damage_gun:ws_upgrade(
                ConnPid,
                "/socket.io/?EIO=4&transport=websocket",
                [{<<"rune">>, ReadOnly}]
            ) of
                {ok, StreamRef} ->
                    {ok, State#state{conn_pid = ConnPid, streamref = StreamRef}};
                {error, Reason} ->
                    maybe_close_gun(ConnPid),
                    {error, {websocket_upgrade_failed, Reason}};
                Other ->
                    maybe_close_gun(ConnPid),
                    {error, {unexpected_websocket_upgrade_result, Other}}
            end;
        {error, Reason} ->
            {error, {cln_connection_failed, Reason}};
        Other ->
            {error, {unexpected_cln_open_result, Other}}
    end.

schedule_retry(State = #state{retry_timer = undefined}) ->
    TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
    State#state{retry_timer = TRef};
schedule_retry(State) ->
    State.

cancel_retry(State = #state{retry_timer = undefined}) ->
    State;
cancel_retry(State = #state{retry_timer = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{retry_timer = undefined}.

clear_connection(State) ->
    maybe_close_gun(State#state.conn_pid),
    maybe_cancel(State#state.heartbeat_timer),
    State#state{
        conn_pid = undefined,
        streamref = undefined,
        heartbeat_timer = undefined
    }.

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
