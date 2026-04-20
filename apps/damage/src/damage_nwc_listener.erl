-module(damage_nwc_listener).

-author("OpenAI").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    publish_info/0,
    supported_methods/0
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

-define(DEFAULT_RECONNECT_MS, 5000).
-define(INFO_KIND, 13194).
-define(REQUEST_KIND, 23194).
-define(RESPONSE_KIND, 23195).
-define(NOTIFICATION_KIND, 23197).
-define(BACKCOMPAT_NOTIFICATION_KIND, 23196).

-record(state, {
    relays = [],
    relay_index = 1,
    conn_pid = undefined,
    stream_ref = undefined,
    relay_path = "/",
    reconnect_ms = ?DEFAULT_RECONNECT_MS,
    service_pubkey = undefined,
    sub_id = undefined,
    seen = #{},
    crypto_handler = damage_nostr,
    retry_count = 0,
    max_retries = 10,
    stopped = false
}).

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

init(Opts) ->
    process_flag(trap_exit, true),
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
    {ok, maybe_connect(State0)}.

handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(restart, State) ->
    {noreply,
        maybe_connect(State#state{
            stopped = false,
            retry_count = 0,
            conn_pid = undefined,
            stream_ref = undefined,
            sub_id = undefined
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
handle_info(
    {gun_error, ConnPid, StreamRef, Reason},
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    ?LOG_WARNING("NWC relay gun_error ~p", [Reason]),
    {noreply,
        schedule_reconnect(State#state{
            conn_pid = undefined,
            stream_ref = undefined,
            sub_id = undefined
        })};
handle_info(
    {gun_ws, ConnPid, StreamRef, {text, Msg}},
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    {noreply, handle_ws_message(Msg, State)};
handle_info(
    {gun_down, ConnPid, _Protocol, _Reason, _KilledStreams, _Unprocessed},
    #state{conn_pid = ConnPid} = State
) ->
    ?LOG_WARNING("NWC relay connection down, scheduling reconnect.", []),
    {noreply,
        schedule_reconnect(State#state{
            conn_pid = undefined, stream_ref = undefined, sub_id = undefined
        })};
handle_info({'EXIT', ConnPid, Reason}, #state{conn_pid = ConnPid} = State) ->
    ?LOG_WARNING("NWC relay process exited reason=~p", [Reason]),
    {noreply,
        schedule_reconnect(State#state{
            conn_pid = undefined,
            stream_ref = undefined,
            sub_id = undefined
        })};
handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_DEBUG("Ignoring unrelated EXIT from ~p reason=~p", [Pid, Reason]),
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("Ignoring unhandled info ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{conn_pid = undefined}) ->
    ok;
terminate(_Reason, #state{conn_pid = ConnPid}) ->
    catch gun:close(ConnPid),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

relays(Opts) ->
    case proplists:get_value(relays, Opts, undefined) of
        undefined ->
            case application:get_env(damage, nostr_relays) of
                {ok, Relays} when is_list(Relays), Relays =/= [] ->
                    Relays;
                _ ->
                    []
            end;
        Relays when is_list(Relays) ->
            Relays
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

maybe_connect(#state{stopped = true} = State) ->
    State;
maybe_connect(#state{relays = []} = State) ->
    ?LOG_WARNING("No NWC relays configured, listener is idle.", []),
    State;
maybe_connect(#state{conn_pid = ConnPid} = State) when is_pid(ConnPid) ->
    State;
maybe_connect(#state{relays = Relays, relay_index = Index} = State) ->
    Relay = lists:nth(clamp_index(Index, Relays), Relays),
    case open_ws(Relay) of
        {ok, ConnPid, StreamRef} ->
            State0 = State#state{
                conn_pid = ConnPid,
                stream_ref = StreamRef,
                relay_path = relay_path(Relay),
                retry_count = 0,
                stopped = false
            },
            publish_info_event(subscribe_requests(State0));
        {error, Reason} ->
            Retry1 = State#state.retry_count + 1,
            ?LOG_WARNING(
                "Failed to connect to NWC relay ~p attempt ~p/~p: ~p",
                [Relay, Retry1, State#state.max_retries, Reason]
            ),
            case Retry1 >= State#state.max_retries of
                true ->
                    ?LOG_ERROR(
                        "Stopping NWC listener after ~p failed attempts.",
                        [Retry1]
                    ),
                    State#state{
                        retry_count = Retry1,
                        conn_pid = undefined,
                        stream_ref = undefined,
                        sub_id = undefined,
                        stopped = true
                    };
                false ->
                    schedule_reconnect(
                        next_relay(
                            State#state{
                                retry_count = Retry1,
                                conn_pid = undefined,
                                stream_ref = undefined,
                                sub_id = undefined
                            }
                        )
                    )
            end
    end.

restart() ->
    gen_server:cast(?MODULE, restart).

open_ws(Relay) ->
    #{host := Host0, port := Port, path := Path0, transport := Transport, tls_opts := TlsOpts} =
        relay_spec(Relay),
    Host = normalize_host_for_gun(Host0),
    Path = normalize_ws_path(Path0),
    Opts =
        case Transport of
            tls -> #{transport => tls, tls_opts => TlsOpts};
            tcp -> #{transport => tcp}
        end,
    case damage_gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            _ = link(ConnPid),
            case gun:await_up(ConnPid, 8000) of
                {ok, _Proto} ->
                    ?LOG_INFO("NWC WS upgrade host=~p port=~p path=~p", [Host, Port, Path]),
                    StreamRef = gun:ws_upgrade(ConnPid, Path),
                    receive
                        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
                            {ok, ConnPid, StreamRef};
                        {gun_response, ConnPid, StreamRef, Fin, Status, Headers1} ->
                            maybe_drain_http_body(ConnPid, StreamRef, Fin),
                            catch gun:close(ConnPid),
                            {error, {upgrade_failed, Status, Headers1}}
                    after 10000 ->
                        catch gun:close(ConnPid),
                        {error, timeout}
                    end;
                Other ->
                    catch gun:close(ConnPid),
                    {error, {await_up_failed, Other}}
            end;
        Error ->
            Error
    end.

maybe_drain_http_body(_ConnPid, _StreamRef, fin) ->
    ok;
maybe_drain_http_body(ConnPid, StreamRef, nofin) ->
    _ = catch gun:await_body(ConnPid, StreamRef, 2000),
    ok;
maybe_drain_http_body(_, _, _) ->
    ok.
normalize_host_for_gun(H) when is_list(H) ->
    H;
normalize_host_for_gun(H) when is_binary(H) ->
    binary_to_list(H).

normalize_ws_path(<<>>) ->
    "/";
normalize_ws_path("") ->
    "/";
normalize_ws_path(P) when is_binary(P) ->
    binary_to_list(P);
normalize_ws_path(P) when is_list(P) ->
    P.

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
    #{
        host => Host,
        port => maps:get(port, Uri, default_port(Scheme)),
        path => Path,
        transport => transport_from_scheme(Scheme),
        tls_opts => [{verify, verify_none}]
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

clamp_index(Index, Relays) when Index > length(Relays) ->
    1;
clamp_index(Index, _Relays) when Index < 1 ->
    1;
clamp_index(Index, _Relays) ->
    Index.

next_relay(#state{relays = Relays, relay_index = Index} = State) ->
    Next =
        case length(Relays) of
            0 -> 1;
            N -> ((Index rem N) + 1)
        end,
    State#state{relay_index = Next}.

schedule_reconnect(#state{stopped = true} = State) ->
    State;
schedule_reconnect(#state{retry_count = Retry, max_retries = Max} = State) when Retry >= Max ->
    ?LOG_ERROR("Reconnect suppressed after ~p/~p attempts.", [Retry, Max]),
    State#state{stopped = true};
schedule_reconnect(#state{reconnect_ms = ReconnectMs} = State) ->
    erlang:send_after(ReconnectMs, self(), connect),
    State.

subscribe_requests(#state{conn_pid = undefined} = State) ->
    State;
subscribe_requests(#state{service_pubkey = undefined} = State) ->
    ?LOG_WARNING("NWC listener has no service pubkey, skipping subscription.", []),
    State;
subscribe_requests(
    #state{conn_pid = ConnPid, stream_ref = StreamRef, service_pubkey = PubKey} = State
) ->
    SubId = subscription_id(),
    Filter = #{
        <<"kinds">> => [?REQUEST_KIND],
        <<"#p">> => [PubKey]
    },
    Msg = jsx:encode([<<"REQ">>, SubId, Filter]),
    ok = send_ws_text(ConnPid, StreamRef, Msg),
    State#state{sub_id = SubId}.

publish_info_event(#state{conn_pid = undefined} = State) ->
    State;
publish_info_event(#state{service_pubkey = undefined} = State) ->
    State;
publish_info_event(
    #state{crypto_handler = CryptoHandler, conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    Content = iolist_to_binary(string:join([binary_to_list(M) || M <- supported_methods()], " ")),
    Tags = [],
    case create_signed_event(CryptoHandler, ?INFO_KIND, Content, Tags) of
        {ok, Event} ->
            ok = send_ws_text(ConnPid, StreamRef, jsx:encode([<<"EVENT">>, Event])),
            State;
        {error, Reason} ->
            ?LOG_WARNING("Failed to publish NWC info event: ~p", [Reason]),
            State
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

send_response(_Event, _Payload, #state{conn_pid = undefined}) ->
    {error, disconnected};
send_response(Event, Payload, #state{
    conn_pid = ConnPid, stream_ref = StreamRef, crypto_handler = CryptoHandler
}) ->
    case encode_response(CryptoHandler, Event, Payload) of
        {ok, ResponseEvent} ->
            send_ws_text(ConnPid, StreamRef, jsx:encode([<<"EVENT">>, ResponseEvent]));
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

send_ws_text(ConnPid, StreamRef, Msg) ->
    ?LOG_DEBUG("send_ws_text ~p", [Msg]),
    _ = gun:ws_send(ConnPid, StreamRef, {text, Msg}),
    ok.

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
