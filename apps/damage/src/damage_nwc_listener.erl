-module(damage_nwc_listener).

-author("OpenAI").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    publish_info/0,
    supported_methods/0,
    get_state/0,
    state_summary/0,
    add_relays/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([restart/0]).
-export([handle_continue/2]).

-define(DEFAULT_MAX_RECONNECT_MS, 60000).
-define(DEFAULT_HEALTHCHECK_MS, 30000).
-define(DEFAULT_RECONNECT_MS, 5000).
-define(INFO_KIND, 13194).
-define(REQUEST_KIND, 23194).
-define(RESPONSE_KIND, 23195).
-define(MAX_NWC_RELAYS, 5).

nwc_relay_allowlist() ->
    [
        <<"wss://nos.lol">>,
        <<"wss://offchain.pub">>,
        <<"wss://relay.primal.net">>,
        <<"wss://relay.damus.io">>,
        <<"wss://nostr-01.yakihonne.com">>,
        <<"wss://nostr-02.yakihonne.com">>
    ].

sanitize_nwc_relays(Relays0) ->
    Relays1 = damage_nostr:normalize_relays(Relays0),
    Allowed = maps:from_list([{canonical_url(U), true} || U <- nwc_relay_allowlist()]),

    Relays2 =
        [
            R#{url => canonical_url(maps:get(url, R)), proxy => direct}
         || R <- Relays1,
            maps:is_key(canonical_url(maps:get(url, R)), Allowed)
        ],

    Relays3 =
        case Relays2 of
            [] ->
                [#{url => canonical_url(U), proxy => direct} || U <- nwc_relay_allowlist()];
            _ ->
                Relays2
        end,

    take_unique_relays(?MAX_NWC_RELAYS, Relays3).

canonical_url(Url0) ->
    Url1 = damage_utils:to_bin(Url0),
    Url2 =
        case byte_size(Url1) of
            0 ->
                Url1;
            N ->
                case binary:at(Url1, N - 1) of
                    $/ -> binary:part(Url1, 0, N - 1);
                    _ -> Url1
                end
        end,
    list_to_binary(string:lowercase(binary_to_list(Url2))).

take_unique_relays(Max, Relays) ->
    take_unique_relays(Max, Relays, #{}, []).

take_unique_relays(0, _Relays, _Seen, Acc) ->
    lists:reverse(Acc);
take_unique_relays(_Max, [], _Seen, Acc) ->
    lists:reverse(Acc);
take_unique_relays(Max, [#{url := Url} = R | Rest], Seen, Acc) ->
    case maps:is_key(Url, Seen) of
        true ->
            take_unique_relays(Max, Rest, Seen, Acc);
        false ->
            take_unique_relays(Max - 1, Rest, Seen#{Url => true}, [R | Acc])
    end.

-record(state, {
    relays = [],
    relay_index = 1,

    %% legacy primary connection
    conn_pid = undefined,
    stream_ref = undefined,
    relay_path = "/",

    %% new fanout connections

    %% Url => #{relay := Relay, conn_pid := Pid, stream_ref := Ref}
    conns = #{},

    reconnect_ms = ?DEFAULT_RECONNECT_MS,
    service_pubkey = undefined,
    sub_id = undefined,
    seen = #{},
    crypto_handler = damage_nostr,
    reconnect_attempt = 0,
    reconnect_timer = undefined,
    max_reconnect_ms = ?DEFAULT_MAX_RECONNECT_MS,
    healthcheck_ms = ?DEFAULT_HEALTHCHECK_MS,
    health_timer = undefined
}).
%% damage_nwc_listener.erl / damage_nwc_wallet listener state

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link(Opts) when is_list(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

publish_info() ->
    gen_server:cast(?MODULE, publish_info).

supported_methods() ->
    [
        <<"get_info">>,
        <<"get_balance">>,
        <<"pay_invoice">>,
        <<"make_invoice">>,
        <<"lookup_invoice">>,
        <<"list_transactions">>
    ].

init(Opts0) ->
    process_flag(trap_exit, true),

    Opts =
        case Opts0 of
            [Conn] when is_map(Conn) ->
                [{relays, nwc_relays(Conn)}];
            L when is_list(L) ->
                L;
            Conn when is_map(Conn) ->
                [{relays, nwc_relays(Conn)}]
        end,

    Relays = relays(Opts),
    ReconnectMs = proplists:get_value(reconnect_ms, Opts, ?DEFAULT_RECONNECT_MS),
    MaxReconnectMs = proplists:get_value(
        max_reconnect_ms,
        Opts,
        ?DEFAULT_MAX_RECONNECT_MS
    ),
    HealthcheckMs = proplists:get_value(
        healthcheck_ms,
        Opts,
        ?DEFAULT_HEALTHCHECK_MS
    ),
    CryptoHandler = proplists:get_value(crypto_handler, Opts, damage_nostr),
    ServicePubKey = resolve_service_pubkey(CryptoHandler),

    State0 = #state{
        relays = Relays,
        reconnect_ms = ReconnectMs,
        max_reconnect_ms = MaxReconnectMs,
        healthcheck_ms = HealthcheckMs,
        crypto_handler = CryptoHandler,
        service_pubkey = ServicePubKey
    },

    {ok, State0, {continue, connect}}.

get_state() ->
    gen_server:call(?MODULE, get_state).

state_summary() ->
    gen_server:call(?MODULE, state_summary).

add_relays(Relays) ->
    gen_server:cast(?MODULE, {add_relays, Relays}).

handle_continue(connect, State) ->
    {noreply, maybe_connect(ensure_healthcheck(State))}.
handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(state_summary, _From, State) ->
    {reply, summarize_state(State), State};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast({add_relays, NewRelays0}, State = #state{relays = Relays0}) ->
    NewRelays = sanitize_nwc_relays(NewRelays0),
    Relays = sanitize_nwc_relays(Relays0 ++ NewRelays),
    ?LOG_INFO("NWC listener adding relays sanitized=~p", [Relays]),
    self() ! connect,
    {noreply, State#state{relays = Relays}};
handle_cast(restart, State) ->
    close_all_conns(State),
    State0 = cancel_health_timer(cancel_reconnect_timer(State)),
    CleanRelays = sanitize_nwc_relays(State0#state.relays),

    {noreply,
        maybe_connect(
            ensure_healthcheck(State0#state{
                relays = CleanRelays,
                reconnect_attempt = 0,
                reconnect_timer = undefined,
                health_timer = undefined,
                conn_pid = undefined,
                stream_ref = undefined,
                sub_id = undefined,
                conns = #{},
                seen = #{}
            })
        )};
handle_cast(publish_info, State) ->
    {noreply, publish_info_event(State)};
handle_cast(_Cast, State) ->
    {noreply, State}.
handle_info(connect, State) ->
    {noreply, maybe_connect(State#state{reconnect_timer = undefined})};
handle_info(healthcheck, State0) ->
    State1 = ensure_healthcheck(State0#state{health_timer = undefined}),
    Missing = missing_relay_count(State1),
    case Missing of
        0 ->
            {noreply, maybe_connect(State1)};
        _ ->
            ?LOG_WARNING(
                "NWC listener healthcheck missing_relays=~p connected=~p",
                [Missing, map_size(State1#state.conns)]
            ),
            {noreply, maybe_connect(State1)}
    end;
handle_info({gun_response, ConnPid, StreamRef, _Fin, Status, Headers}, State) ->
    case conn_known(ConnPid, StreamRef, State) of
        true ->
            ?LOG_WARNING(
                "NWC relay HTTP response before WS upgrade conn=~p stream=~p status=~p headers_count=~p",
                [ConnPid, StreamRef, Status, length(Headers)]
            ),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG(
                "Ignoring gun_response from unknown conn=~p stream=~p status=~p",
                [ConnPid, StreamRef, Status]
            ),
            {noreply, State}
    end;
handle_info({gun_data, ConnPid, StreamRef, _Fin, Data}, State) ->
    case conn_known(ConnPid, StreamRef, State) of
        true ->
            ?LOG_WARNING(
                "NWC relay HTTP body before/without WS upgrade conn=~p stream=~p bytes=~p",
                [ConnPid, StreamRef, byte_size(Data)]
            ),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG(
                "Ignoring gun_data from unknown conn=~p stream=~p bytes=~p",
                [ConnPid, StreamRef, byte_size(Data)]
            ),
            {noreply, State}
    end;
handle_info({gun_error, ConnPid, Reason}, State) ->
    case conn_known_pid(ConnPid, State) of
        true ->
            ?LOG_WARNING("NWC relay gun_error conn=~p reason=~p", [ConnPid, Reason]),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG("Ignoring gun_error from unknown relay conn=~p reason=~p", [
                ConnPid,
                Reason
            ]),
            {noreply, State}
    end;
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    case conn_known(ConnPid, StreamRef, State) of
        true ->
            ?LOG_WARNING("NWC relay gun_error conn=~p stream=~p reason=~p", [
                ConnPid, StreamRef, Reason
            ]),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG("Ignoring gun_error from unknown relay conn=~p stream=~p reason=~p", [
                ConnPid, StreamRef, Reason
            ]),
            {noreply, State}
    end;
handle_info({gun_ws, ConnPid, StreamRef, {text, Msg}}, State) ->
    case conn_known(ConnPid, StreamRef, State) of
        true ->
            {noreply, handle_ws_message(Msg, State)};
        false ->
            ?LOG_DEBUG("Ignoring WS from unknown relay conn=~p stream=~p", [ConnPid, StreamRef]),
            {noreply, State}
    end;
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}, State) ->
    case conn_known_pid(ConnPid, State) of
        true ->
            ?LOG_WARNING(
                "NWC relay connection down conn=~p protocol=~p reason=~p killed_streams=~p",
                [ConnPid, Protocol, Reason, safe_len(KilledStreams)]
            ),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG(
                "Ignoring gun_down from unknown relay conn=~p protocol=~p reason=~p",
                [ConnPid, Protocol, Reason]
            ),
            {noreply, State}
    end;
handle_info({gun_down, ConnPid, _Protocol, Reason, _KilledStreams, _Unprocessed}, State) ->
    case conn_known_pid(ConnPid, State) of
        true ->
            ?LOG_WARNING("NWC relay connection down conn=~p reason=~p", [ConnPid, Reason]),
            {noreply, schedule_reconnect(drop_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG("Ignoring gun_down from unknown relay conn=~p reason=~p", [
                ConnPid, Reason
            ]),
            {noreply, State}
    end;
handle_info({'EXIT', ConnPid, Reason}, State) ->
    case conn_known_pid(ConnPid, State) of
        true ->
            State1 = drop_conn(ConnPid, State),
            ?LOG_WARNING("NWC relay process exited conn=~p reason=~p", [ConnPid, Reason]),
            {noreply, schedule_reconnect(State1)};
        false ->
            ?LOG_DEBUG("Ignoring unrelated EXIT from ~p reason=~p", [ConnPid, Reason]),
            {noreply, State}
    end;
handle_info(
    {gun_down, _, http, closed, []},
    State
) ->
    {noreply, State};
handle_info(
    {gun_up, _, http},
    State
) ->
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("Ignoring unhandled info ~p", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    close_all_conns(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

relays(Opts) ->
    case proplists:get_value(relays, Opts, undefined) of
        undefined ->
            sanitize_nwc_relays(damage_nostr:configured_relays());
        Relays when is_list(Relays) ->
            sanitize_nwc_relays(Relays)
    end.

resolve_service_pubkey(CryptoHandler) ->
    case catch apply(CryptoHandler, service_pubkey_hex, []) of
        PubKey when is_binary(PubKey) ->
            PubKey;
        _ ->
            case catch apply(CryptoHandler, public_key_hex, []) of
                PubKey when is_binary(PubKey) ->
                    PubKey;
                _ ->
                    undefined
            end
    end.

maybe_connect(State0 = #state{relays = Relays0}) ->
    State = ensure_service_pubkey(State0),
    Relays = sanitize_nwc_relays(Relays0),

    State1 = lists:foldl(
        fun ensure_relay_connected/2,
        State#state{relays = Relays},
        Relays
    ),

    case missing_relay_count(State1) of
        0 ->
            cancel_reconnect_timer(State1#state{reconnect_attempt = 0});
        _ ->
            schedule_reconnect(State1)
    end.

restart() ->
    gen_server:cast(?MODULE, restart).

open_ws(Relay) ->
    case damage_nostr:open_relay_ws(Relay, #{connect_timeout => 20000}) of
        {ok, ConnPid, StreamRef} ->
            link(ConnPid),
            {ok, ConnPid, StreamRef};
        {error, Reason} ->
            ?LOG_ERROR("NWC listener websocket open failed relay=~p proxy=~p reason=~p", [
                Relay,
                damage_gun:proxy(),
                Reason
            ]),
            {error, Reason}
    end.

relay_spec(#{url := Url} = _Relay) ->
    relay_spec(Url);
relay_spec(Relay) when is_binary(Relay) ->
    relay_spec(binary_to_list(Relay));
relay_spec(Relay) when is_list(Relay) ->
    Uri = uri_string:parse(Relay),
    Scheme = maps:get(scheme, Uri, "wss"),
    Host = maps:get(host, Uri),
    Path0 = maps:get(path, Uri, "/"),
    Path1 =
        case Path0 of
            <<>> -> "/";
            "" -> "/";
            P -> P
        end,
    Query = maps:get(query, Uri, undefined),
    Path =
        case Query of
            undefined -> Path1;
            <<>> -> Path1;
            "" -> Path1;
            _ -> Path1 ++ "?" ++ Query
        end,
    TlsOpts = [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {depth, 3},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],

    #{
        host => Host,
        port => maps:get(port, Uri, default_port(Scheme)),
        path => Path,
        transport => transport_from_scheme(Scheme),
        tls_opts => TlsOpts
    }.

relay_path(Relay) ->
    maps:get(path, relay_spec(Relay), "/").

transport_from_scheme("wss") -> tls;
transport_from_scheme(<<"wss">>) -> tls;
transport_from_scheme("https") -> tls;
transport_from_scheme(<<"https">>) -> tls;
transport_from_scheme(_) -> tcp.

default_port("wss") -> 443;
default_port(<<"wss">>) -> 443;
default_port("https") -> 443;
default_port(<<"https">>) -> 443;
default_port(_) -> 80.

schedule_reconnect(#state{reconnect_timer = Timer} = State) when is_reference(Timer) ->
    %% Already scheduled. Prevent reconnect timer storms.
    State;
schedule_reconnect(
    #state{
        reconnect_ms = BaseMs,
        max_reconnect_ms = MaxMs,
        reconnect_attempt = Attempt
    } = State
) ->
    DelayMs = backoff_ms(BaseMs, MaxMs, Attempt),
    Timer = erlang:send_after(DelayMs, self(), connect),
    ?LOG_WARNING(
        "NWC listener reconnect scheduled delay_ms=~p attempt=~p missing_relays=~p connected=~p",
        [DelayMs, Attempt + 1, missing_relay_count(State), map_size(State#state.conns)]
    ),
    State#state{
        reconnect_timer = Timer,
        reconnect_attempt = Attempt + 1
    }.

backoff_ms(BaseMs, MaxMs, Attempt) ->
    Mult = 1 bsl min_int(Attempt, 6),
    min_int(MaxMs, BaseMs * Mult).

min_int(A, B) when A =< B -> A;
min_int(_A, B) -> B.

cancel_reconnect_timer(#state{reconnect_timer = undefined} = State) ->
    State;
cancel_reconnect_timer(#state{reconnect_timer = Timer} = State) when is_reference(Timer) ->
    _ = erlang:cancel_timer(Timer),
    State#state{reconnect_timer = undefined}.

ensure_healthcheck(#state{health_timer = Timer} = State) when is_reference(Timer) ->
    State;
ensure_healthcheck(#state{healthcheck_ms = Ms} = State) when is_integer(Ms), Ms > 0 ->
    Timer = erlang:send_after(Ms, self(), healthcheck),
    State#state{health_timer = Timer};
ensure_healthcheck(State) ->
    State.

cancel_health_timer(#state{health_timer = undefined} = State) ->
    State;
cancel_health_timer(#state{health_timer = Timer} = State) when is_reference(Timer) ->
    _ = erlang:cancel_timer(Timer),
    State#state{health_timer = undefined}.

publish_info_event(#state{conns = Conns} = State) when map_size(Conns) =:= 0 ->
    State;
publish_info_event(#state{service_pubkey = undefined} = State) ->
    State;
publish_info_event(#state{conns = Conns} = State) ->
    case create_info_event_msg(State) of
        {ok, Msg, EventId} ->
            case fanout_ws_text(Conns, Msg) of
                {ok, OkUrls, Results} ->
                    ?LOG_INFO(
                        "Published NWC info event id=~p ok_relays=~p results=~p",
                        [EventId, OkUrls, Results]
                    ),
                    State;
                {error, Results} ->
                    ?LOG_WARNING(
                        "Failed to publish NWC info event to any relay results=~p",
                        [Results]
                    ),
                    State
            end;
        {error, Reason} ->
            ?LOG_WARNING("Failed to build NWC info event: ~p", [Reason]),
            State
    end.

publish_info_event_to_conn(_ConnPid, _StreamRef, #state{service_pubkey = undefined} = State) ->
    State;
publish_info_event_to_conn(ConnPid, StreamRef, State) ->
    case create_info_event_msg(State) of
        {ok, Msg, EventId} ->
            case safe_send_ws_text(ConnPid, StreamRef, Msg) of
                ok ->
                    ?LOG_INFO(
                        "Published NWC info event id=~p conn=~p stream=~p",
                        [EventId, ConnPid, StreamRef]
                    ),
                    State;
                Error ->
                    ?LOG_WARNING(
                        "Failed to publish NWC info event id=~p conn=~p stream=~p error=~p",
                        [EventId, ConnPid, StreamRef, Error]
                    ),
                    State
            end;
        {error, Reason} ->
            ?LOG_WARNING("Failed to build NWC info event: ~p", [Reason]),
            State
    end.

create_info_event_msg(#state{crypto_handler = CryptoHandler}) ->
    Content = iolist_to_binary(string:join([binary_to_list(M) || M <- supported_methods()], " ")),
    Tags = [
        [<<"encryption">>, <<"nip04">>]
    ],
    case create_signed_event(CryptoHandler, ?INFO_KIND, Content, Tags) of
        {ok, Event} ->
            EventId = maps:get(<<"id">>, Event, maps:get(id, Event, undefined)),
            {ok, jsx:encode([<<"EVENT">>, Event]), EventId};
        Error ->
            Error
    end.

handle_ws_message(Msg, State) when is_binary(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        [<<"EVENT">>, _SubId, Event] when is_map(Event) ->
            handle_request_event(Event, State);
        [<<"NOTICE">>, Notice] ->
            ?LOG_INFO("NWC relay notice: ~p", [Notice]),
            State;
        [<<"OK">>, EventId, Accepted, Message] ->
            ?LOG_DEBUG(
                "NWC OK event_id=~p accepted=~p msg=~p",
                [EventId, Accepted, Message]
            ),
            State;
        [<<"EOSE">>, _SubId] ->
            State;
        [<<"CLOSED">>, _SubId, Reason] ->
            ?LOG_WARNING("NWC relay closed subscription: ~p", [Reason]),
            State;
        Other ->
            ?LOG_DEBUG("Ignoring relay frame ~p", [Other]),
            State
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(
                "JSON decode failed class=~p reason=~p msg=~p stack_top=~p",
                [Class, Reason, safe_bin(Msg), stack_top(Stack)]
            ),
            State
    end;
handle_ws_message(_Msg, State) ->
    State.

handle_request_event(#{<<"id">> := EventId} = Event, #state{seen = Seen} = State) ->
    case maps:is_key(EventId, Seen) of
        true ->
            ?LOG_DEBUG("NWC Event seen ~p", [event_summary(Event)]),
            State;
        false ->
            ?LOG_DEBUG("NWC Event unseen ~p", [event_summary(Event)]),
            handle_new_request_event(Event, State#state{seen = maps:put(EventId, true, Seen)})
    end.

handle_new_request_event(Event, #state{crypto_handler = CryptoHandler} = State) ->
    case decode_request(CryptoHandler, Event) of
        {ok, RequestCtx} ->
            Method = maps:get(<<"method">>, RequestCtx, <<"unknown">>),

            ResponsePayload =
                case damage_nwc_request_handler:handle_nip47_request(RequestCtx) of
                    {ok, Response0} ->
                        nwc_success_payload(Method, Response0);
                    {error, Error0} ->
                        nwc_error_payload(Method, Error0);
                    Other ->
                        nwc_error_payload(
                            Method,
                            #{
                                <<"code">> => <<"INTERNAL">>,
                                <<"message">> => to_binary(Other)
                            }
                        )
                end,

            Res = send_response(Event, ResponsePayload, State),
            ?LOG_DEBUG("Send NIP-47 response result=~p payload_summary=~p", [
                Res,
                response_payload_summary(ResponsePayload)
            ]),
            State;
        {error, Reason} ->
            ?LOG_WARNING("Ignoring undecodable NIP-47 request reason=~p event=~p", [
                nwc_error_summary(Reason),
                event_summary(Event)
            ]),
            State
    end.
nwc_success_payload(Method, Result0) ->
    Result = normalize_nwc_result(Method, Result0),
    #{
        <<"result_type">> => Method,
        <<"error">> => null,
        <<"result">> => Result,

        %% Amethyst / Quartz 1.04.2 compatibility.
        %% Its LnZapPaymentResponseEvent mapper expects Response(non-null).
        <<"response">> => Result
    }.

nwc_error_payload(Method, Error0) ->
    Error = normalize_nwc_error(Error0),
    #{
        <<"result_type">> => Method,
        <<"error">> => Error,
        <<"result">> => null,
        <<"response">> => null
    }.

normalize_nwc_result(<<"pay_invoice">>, Result0) ->
    Result = normalize_map(Result0),
    #{
        <<"preimage">> => maps:get(<<"preimage">>, Result, <<>>)
    };
normalize_nwc_result(<<"get_balance">>, Result0) ->
    Result = normalize_map(Result0),
    #{
        <<"balance">> => maps:get(<<"balance">>, Result, 0)
    };
normalize_nwc_result(_Method, Result0) ->
    normalize_map(Result0).

normalize_nwc_error(#{error := E}) ->
    normalize_nwc_error(E);
normalize_nwc_error(#{<<"error">> := E}) ->
    normalize_nwc_error(E);
normalize_nwc_error(#{code := Code, message := Message}) ->
    #{
        <<"code">> => to_binary(Code),
        <<"message">> => to_binary(Message)
    };
normalize_nwc_error(#{<<"code">> := Code, <<"message">> := Message}) ->
    #{
        <<"code">> => to_binary(Code),
        <<"message">> => to_binary(Message)
    };
normalize_nwc_error(Other) ->
    #{
        <<"code">> => <<"INTERNAL">>,
        <<"message">> => to_binary(Other)
    }.

response_payload_summary(Payload) ->
    #{
        result_type => maps:get(<<"result_type">>, Payload, undefined),
        error => term_shape(maps:get(<<"error">>, Payload, undefined)),
        result => term_shape(maps:get(<<"result">>, Payload, undefined)),
        response => term_shape(maps:get(<<"response">>, Payload, undefined))
    }.

nwc_error_summary({request_decrypt_failed, Err}) ->
    #{type => request_decrypt_failed, reason => crypto_error_summary(Err)};
nwc_error_summary({invalid_request_json, Reason, Plain}) ->
    #{type => invalid_request_json, reason => Reason, plain_bytes => bin_len(Plain)};
nwc_error_summary({invalid_request_event, Event}) ->
    #{type => invalid_request_event, event => event_summary(Event)};
nwc_error_summary({decrypt_crash, Class, Reason, _Stack}) ->
    #{type => decrypt_crash, class => Class, reason => term_shape(Reason)};
nwc_error_summary({ecdh_shared_secret_failed, Class, Reason, _Stack}) ->
    #{type => ecdh_shared_secret_failed, class => Class, reason => term_shape(Reason)};
nwc_error_summary(Other) ->
    term_shape(Other).

crypto_error_summary({error, Reason}) ->
    nwc_error_summary(Reason);
crypto_error_summary(Other) ->
    term_shape(Other).

decode_request(CryptoHandler, Event) ->
    case catch apply(CryptoHandler, nwc_decode_request, [Event]) of
        {ok, _Req} = Ok ->
            Ok;
        {error, Reason} ->
            {error, Reason};
        {'EXIT', Reason} ->
            {error, {crypto_handler_exit, Reason}};
        Other ->
            {error, {unexpected_decode_result, Other}}
    end.

send_response(_Event, _Payload, #state{conns = Conns}) when map_size(Conns) =:= 0 ->
    {error, disconnected};
send_response(Event, Payload, _State = #state{crypto_handler = CryptoHandler, conns = Conns}) ->
    case encode_response(CryptoHandler, Event, Payload) of
        {ok, ResponseEvent} ->
            Msg = jsx:encode([<<"EVENT">>, ResponseEvent]),
            case fanout_ws_text(Conns, Msg) of
                {ok, _OkUrls, _Results} -> ok;
                {error, Results} -> {error, Results}
            end;
        {error, Reason} ->
            ?LOG_WARNING("Failed to encode NIP-47 response: ~p", [Reason]),
            {error, Reason}
    end.

encode_response(CryptoHandler, Event, Payload) ->
    case catch apply(CryptoHandler, nwc_encode_response, [Event, Payload, ?RESPONSE_KIND]) of
        {ok, _Event} = Ok ->
            Ok;
        {error, Reason} ->
            {error, Reason};
        {'EXIT', Reason} ->
            {error, {crypto_handler_exit, Reason}};
        Other ->
            {error, {unexpected_encode_result, Other}}
    end.

create_signed_event(CryptoHandler, Kind, Content, Tags) ->
    case catch apply(CryptoHandler, create_signed_event, [Kind, Content, Tags]) of
        {ok, _Event} = Ok ->
            Ok;
        {'EXIT', Reason} ->
            {error, Reason};
        Error ->
            {error, Error}
    end.

fanout_ws_text(Conns, Msg) ->
    Results =
        maps:fold(
            fun
                (Url, #{conn_pid := Pid, stream_ref := Ref}, Acc) ->
                    [{Url, safe_send_ws_text(Pid, Ref, Msg)} | Acc];
                (Url, Entry, Acc) ->
                    [{Url, {error, {bad_conn_entry, Entry}}} | Acc]
            end,
            [],
            Conns
        ),
    OkUrls = [Url || {Url, ok} <- Results],
    case OkUrls of
        [] -> {error, Results};
        _ -> {ok, OkUrls, Results}
    end.

safe_send_ws_text(ConnPid, StreamRef, Msg) ->
    try send_ws_text(ConnPid, StreamRef, Msg) of
        ok -> ok;
        Other -> {error, Other}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.
send_ws_text(ConnPid, StreamRef, Msg) when is_binary(Msg) ->
    ?LOG_DEBUG("send_ws_text conn=~p stream=~p bytes=~p", [
        ConnPid, StreamRef, byte_size(Msg)
    ]),
    gun:ws_send(ConnPid, StreamRef, {text, Msg});
send_ws_text(ConnPid, StreamRef, Msg) ->
    ?LOG_DEBUG("send_ws_text conn=~p stream=~p msg_shape=~p", [
        ConnPid, StreamRef, term_shape(Msg)
    ]),
    gun:ws_send(ConnPid, StreamRef, {text, Msg}).

subscription_id() ->
    iolist_to_binary(io_lib:format("nwc-~p", [erlang:unique_integer([positive])])).

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
to_binary(Int) when is_integer(Int) ->
    integer_to_binary(Int);
to_binary(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

normalize_map(Map) when is_map(Map) ->
    maps:from_list([{to_binary(K), normalize_value(V)} || {K, V} <- maps:to_list(Map)]).

normalize_value(V) when is_map(V) ->
    normalize_map(V);
normalize_value(V) when is_list(V) ->
    case io_lib:printable_list(V) of
        true -> to_binary(V);
        false -> [normalize_value(I) || I <- V]
    end;
normalize_value(V) ->
    V.
nwc_relays(Conn) ->
    Relays0 =
        case Conn of
            #{relays := Rs} when is_list(Rs), Rs =/= [] ->
                Rs;
            #{<<"relays">> := Rs} when is_list(Rs), Rs =/= [] ->
                Rs;
            #{relay := R} ->
                [R];
            #{<<"relay">> := R} ->
                [R];
            _ ->
                damage_nostr:configured_relays()
        end,
    damage_nostr:normalize_relays(Relays0).

ensure_relay_connected(Relay, State = #state{conns = Conns}) ->
    Url = maps:get(url, Relay),
    case maps:get(Url, Conns, undefined) of
        #{conn_pid := Pid, subscribed := true} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true ->
                    State;
                false ->
                    ?LOG_WARNING("NWC listener removing dead subscribed relay pid=~p url=~p", [
                        Pid, Url
                    ]),
                    ensure_relay_connected(Relay, drop_conn(Pid, State))
            end;
        #{conn_pid := Pid, stream_ref := Ref} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true ->
                    subscribe_requests_for(Pid, Ref, State);
                false ->
                    ?LOG_WARNING("NWC listener removing dead unsubscribed relay pid=~p url=~p", [
                        Pid, Url
                    ]),
                    ensure_relay_connected(Relay, drop_conn(Pid, State))
            end;
        _ ->
            case open_ws(Relay) of
                {ok, ConnPid, StreamRef} ->
                    Entry = #{
                        relay => Relay,
                        conn_pid => ConnPid,
                        stream_ref => StreamRef,
                        subscribed => false
                    },
                    State1 = State#state{
                        conns = maps:put(Url, Entry, Conns),
                        conn_pid =
                            case State#state.conn_pid of
                                undefined -> ConnPid;
                                P -> P
                            end,
                        stream_ref =
                            case State#state.stream_ref of
                                undefined -> StreamRef;
                                R -> R
                            end,
                        relay_path = relay_path(Relay)
                    },
                    State2 = subscribe_requests_for(ConnPid, StreamRef, State1),
                    case conn_known(ConnPid, StreamRef, State2) of
                        true ->
                            publish_info_event_to_conn(ConnPid, StreamRef, State2);
                        false ->
                            State2
                    end;
                {error, Reason} ->
                    ?LOG_WARNING("NWC listener failed relay=~p reason=~p", [
                        relay_summary(Relay), Reason
                    ]),
                    State
            end
    end.
subscribe_requests_for(_ConnPid, _StreamRef, #state{service_pubkey = undefined} = State) ->
    ?LOG_WARNING("NWC listener has no service pubkey, skipping subscription.", []),
    State;
subscribe_requests_for(ConnPid, StreamRef, #state{service_pubkey = PubKey} = State) ->
    SubId = subscription_id(),
    Filter = #{
        <<"kinds">> => [?REQUEST_KIND],
        <<"#p">> => [PubKey]
    },
    Msg = jsx:encode([<<"REQ">>, SubId, Filter]),
    case safe_send_ws_text(ConnPid, StreamRef, Msg) of
        ok ->
            ?LOG_INFO(
                "NWC listener subscribed conn=~p stream=~p sub_id=~p pubkey=~p",
                [ConnPid, StreamRef, SubId, PubKey]
            ),
            mark_subscribed(ConnPid, StreamRef, SubId, State);
        Error ->
            ?LOG_WARNING(
                "NWC listener subscribe failed conn=~p stream=~p error=~p",
                [ConnPid, StreamRef, Error]
            ),
            drop_conn(ConnPid, State)
    end.

mark_subscribed(ConnPid, StreamRef, SubId, State = #state{conns = Conns}) ->
    Conns1 =
        maps:map(
            fun
                (_Url, #{conn_pid := ConnPid0, stream_ref := StreamRef0} = Entry) when
                    ConnPid0 =:= ConnPid, StreamRef0 =:= StreamRef
                ->
                    Entry#{subscribed => true, sub_id => SubId};
                (_Url, Entry) ->
                    Entry
            end,
            Conns
        ),
    State#state{conns = Conns1, sub_id = SubId}.
drop_conn(ConnPid, State = #state{conns = Conns, conn_pid = Primary}) ->
    case ConnPid of
        Pid when is_pid(Pid) ->
            catch gun:close(Pid);
        _ ->
            ok
    end,

    Conns1 =
        maps:filter(
            fun
                (_Url, #{conn_pid := Pid}) ->
                    Pid =/= ConnPid;
                (_Url, _Entry) ->
                    true
            end,
            Conns
        ),

    State1 = State#state{conns = Conns1},

    case Primary =:= ConnPid of
        true ->
            case maps:values(Conns1) of
                [#{conn_pid := P, stream_ref := S, relay := Relay} | _] ->
                    State1#state{
                        conn_pid = P,
                        stream_ref = S,
                        relay_path = relay_path(Relay)
                    };
                [] ->
                    State1#state{
                        conn_pid = undefined,
                        stream_ref = undefined,
                        relay_path = "/"
                    }
            end;
        false ->
            State1
    end.
conn_known(ConnPid, StreamRef, #state{conn_pid = ConnPid, stream_ref = StreamRef}) ->
    true;
conn_known(ConnPid, StreamRef, #state{conns = Conns}) ->
    lists:any(
        fun
            (#{conn_pid := P, stream_ref := S}) ->
                P =:= ConnPid andalso S =:= StreamRef;
            (_) ->
                false
        end,
        maps:values(Conns)
    ).

close_all_conns(#state{conns = Conns, conn_pid = ConnPid}) ->
    lists:foreach(
        fun
            (#{conn_pid := Pid}) when is_pid(Pid) ->
                catch gun:close(Pid);
            (_) ->
                ok
        end,
        maps:values(Conns)
    ),
    case ConnPid of
        undefined -> ok;
        P when is_pid(P) -> catch gun:close(P)
    end,
    ok.
summarize_state(#state{
    relays = Relays,
    service_pubkey = ServicePubKey,
    sub_id = SubId,
    conns = Conns,
    reconnect_attempt = ReconnectAttempt,
    reconnect_timer = ReconnectTimer,
    max_reconnect_ms = MaxReconnectMs,
    health_timer = HealthTimer
}) ->
    #{
        relays => Relays,
        service_pubkey => ServicePubKey,
        sub_id => SubId,

        %% compatibility keys: listener should never self-stop now
        stopped => false,
        retry_count => ReconnectAttempt,
        max_retries => infinity,

        reconnect_attempt => ReconnectAttempt,
        reconnect_timer_set => is_reference(ReconnectTimer),
        max_reconnect_ms => MaxReconnectMs,
        health_timer_set => is_reference(HealthTimer),

        connected_count => map_size(Conns),
        missing_relay_count =>
            missing_relay_count(#state{relays = Relays, conns = Conns}),
        connected_relays =>
            [
                #{
                    url => Url,
                    alive => alive_pid(maps:get(conn_pid, Entry, undefined)),
                    subscribed => maps:get(subscribed, Entry, false),
                    sub_id => maps:get(sub_id, Entry, undefined),
                    conn_pid => maps:get(conn_pid, Entry, undefined),
                    stream_ref => maps:get(stream_ref, Entry, undefined)
                }
             || {Url, Entry} <- maps:to_list(Conns)
            ]
    }.
alive_pid(Pid) when is_pid(Pid) ->
    is_process_alive(Pid);
alive_pid(_) ->
    false.
ensure_service_pubkey(#state{service_pubkey = undefined, crypto_handler = CryptoHandler} = State) ->
    case resolve_service_pubkey(CryptoHandler) of
        PubKey when is_binary(PubKey) ->
            ?LOG_INFO("NWC listener resolved service pubkey ~p", [PubKey]),
            State#state{service_pubkey = PubKey};
        _ ->
            State
    end;
ensure_service_pubkey(State) ->
    State.
missing_relay_count(#state{relays = Relays, conns = Conns}) ->
    Wanted =
        maps:from_list([{maps:get(url, R), true} || R <- damage_nostr:normalize_relays(Relays)]),
    Have =
        maps:from_list([
            {Url, true}
         || {Url, #{subscribed := true, conn_pid := Pid}} <- maps:to_list(Conns),
            alive_pid(Pid)
        ]),
    length([Url || Url <- maps:keys(Wanted), not maps:is_key(Url, Have)]).
conn_known_pid(ConnPid, #state{conn_pid = ConnPid}) when is_pid(ConnPid) ->
    true;
conn_known_pid(ConnPid, #state{conns = Conns}) when is_pid(ConnPid) ->
    lists:any(
        fun
            (#{conn_pid := P}) -> P =:= ConnPid;
            (_) -> false
        end,
        maps:values(Conns)
    );
conn_known_pid(_, _) ->
    false.
relay_summary(#{url := Url}) ->
    #{url => Url};
relay_summary(Relay) ->
    Relay.

term_shape(Term) when is_map(Term) ->
    #{type => map, size => map_size(Term), keys => maps:keys(Term)};
term_shape(Term) when is_list(Term) ->
    #{type => list, length => length(Term)};
term_shape(Term) when is_tuple(Term) ->
    #{type => tuple, size => tuple_size(Term), tag => element(1, Term)};
term_shape(Term) when is_binary(Term) ->
    #{type => binary, bytes => byte_size(Term)};
term_shape(Term) ->
    Term.

safe_bin(Bin) when is_binary(Bin) ->
    #{type => binary, bytes => byte_size(Bin)};
safe_bin(List) when is_list(List) ->
    #{type => list, length => length(List)};
safe_bin(Other) ->
    term_shape(Other).

event_summary(Event) when is_map(Event) ->
    Content = maps:get(<<"content">>, Event, maps:get(content, Event, <<>>)),
    Tags = maps:get(<<"tags">>, Event, maps:get(tags, Event, [])),
    #{
        id => short_bin(maps:get(<<"id">>, Event, maps:get(id, Event, undefined))),
        kind => maps:get(<<"kind">>, Event, maps:get(kind, Event, undefined)),
        pubkey => short_bin(maps:get(<<"pubkey">>, Event, maps:get(pubkey, Event, undefined))),
        p_tags => short_bin_list(tag_values(<<"p">>, Tags)),
        encryption => encryption_tag(Tags),
        tag_names => tag_names(Tags),
        tags_count => list_len(Tags),
        content_bytes => bin_len(Content)
    };
event_summary(Other) ->
    term_shape(Other).

tag_names(Tags) when is_list(Tags) ->
    [N || [N | _] <- Tags];
tag_names(_) ->
    [].

encryption_tag(Tags) when is_list(Tags) ->
    case [V || [<<"encryption">>, V | _] <- Tags] of
        [V | _] -> V;
        [] -> nip04_implicit
    end;
encryption_tag(_) ->
    nip04_implicit.

tag_values(Name, Tags) when is_list(Tags) ->
    [V || [N, V | _] <- Tags, N =:= Name];
tag_values(_, _) ->
    [].

short_bin_list(Vs) ->
    [short_bin(V) || V <- Vs].

short_bin(undefined) ->
    undefined;
short_bin(Bin) when is_binary(Bin), byte_size(Bin) > 16 ->
    <<Head:8/binary, _/binary>> = Bin,
    <<Head/binary, "...">>;
short_bin(Other) ->
    Other.

list_len(L) when is_list(L) -> length(L);
list_len(_) -> 0.

bin_len(B) when is_binary(B) -> byte_size(B);
bin_len(L) when is_list(L) -> length(L);
bin_len(_) -> 0.

stack_top([{M, F, A, _} | _]) -> {M, F, A};
stack_top(_) -> undefined.

safe_len(L) when is_list(L) ->
    length(L);
safe_len(_) ->
    0.
