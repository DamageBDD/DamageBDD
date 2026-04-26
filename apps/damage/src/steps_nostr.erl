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

fmt(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
wait_for_nwc_response(Filter, Relays, Conn, TimeoutMs, PollMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_nwc_response_loop(Filter, Relays, Conn, Deadline, PollMs).

wait_for_nwc_response_loop(Filter, Relays, Conn, Deadline, PollMs) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = Deadline - Now,
    case Remaining =< 0 of
        true ->
            {error, timeout};
        false ->
            ReqTimeout = min(Remaining, PollMs),
            case nostr_pool:req_one(Filter, Relays, ReqTimeout, 1) of
                {ok, Event} ->
                    damage_nwc_client:decrypt_response_event(Conn, Event);
                {error, {all_failed, [{_, {error, not_found}}]}} ->
                    timer:sleep(PollMs),
                    wait_for_nwc_response_loop(Filter, Relays, Conn, Deadline, PollMs);
                {error, not_found} ->
                    timer:sleep(PollMs),
                    wait_for_nwc_response_loop(Filter, Relays, Conn, Deadline, PollMs);
                {error, timeout} ->
                    timer:sleep(PollMs),
                    wait_for_nwc_response_loop(Filter, Relays, Conn, Deadline, PollMs);
                {error, Why} ->
                    {error, Why}
            end
    end.

test() ->
    ok.
