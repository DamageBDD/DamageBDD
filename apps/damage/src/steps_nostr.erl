-module(steps_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-export([step/6]).
-export([test/0]).
-import(damage_utils, [to_bin/1]).

-include_lib("kernel/include/logger.hrl").
step(
    _Config,
    Context,
    _,
    _N,
    ["I create and store a nostr event as", NostrEventVariable],
    Body
) ->
    ?LOG_DEBUG("create store nostr event ~p ~p", [NostrEventVariable, Body]),
    maps:put(
        NostrEventVariable,
        damage_nostr:construct_event(Body),
        Context
    );
%% Generate unsigned NIP-56 reports from monitored events in Context
%%
%% Body expects JSON like:
%% {
%%   "from": "monitored_events",
%%   "store_as": "reports_out",
%%   "report_type": "spam",
%%   "content": "reason text",
%%   "opts": {"L":"social.nos.ontology","l":"NS-spam"}
%% }
%%
step(
    _Config,
    Context,
    _,
    _N,
    ["I generate NIP-56 reports from", FromVar, "store as", OutVar],
    Body
) ->
    %% pull config from body
    ReportType = map_get_bin(Body, <<"report_type">>, <<"other">>),
    Content = map_get_bin(Body, <<"content">>, <<>>),
    Opts = maps:get(<<"opts">>, Body, #{}),

    Events = maps:get(FromVar, Context, []),
    Reports =
        [
            mk_report_from_event(E, ReportType, Content, Opts)
         || E <- Events, is_map(E)
        ],

    maps:put(list_to_atom(OutVar), Reports, Context);
%% Publish NIP-56 reports from monitored events in Context
%%
%% Body expects JSON like:
%% {
%%   "from": "monitored_events",
%%   "store_as": "report_responses",
%%   "nsec_key": "damage_nostr_nsec",
%%   "report_type": "illegal",
%%   "content": "why",
%%   "opts": {}
%% }
%%
step(
    _Config,
    Context,
    _,
    _N,
    ["I publish NIP-56 reports from", FromVar, "store responses as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, damage_nostr_nsec),
    ReportType = map_get_bin(Body, <<"report_type">>, <<"other">>),
    Content = map_get_bin(Body, <<"content">>, <<>>),
    Opts = maps:get(<<"opts">>, Body, #{}),

    Events = maps:get(list_to_atom(FromVar), Context, []),
    Responses =
        [
            publish_report_from_event(NsecKey, E, ReportType, Content, Opts)
         || E <- Events, is_map(E)
        ],

    maps:put(list_to_atom(OutVar), Responses, Context);
step(
    _Config,
    Context,
    _,
    _N,
    ["I parse the NWC URI in", UriVar, "and store it as", OutVar],
    _
) ->
    Uri = maps:get(list_to_atom(UriVar), Context),
    Conn = damage_nwc_client:parse_nwc_uri(Uri),
    maps:put(list_to_atom(OutVar), Conn, Context);
step(
    _Config,
    Context,
    _,
    _N,
    ["I build NWC request", Method, "using", ConnVar, "store as", OutVar],
    Body
) ->
    Conn = maps:get(list_to_atom(ConnVar), Context),
    Params = normalize_body_map(Body),
    case damage_nwc_client:build_request_event(Conn, Method, Params) of
        {ok, Event, RequestId} ->
            maps:put(
                list_to_atom(OutVar),
                #{
                    event => Event,
                    request_id => RequestId,
                    method => to_bin(Method),
                    conn => Conn
                },
                Context
            );
        {error, Reason} ->
            maps:put(fail, damage_utils:strf("NWC request build failed: ~p", [Reason]), Context)
    end;
step(
    _Config,
    Context,
    _,
    _N,
    ["I publish NWC request in", ReqVar, "store relay ack as", OutVar],
    _
) ->
    Req = maps:get(list_to_atom(ReqVar), Context),
    Event = maps:get(event, Req),
    Conn = maps:get(conn, Req),
    Relays = damage_nwc_client:relays_for_conn(Conn),

    ?LOG_INFO("NWC publish using relays=~p", [Relays]),
    case damage_nwc_client:publish(Event, Relays) of
        ok ->
            maps:put(list_to_atom(OutVar), ok, Context);
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf("publish nwc event ~p", [Reason]),
                Context
            )
    end;
step(
    _Config,
    Context,
    _,
    _N,
    [
        "I publish NWC request in",
        ReqVar,
        "using",
        ConnVar,
        "and wait for response store as",
        OutVar
    ],
    Body
) ->
    Req = maps:get(list_to_atom(ReqVar), Context),
    Conn = maps:get(list_to_atom(ConnVar), Context),

    BodyMap = normalize_body_map(Body),
    TimeoutMs = map_get_int(BodyMap, <<"timeout_ms">>, 65000),
    PollMs = map_get_int(BodyMap, <<"poll_ms">>, 1000),

    case publish_and_wait_nwc_response(Req, Conn, TimeoutMs, PollMs) of
        {ok, RespJson} ->
            maps:put(list_to_atom(OutVar), RespJson, Context);
        {error, Why} ->
            ?LOG_ERROR("publish_and_wait nwc response failed ~p", [Why]),
            maps:put(
                fail,
                fmt(Why),
                maps:put(list_to_atom(OutVar), #{error => fmt(Why)}, Context)
            );
        RespJson when is_map(RespJson) ->
            maps:put(list_to_atom(OutVar), RespJson, Context)
    end;
step(
    _Config,
    Context,
    _,
    _N,
    ["I wait for NWC response to", ReqVar, "using", ConnVar, "store as", OutVar],
    Body
) ->
    Req = maps:get(list_to_atom(ReqVar), Context),
    Conn = maps:get(list_to_atom(ConnVar), Context),
    RequestId = maps:get(request_id, Req),
    WalletPubHex = maps:get(wallet_pubkey, Conn),

    BodyMap = normalize_body_map(Body),
    TimeoutMs = map_get_int(BodyMap, <<"timeout_ms">>, 65000),
    PollMs = map_get_int(BodyMap, <<"poll_ms">>, 1000),

    Filter = #{
        <<"kinds">> => [23195],
        <<"authors">> => [WalletPubHex],
        <<"#e">> => [RequestId],
        <<"limit">> => 1
    },

    Relays = damage_nwc_client:relays_for_conn(Conn),
    ?LOG_DEBUG("wait nwc response relays=~p filter=~p", [Relays, Filter]),
    ok = nostr_pool:ensure_started(Relays),

    case wait_for_nwc_response(Filter, Relays, Conn, TimeoutMs, PollMs) of
        {ok, RespJson} ->
            maps:put(list_to_atom(OutVar), RespJson, Context);
        {error, Why} ->
            ?LOG_ERROR("wait nwc response failed ~p filter=~p relays=~p", [Why, Filter, Relays]),
            maps:put(
                fail,
                fmt(Why),
                maps:put(list_to_atom(OutVar), #{error => fmt(Why)}, Context)
            )
    end.
%% --- helpers ------------------------------------------------------------

mk_report_from_event(Event, ReportType, Content, Opts) ->
    %% We don’t have reporter pubkey here (that’s in damage_nostr state),
    %% so we return a “report request” structure you can later sign/publish.
    %% If you want unsigned *nostr event maps*, call into damage_nostr directly
    %% with a ReporterPubKey; but steps typically don’t have it.
    ReportedPubKey = pick_pubkey(Event),
    MaybeEventId = pick_id(Event),
    #{
        reported_pubkey => ReportedPubKey,
        event_id => MaybeEventId,
        report_type => ReportType,
        content => Content,
        opts => Opts
    }.

publish_report_from_event(NsecKey, Event, ReportType, Content, Opts) ->
    ReportedPubKey = pick_pubkey(Event),
    MaybeEventId = pick_id(Event),
    %% delegate to damage_nostr publisher
    damage_nostr:post_report(NsecKey, ReportedPubKey, MaybeEventId, ReportType, Content, Opts).

pick_pubkey(#{<<"pubkey">> := P}) -> P;
pick_pubkey(#{pubkey := P}) -> P;
pick_pubkey(_) -> <<>>.

pick_id(#{<<"id">> := I}) -> I;
pick_id(#{id := I}) -> I;
pick_id(_) -> <<>>.

map_get_bin(M, K, Default) ->
    case maps:get(K, M, Default) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V);
        V when is_atom(V) -> atom_to_binary(V, utf8);
        _ -> Default
    end.

map_get_atom_or_bin(M, K, DefaultAtom) ->
    case maps:get(K, M, DefaultAtom) of
        A when is_atom(A) -> A;
        B when is_binary(B) -> binary_to_atom(B, utf8);
        L when is_list(L) -> list_to_atom(L);
        _ -> DefaultAtom
    end.
normalize_body_map(M) when is_map(M) -> M;
normalize_body_map(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 -> #{};
        _ -> jsx:decode(Bin, [return_maps])
    end;
normalize_body_map(_) ->
    #{}.

map_get_int(M, K, Default) ->
    case maps:get(K, M, Default) of
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            try
                binary_to_integer(B)
            catch
                _:_ -> Default
            end;
        L when is_list(L) ->
            try
                list_to_integer(L)
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

wait_for_nwc_response(Filter, Relays, Conn, TimeoutMs, _PollMs) ->
    Fanout = max(1, length(Relays)),
    case nostr_pool:req_one(Filter, Relays, TimeoutMs, Fanout) of
        {ok, Event} ->
            damage_nwc_client:decrypt_response_event(Conn, Event);
        {error, Why} ->
            {error, Why}
    end.
nwc_test_relays(Conn) ->
    Relays0 = damage_nwc_client:relays_for_conn(Conn),
    Allowed = [
        <<"wss://nos.lol">>,
        <<"wss://offchain.pub">>,
        <<"wss://relay.primal.net">>,
        <<"wss://nostr-01.yakihonne.com">>,
        <<"wss://nostr-02.yakihonne.com">>
    ],
    AllowedMap = maps:from_list([{canonical_url(U), true} || U <- Allowed]),
    Relays1 =
        [
            R#{url => canonical_url(maps:get(url, R)), proxy => direct}
         || R <- damage_nostr:normalize_relays(Relays0),
            maps:is_key(canonical_url(maps:get(url, R)), AllowedMap)
        ],
    case take_unique_relays(4, damage_nostr:score_relays(Relays1)) of
        [] ->
            [
                #{url => <<"wss://nos.lol">>, proxy => direct},
                #{url => <<"wss://offchain.pub">>, proxy => direct},
                #{url => <<"wss://relay.primal.net">>, proxy => direct}
            ];
        Rs ->
            Rs
    end.
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
publish_and_wait_nwc_response(Req, Conn, TimeoutMs, _PollMs) ->
    Event = maps:get(event, Req),
    RequestId = maps:get(request_id, Req),
    WalletPubHex = maps:get(wallet_pubkey, Conn),

    Relays = nwc_test_relays(Conn),

    Filter = #{
        <<"kinds">> => [23195],
        <<"authors">> => [WalletPubHex],
        <<"#e">> => [RequestId],
        <<"limit">> => 1
    },

    Parent = self(),

    Workers =
        [
            spawn(fun() ->
                Url = maps:get(url, Relay, Relay),
                Result =
                    try
                        direct_nwc_roundtrip(Relay, Event, Filter, Conn, TimeoutMs)
                    catch
                        C:R:S ->
                            {error, {direct_nwc_crash, C, R, stack_top(S)}}
                    end,
                Parent ! {nwc_direct_result, RequestId, Url, Result}
            end)
         || Relay <- Relays
        ],

    collect_direct_nwc_response(RequestId, Workers, TimeoutMs + 5000, []).

direct_nwc_roundtrip(Relay, Event, Filter, Conn, TimeoutMs) ->
    Url = maps:get(url, Relay, Relay),

    ?LOG_INFO("NWC direct roundtrip opening relay=~p", [Url]),

    case damage_nostr:open_relay_ws(Relay, #{connect_timeout => min(15000, TimeoutMs)}) of
        {ok, ConnPid, StreamRef} ->
            try
                SubId = nwc_response_sub_id(),

                ReqMsg = jsx:encode([<<"REQ">>, SubId, Filter]),
                case safe_ws_send(ConnPid, StreamRef, ReqMsg) of
                    ok ->
                        timer:sleep(250),

                        EventMsg = jsx:encode([<<"EVENT">>, Event]),
                        case safe_ws_send(ConnPid, StreamRef, EventMsg) of
                            ok ->
                                await_direct_nwc_response(
                                    ConnPid,
                                    StreamRef,
                                    SubId,
                                    Conn,
                                    TimeoutMs
                                );
                            PubErr ->
                                {error, {publish_ws_send_failed, PubErr}}
                        end;
                    SubErr ->
                        {error, {subscribe_ws_send_failed, SubErr}}
                end
            after
                catch gun:close(ConnPid)
            end;
        {error, Reason} ->
            {error, {open_relay_failed, Url, Reason}}
    end.

nwc_response_sub_id() ->
    Rand = crypto:strong_rand_bytes(6),
    <<"nwc_resp_", (binary:encode_hex(Rand))/binary>>.

safe_ws_send(ConnPid, StreamRef, Msg) ->
    try gun:ws_send(ConnPid, StreamRef, {text, Msg}) of
        ok -> ok;
        Other -> {error, Other}
    catch
        C:R ->
            {error, {C, R}}
    end.
await_direct_nwc_response(ConnPid, StreamRef, SubId, Conn, TimeoutMs) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case safe_decode_frame(Msg) of
                [<<"EVENT">>, SubId, Event] when is_map(Event) ->
                    damage_nwc_client:decrypt_response_event(Conn, Event);
                [<<"OK">>, EventId, Accepted, Message] ->
                    ?LOG_DEBUG(
                        "NWC direct publish OK event_id=~p accepted=~p msg=~p",
                        [EventId, Accepted, Message]
                    ),
                    await_direct_nwc_response(ConnPid, StreamRef, SubId, Conn, TimeoutMs);
                [<<"EOSE">>, SubId] ->
                    await_direct_nwc_response(ConnPid, StreamRef, SubId, Conn, TimeoutMs);
                [<<"NOTICE">>, Notice] ->
                    ?LOG_WARNING("NWC direct relay notice ~p", [Notice]),
                    await_direct_nwc_response(ConnPid, StreamRef, SubId, Conn, TimeoutMs);
                Other ->
                    ?LOG_DEBUG("NWC direct ignored frame shape=~p", [term_shape(Other)]),
                    await_direct_nwc_response(ConnPid, StreamRef, SubId, Conn, TimeoutMs)
            end;
        {gun_down, ConnPid, Protocol, Reason, KilledStreams} ->
            {error, {gun_down, Protocol, Reason, safe_len(KilledStreams)}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams, Unprocessed} ->
            {error, {gun_down, Protocol, Reason, safe_len(KilledStreams), safe_len(Unprocessed)}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {gun_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {gun_error, Reason}}
    after TimeoutMs ->
        {error, timeout}
    end.

safe_decode_frame(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        Frame -> Frame
    catch
        C:R ->
            {decode_failed, C, R, byte_size(Msg)}
    end.
collect_direct_nwc_response(RequestId, Workers, TimeoutMs, Errors) ->
    receive
        {nwc_direct_result, RequestId, Url, {ok, RespJson}} ->
            kill_workers(Workers),
            ?LOG_INFO("NWC direct response received relay=~p", [Url]),
            {ok, RespJson};
        {nwc_direct_result, RequestId, Url, {error, Reason}} ->
            _RemainingWorkers = remove_dead_worker(self(), Workers),
            Errors1 = [{Url, compact_error(Reason)} | Errors],
            case length(Errors1) >= length(Workers) of
                true ->
                    {error, #{error => all_direct_relays_failed, relays => lists:reverse(Errors1)}};
                false ->
                    collect_direct_nwc_response(RequestId, Workers, TimeoutMs, Errors1)
            end
    after TimeoutMs ->
        kill_workers(Workers),
        {error, #{error => direct_nwc_timeout, relays => lists:reverse(Errors)}}
    end.

kill_workers(Workers) ->
    lists:foreach(
        fun(Pid) when is_pid(Pid) ->
            exit(Pid, kill)
        end,
        Workers
    ).

remove_dead_worker(_Parent, Workers) ->
    Workers.
safe_len(L) when is_list(L) -> length(L);
safe_len(_) -> 0.

stack_top([{M, F, A, _} | _]) -> {M, F, A};
stack_top(_) -> undefined.

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
fmt(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [compact_error(Term)])).

compact_error(#{error := _} = M) ->
    maps:map(fun(_K, V) -> compact_error(V) end, M);
compact_error(#{publish_error := _} = M) ->
    maps:map(fun(_K, V) -> compact_error(V) end, M);
compact_error(#{response_error := _} = M) ->
    maps:map(fun(_K, V) -> compact_error(V) end, M);
compact_error({publish_timeout, EventId, TimeoutMs, Relays}) ->
    #{
        error => publish_timeout,
        event_id => EventId,
        timeout_ms => TimeoutMs,
        relays => Relays
    };
compact_error({publish_failed_after_reset, A, B}) ->
    #{
        error => publish_failed_after_reset,
        first => compact_error(A),
        second => compact_error(B)
    };
compact_error({error, Reason}) ->
    compact_error(Reason);
compact_error(Term) when is_map(Term) ->
    %% Preserve small diagnostic maps; compact large payload maps.
    case map_size(Term) =< 8 of
        true ->
            maps:map(fun(_K, V) -> compact_error(V) end, Term);
        false ->
            #{type => map, size => map_size(Term), keys => maps:keys(Term)}
    end;
compact_error(Term) when is_list(Term) ->
    #{type => list, length => length(Term)};
compact_error(Term) when is_tuple(Term) ->
    #{type => tuple, size => tuple_size(Term), tag => element(1, Term)};
compact_error(Term) when is_binary(Term), byte_size(Term) > 96 ->
    #{type => binary, bytes => byte_size(Term)};
compact_error(Term) ->
    Term.

test() ->
    ok.
