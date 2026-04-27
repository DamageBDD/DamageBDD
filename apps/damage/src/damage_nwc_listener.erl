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

-define(DEFAULT_RECONNECT_MS, 5000).
-define(INFO_KIND, 13194).
-define(REQUEST_KIND, 23194).
-define(RESPONSE_KIND, 23195).

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
    retry_count = 0,
    max_retries = 10,
    stopped = false
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
    MaxRetries = proplists:get_value(max_retries, Opts, 10),
    CryptoHandler = proplists:get_value(crypto_handler, Opts, damage_nostr),
    ServicePubKey = resolve_service_pubkey(CryptoHandler),

    State0 = #state{
        relays = Relays,
        reconnect_ms = ReconnectMs,
        max_retries = MaxRetries,
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
    {noreply, maybe_connect(State)}.

handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(state_summary, _From, State) ->
    {reply, summarize_state(State), State};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast({add_relays, NewRelays0}, State = #state{relays = Relays0}) ->
    NewRelays = damage_nostr:normalize_relays(NewRelays0),
    Relays = merge_relays(Relays0, NewRelays),
    ?LOG_INFO("NWC listener adding relays ~p merged=~p", [NewRelays, Relays]),
    {noreply, maybe_connect(State#state{relays = Relays, stopped = false})};
handle_cast(restart, State) ->
    close_all_conns(State),
    {noreply,
        maybe_connect(State#state{
            stopped = false,
            retry_count = 0,
            conn_pid = undefined,
            stream_ref = undefined,
            sub_id = undefined,
            conns = #{},
            seen = #{}
        })};
handle_cast(publish_info, State) ->
    {noreply, publish_info_event(State)};
handle_cast(_Cast, State) ->
    {noreply, State}.
handle_info(connect, #state{stopped = true} = State) ->
    {noreply, State};
handle_info(connect, State) ->
    {noreply, maybe_connect(State)};
handle_info(
    {gun_response, ConnPid, StreamRef, _Fin, Status, Headers},
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    ?LOG_WARNING("NWC relay HTTP response before WS upgrade status=~p headers=~p", [
        Status, Headers
    ]),
    {noreply, State};
handle_info(
    {gun_data, ConnPid, StreamRef, _Fin, Data},
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    ?LOG_WARNING("NWC relay HTTP body before/without WS upgrade: ~ts", [Data]),
    {noreply, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    case conn_known(ConnPid, StreamRef, State) of
        true ->
            ?LOG_WARNING("NWC relay gun_error conn=~p stream=~p reason=~p", [
                ConnPid, StreamRef, Reason
            ]),
            {noreply, schedule_reconnect(remove_conn(ConnPid, State))};
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
handle_info({gun_down, ConnPid, _Protocol, Reason, _KilledStreams, _Unprocessed}, State) ->
    case conn_known_pid(ConnPid, State) of
        true ->
            ?LOG_WARNING("NWC relay connection down conn=~p reason=~p", [ConnPid, Reason]),
            {noreply, schedule_reconnect(remove_conn(ConnPid, State))};
        false ->
            ?LOG_DEBUG("Ignoring gun_down from unknown relay conn=~p reason=~p", [
                ConnPid, Reason
            ]),
            {noreply, State}
    end;
handle_info({'EXIT', ConnPid, Reason}, State) ->
    case remove_conn(ConnPid, State) of
        State ->
            ?LOG_DEBUG("Ignoring unrelated EXIT from ~p reason=~p", [ConnPid, Reason]),
            {noreply, State};
        State1 ->
            ?LOG_WARNING("NWC relay process exited conn=~p reason=~p", [ConnPid, Reason]),
            {noreply, schedule_reconnect(State1)}
    end;
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
            damage_nostr:configured_relays();
        Relays when is_list(Relays) ->
            damage_nostr:normalize_relays(Relays)
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

maybe_connect(State0 = #state{relays = Relays0, conns = _Conns0}) ->
    State = ensure_service_pubkey(State0),
    Relays = damage_nostr:normalize_relays(Relays0),
    State1 = lists:foldl(fun ensure_relay_connected/2, State#state{relays = Relays}, Relays),
    case missing_relay_count(State1) of
        0 -> State1;
        _ -> schedule_reconnect(State1)
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

schedule_reconnect(#state{stopped = true} = State) ->
    State;
schedule_reconnect(#state{retry_count = Retry, max_retries = Max} = State) when Retry >= Max ->
    ?LOG_ERROR("Reconnect suppressed after ~p/~p attempts.", [Retry, Max]),
    State#state{stopped = true};
schedule_reconnect(#state{reconnect_ms = ReconnectMs} = State) ->
    erlang:send_after(ReconnectMs, self(), connect),
    State#state{retry_count = State#state.retry_count + 1}.

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
    Tags = [],
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
            ?LOG_ERROR("JSON decode failed class=~p reason=~p msg=~p stack=~p", [
                Class, Reason, Msg, Stack
            ]),
            State
    end;
handle_ws_message(_Msg, State) ->
    State.

handle_request_event(#{<<"id">> := EventId} = Event, #state{seen = Seen} = State) ->
    ?LOG_DEBUG(
        "NWC Event ~p",
        [Event]
    ),
    case maps:is_key(EventId, Seen) of
        true ->
            State;
        false ->
            handle_new_request_event(Event, State#state{seen = maps:put(EventId, true, Seen)})
    end.

handle_new_request_event(Event, #state{crypto_handler = CryptoHandler} = State) ->
    case decode_request(CryptoHandler, Event) of
        {ok, RequestCtx} ->
            ResponsePayload =
                case damage_nwc_request_handler:handle_nip47_request(RequestCtx) of
                    {ok, Response0} ->
                        ?LOG_DEBUG("handle_new_request_event relay frame success ~p", [Response0]),
                        maps:merge(#{<<"result_type">> => <<"ok">>}, normalize_map(Response0));
                    {error, Error0} ->
                        ?LOG_ERROR("handle_new_request_event relay Error ~p", [Error0]),
                        maps:merge(#{<<"result_type">> => <<"error">>}, normalize_map(Error0));
                    Response0 when is_map(Response0) ->
                        maps:merge(#{<<"result_type">> => <<"ok">>}, normalize_map(Response0));
                    Other ->
                        maps:merge(
                            #{<<"result_type">> => <<"error">>},
                            #{
                                <<"error">> => #{
                                    <<"code">> => <<"INTERNAL">>,
                                    <<"message">> => to_binary(Other)
                                }
                            }
                        )
                end,
            Res = send_response(Event, ResponsePayload, State),
            ?LOG_DEBUG("Send response  ~p", [Res]),
            State;
        {error, Reason} ->
            ?LOG_WARNING("Failed to decode NIP-47 request: ~p ~p", [Reason, Event]),
            _ = send_response(
                Event,
                #{
                    <<"result_type">> => <<"error">>,
                    <<"error">> => #{
                        <<"code">> => <<"BAD_REQUEST">>,
                        <<"message">> => to_binary(Reason)
                    }
                },
                State
            ),
            State
    end.

decode_request(CryptoHandler, Event) ->
    case catch apply(CryptoHandler, nwc_decode_request, [Event]) of
        {ok, _Req} = Ok ->
            Ok;
        {'EXIT', Reason} ->
            {error, Reason};
        Error ->
            {error, Error}
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
        {'EXIT', Reason} ->
            {error, Reason};
        Error ->
            {error, Error}
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
send_ws_text(ConnPid, StreamRef, Msg) ->
    ?LOG_DEBUG("send_ws_text ~p", [Msg]),
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

merge_relays(Old0, New0) ->
    Old = damage_nostr:normalize_relays(Old0),
    New = damage_nostr:normalize_relays(New0),
    maps:values(
        lists:foldl(
            fun(Relay, Acc) ->
                maps:put(maps:get(url, Relay), Relay, Acc)
            end,
            #{},
            Old ++ New
        )
    ).
ensure_relay_connected(Relay, State = #state{conns = Conns}) ->
    Url = maps:get(url, Relay),
    case maps:get(Url, Conns, undefined) of
        #{conn_pid := Pid, subscribed := true} when is_pid(Pid) ->
            State;
        #{conn_pid := Pid, stream_ref := Ref} when is_pid(Pid) ->
            subscribe_requests_for(Pid, Ref, State);
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

                        %% keep legacy fields populated for old send_response path
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
                        relay_path = relay_path(Relay),
                        stopped = false,
                        retry_count = 0
                    },
                    State2 = subscribe_requests_for(ConnPid, StreamRef, State1),
                    publish_info_event_to_conn(ConnPid, StreamRef, State2);
                {error, Reason} ->
                    ?LOG_WARNING("NWC listener failed relay=~p reason=~p", [Relay, Reason]),
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
    ok = send_ws_text(ConnPid, StreamRef, Msg),
    ?LOG_INFO("NWC listener subscribed conn=~p stream=~p sub_id=~p pubkey=~p filter=~p", [
        ConnPid, StreamRef, SubId, PubKey, Filter
    ]),
    mark_subscribed(ConnPid, StreamRef, SubId, State).

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
conn_known(ConnPid, StreamRef, #state{conn_pid = ConnPid, stream_ref = StreamRef}) ->
    true;
conn_known(ConnPid, StreamRef, #state{conns = Conns}) ->
    lists:any(
        fun(#{conn_pid := P, stream_ref := S}) ->
            P =:= ConnPid andalso S =:= StreamRef
        end,
        maps:values(Conns)
    ).
remove_conn(ConnPid, State = #state{conns = Conns, conn_pid = Primary}) ->
    Conns1 =
        maps:filter(
            fun(_Url, #{conn_pid := Pid}) ->
                Pid =/= ConnPid
            end,
            Conns
        ),
    State1 = State#state{conns = Conns1},
    case Primary =:= ConnPid of
        true ->
            case maps:values(Conns1) of
                [#{conn_pid := P, stream_ref := S, relay := Relay} | _] ->
                    State1#state{conn_pid = P, stream_ref = S, relay_path = relay_path(Relay)};
                [] ->
                    State1#state{conn_pid = undefined, stream_ref = undefined, relay_path = "/"}
            end;
        false ->
            State1
    end.

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
    stopped = Stopped,
    retry_count = RetryCount,
    max_retries = MaxRetries
}) ->
    #{
        relays => Relays,
        service_pubkey => ServicePubKey,
        sub_id => SubId,
        stopped => Stopped,
        retry_count => RetryCount,
        max_retries => MaxRetries,
        connected_count => map_size(Conns),
        connected_relays =>
            [
                #{
                    url => Url,
                    subscribed => maps:get(subscribed, Entry, false),
                    sub_id => maps:get(sub_id, Entry, undefined),
                    conn_pid => maps:get(conn_pid, Entry, undefined),
                    stream_ref => maps:get(stream_ref, Entry, undefined)
                }
             || {Url, Entry} <- maps:to_list(Conns)
            ]
    }.
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
         || {Url, #{subscribed := true}} <- maps:to_list(Conns)
        ]),
    length([Url || Url <- maps:keys(Wanted), not maps:is_key(Url, Have)]).
conn_known_pid(ConnPid, #state{conn_pid = ConnPid}) ->
    true;
conn_known_pid(ConnPid, #state{conns = Conns}) ->
    lists:any(
        fun
            (#{conn_pid := P}) -> P =:= ConnPid;
            (_) -> false
        end,
        maps:values(Conns)
    ).
