%%--------------------------------------------------------------------
%% damage_nsecbunker_relay
%%
%% Live NIP-46 relay adapter for damage_nsecbunker.
%%
%% This module owns the public-relay WebSocket surface used by
%% damage_nostr_relay_client. It subscribes for kind:24133 requests p-tagged
%% to the bunker pubkey and feeds matching events back into the existing
%% damage_nostr_relay_client -> damage_nsecbunker path.
%%
%% It also publishes signed bunker response events to the configured relays.
%%
%% Deliberate boundaries:
%%   * no signing happens here
%%   * no nsec / vault material is loaded here
%%   * inbound events are dispatched asynchronously to avoid a gen_server
%%     deadlock when damage_nostr_relay_client publishes the reply back
%%     through this adapter
%%--------------------------------------------------------------------
-module(damage_nsecbunker_relay).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% Public API / MFA targets for damage_nostr_relay_client
-export([
    start_link/0,
    child_spec/0,
    status/0,
    subscribe/1,
    subscribe/2,
    publish_event/1,
    publish_event/2,
    broadcast_event/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(NIP46_KIND, 24133).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 15000).
-define(DEFAULT_PUBLISH_TIMEOUT_MS, 15000).
-define(DEFAULT_RECONNECT_MS, 5000).
-define(SUBSCRIBE_RETRY_MS, 500).
-define(MAX_SUBSCRIBE_ATTEMPTS, 20).
-define(MAX_SEEN_IDS, 2000).

-record(st, {
    relays = [] :: [map()],
    filter = undefined :: undefined | map(),
    %% ConnPid => #{relay := map(), relay_url := binary(), stream_ref := term(), sub_id := binary()}
    conns = #{} :: map(),
    seen_ids = #{} :: map(),
    %% newest first; public event ids only, no content or secrets
    recent_inbound_event_ids = [] :: [binary()],
    reconnect_ms = ?DEFAULT_RECONNECT_MS :: pos_integer(),
    stats = #{} :: map()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

status() ->
    call(status).

%% Called by damage_nostr_relay_client via relay_subscribe_mfa or default path.
subscribe(Filter) when is_map(Filter) ->
    call({subscribe, Filter, configured_relays()}).

%% Optional MFA shape: {damage_nsecbunker_relay, subscribe, [Relays]}.
subscribe(Filter, Relays0) when is_map(Filter), is_list(Relays0) ->
    call({subscribe, Filter, normalize_relays(Relays0)}).

%% Called by damage_nostr_relay_client via relay_publish_mfa or default path.
publish_event(Event) when is_map(Event) ->
    call({publish_event, Event, configured_relays()}).

%% Optional MFA shape: {damage_nsecbunker_relay, publish_event, [Relays]}.
publish_event(Event, Relays0) when is_map(Event), is_list(Relays0) ->
    call({publish_event, Event, normalize_relays(Relays0)}).

%% Compatibility with the older damage_nostr_relay_client fallback shape.
broadcast_event(Relays0, Event) when is_list(Relays0), is_map(Event) ->
    publish_event(Event, Relays0).

call(Request) ->
    case whereis(?SERVER) of
        undefined -> {error, nsecbunker_relay_not_running};
        _Pid -> gen_server:call(?SERVER, Request, 60000)
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    {ok, #st{relays = configured_relays(), stats = empty_stats()}}.

handle_call(
    status,
    _From,
    St = #st{
        relays = Relays,
        filter = Filter,
        conns = Conns,
        stats = Stats,
        recent_inbound_event_ids = RecentInbound
    }
) ->
    LastInbound =
        case RecentInbound of
            [EventId | _] -> EventId;
            [] -> undefined
        end,
    {reply,
        #{
            running => true,
            subscribed => subscribed_count(Conns) > 0,
            relays => [relay_url(R) || R <- Relays],
            filter => Filter,
            connections => connection_status(Conns),
            stats => Stats,
            last_inbound_event_id => LastInbound,
            recent_inbound_event_ids => RecentInbound
        },
        St};
handle_call({subscribe, Filter0, Relays0}, _From, St0) ->
    Filter = normalize_filter(Filter0),
    Relays = normalize_relays(Relays0),

    %% Replace the previous subscription set cleanly, but do not block the
    %% gen_server waiting for websocket upgrades.  Earlier versions waited
    %% inside this call; while waiting, status/0 could not be served and the
    %% live BDD timed out with damage_nsecbunker_relay:status/0.
    close_all(St0#st.conns),
    St1 = St0#st{relays = Relays, filter = Filter, conns = #{}},

    {Results, St2} = subscribe_all(Relays, Filter, St1),
    Opened = length([ok || {_, ok} <- Results]),
    Reply =
        case Opened > 0 of
            true ->
                {ok, #{opened => Opened, subscribing => true, relays => Results, filter => Filter}};
            false ->
                {error, #{error => all_relays_failed, relays => Results, filter => Filter}}
        end,
    {reply, Reply, St2};
handle_call({publish_event, Event0, Relays0}, _From, St0) ->
    Event = normalize_event(Event0),
    Relays = normalize_relays(Relays0),
    TimeoutMs = publish_timeout_ms(),
    Result = publish_to_relays(Event, Relays, TimeoutMs),
    St1 = bump_publish_stats(Result, St0),
    {reply, Result, St1};
handle_call(_Other, _From, St) ->
    {reply, {error, bad_call}, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({gun_up, ConnPid, Protocol}, St0) ->
    %% gun:open/3 reports TCP/TLS readiness before the WebSocket upgrade.
    %% Do not treat this as a subscription. The REQ frame is sent only after
    %% gun_upgrade/4 confirms the websocket is active.
    case maps:get(ConnPid, St0#st.conns, undefined) of
        #{relay_url := RelayUrl} ->
            ?LOG_DEBUG("nsecbunker relay gun_up relay=~p protocol=~p", [RelayUrl, Protocol]);
        _ ->
            ok
    end,
    {noreply, St0};
handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers}, St0) ->
    handle_ws_upgrade(ConnPid, StreamRef, St0);
handle_info({gun_response, ConnPid, StreamRef, _IsFin, 101, _Headers}, St0) ->
    %% Older gun paths may expose the websocket upgrade as an HTTP 101 response.
    handle_ws_upgrade(ConnPid, StreamRef, St0);
handle_info({gun_response, ConnPid, StreamRef, _IsFin, Status, _Headers}, St0) ->
    handle_conn_down(ConnPid, {websocket_upgrade_rejected, StreamRef, Status}, St0);
handle_info({ensure_subscription, ConnPid}, St0) ->
    case maps:get(ConnPid, St0#st.conns, undefined) of
        #{subscribed := true} ->
            {noreply, St0};
        #{stream_ref := StreamRef} = Conn ->
            case send_subscription(ConnPid, StreamRef, Conn, St0) of
                {ok, St1} ->
                    {noreply, St1};
                {{error, Reason}, St1} ->
                    {noreply, maybe_retry_subscription(ConnPid, Reason, St1)}
            end;
        _ ->
            {noreply, St0}
    end;
handle_info({gun_ws, ConnPid, StreamRef, {text, Msg}}, St0) ->
    case maps:get(ConnPid, St0#st.conns, undefined) of
        #{stream_ref := StreamRef, sub_id := SubId, relay_url := RelayUrl, subscribed := true} =
                Conn ->
            handle_relay_frame(ConnPid, Conn, SubId, RelayUrl, Msg, St0);
        #{stream_ref := StreamRef, relay_url := RelayUrl} ->
            ?LOG_DEBUG("nsecbunker relay ignored websocket frame before subscription relay=~p", [
                RelayUrl
            ]),
            {noreply, St0};
        _ ->
            ?LOG_DEBUG("nsecbunker relay ignored websocket frame from unknown conn=~p", [ConnPid]),
            {noreply, St0}
    end;
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}, St0) ->
    handle_conn_down(ConnPid, {gun_down, Protocol, Reason, safe_len(KilledStreams)}, St0);
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams, UnprocessedStreams}, St0) ->
    handle_conn_down(
        ConnPid,
        {gun_down, Protocol, Reason, safe_len(KilledStreams), safe_len(UnprocessedStreams)},
        St0
    );
handle_info({gun_error, ConnPid, StreamRef, Reason}, St0) ->
    handle_conn_down(ConnPid, {gun_error, StreamRef, Reason}, St0);
handle_info({gun_error, ConnPid, Reason}, St0) ->
    handle_conn_down(ConnPid, {gun_error, Reason}, St0);
handle_info({reconnect, RelayUrl}, St0 = #st{filter = undefined}) ->
    ?LOG_DEBUG("nsecbunker relay reconnect ignored without active filter relay=~p", [RelayUrl]),
    {noreply, St0};
handle_info({reconnect, RelayUrl}, St0 = #st{filter = Filter}) ->
    Relay = find_relay(RelayUrl, St0#st.relays),
    case Relay of
        undefined ->
            {noreply, St0};
        _ ->
            case connect_and_subscribe(Relay, Filter, St0) of
                {ok, St1} ->
                    {noreply, St1};
                {{error, Reason}, St1} ->
                    ?LOG_WARNING("nsecbunker relay reconnect failed relay=~p reason=~p", [
                        RelayUrl, Reason
                    ]),
                    schedule_reconnect(RelayUrl, St1),
                    {noreply, St1}
            end
    end;
handle_info(Other, St) ->
    ?LOG_DEBUG("nsecbunker relay ignored message shape=~p", [term_shape(Other)]),
    {noreply, St}.

terminate(_Reason, St) ->
    close_all(St#st.conns),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%%====================================================================
%% Subscribe/listen path
%%====================================================================

subscribe_all(Relays, Filter, St0) ->
    lists:foldl(
        fun(Relay, {Acc, StAcc}) ->
            RelayUrl = relay_url(Relay),
            case connect_and_subscribe(Relay, Filter, StAcc) of
                {ok, St1} ->
                    {[{RelayUrl, ok} | Acc], St1};
                {{error, Reason}, St1} ->
                    schedule_reconnect(RelayUrl, St1),
                    {[{RelayUrl, {error, compact_error(Reason)}} | Acc], St1}
            end
        end,
        {[], St0},
        Relays
    ).

connect_and_subscribe(Relay, Filter, St0) ->
    RelayUrl = relay_url(Relay),
    case damage_nostr:open_relay_ws(Relay, #{connect_timeout => connect_timeout_ms()}) of
        {ok, ConnPid, StreamRef} ->
            SubId = make_sub_id(),
            Conn = #{
                relay => Relay,
                relay_url => RelayUrl,
                stream_ref => StreamRef,
                sub_id => SubId,
                filter => Filter,
                subscribed => false,
                subscribe_attempts => 0,
                opened_at => erlang:system_time(second)
            },
            Conns0 = St0#st.conns,
            %% Return immediately after the websocket upgrade request has been
            %% initiated. The actual REQ subscription is normally sent from
            %% handle_ws_upgrade/3. Some damage_gun/open_ws paths consume the
            %% upgrade confirmation internally before returning, so also schedule
            %% an async subscription attempt.  The connection is marked
            %% subscribed only after the REQ ws_send succeeds.
            St1 = St0#st{conns = Conns0#{ConnPid => Conn}},
            schedule_subscription_attempt(ConnPid, 0),
            {ok, St1};
        {error, Reason} ->
            {{error, {open_relay_failed, RelayUrl, Reason}}, St0}
    end.

await_ws_upgrade(ConnPid, StreamRef, RelayUrl, TimeoutMs) ->
    receive
        {gun_up, ConnPid, Protocol} ->
            ?LOG_DEBUG("nsecbunker relay gun_up relay=~p protocol=~p", [RelayUrl, Protocol]),
            await_ws_upgrade(ConnPid, StreamRef, RelayUrl, TimeoutMs);
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
            ok;
        {gun_response, ConnPid, StreamRef, _IsFin, 101, _Headers} ->
            ok;
        {gun_response, ConnPid, StreamRef, _IsFin, Status, _Headers} ->
            {error, {websocket_upgrade_rejected, Status}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {gun_error, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {gun_error, Reason}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams} ->
            {error, {gun_down, Protocol, Reason, safe_len(KilledStreams)}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams, UnprocessedStreams} ->
            {error,
                {gun_down, Protocol, Reason, safe_len(KilledStreams), safe_len(UnprocessedStreams)}}
    after TimeoutMs ->
        {error, websocket_upgrade_timeout}
    end.

handle_ws_upgrade(ConnPid, StreamRef, St0) ->
    case maps:get(ConnPid, St0#st.conns, undefined) of
        #{stream_ref := StreamRef, subscribed := true, relay_url := RelayUrl} ->
            ?LOG_DEBUG("nsecbunker relay duplicate websocket upgrade relay=~p", [RelayUrl]),
            {noreply, St0};
        #{stream_ref := StreamRef} = Conn ->
            case send_subscription(ConnPid, StreamRef, Conn, St0) of
                {ok, St1} -> {noreply, St1};
                {{error, Reason}, St1} -> {noreply, maybe_retry_subscription(ConnPid, Reason, St1)}
            end;
        _ ->
            ?LOG_DEBUG("nsecbunker relay websocket upgrade for unknown conn=~p", [ConnPid]),
            {noreply, St0}
    end.

send_subscription(ConnPid, StreamRef, Conn, St0) ->
    RelayUrl = maps:get(relay_url, Conn),
    SubId = maps:get(sub_id, Conn),
    Filter = maps:get(filter, Conn, St0#st.filter),
    Req = jsx:encode([<<"REQ">>, SubId, Filter]),
    case safe_ws_send(ConnPid, StreamRef, Req) of
        ok ->
            ?LOG_INFO("nsecbunker NIP46 subscribed relay=~p sub_id=~p filter=~p", [
                RelayUrl, SubId, Filter
            ]),
            Conn1 = Conn#{subscribed => true, subscribed_at => erlang:system_time(second)},
            Conns0 = St0#st.conns,
            {ok, St0#st{conns = Conns0#{ConnPid => Conn1}}};
        {error, Reason} ->
            {{error, {subscribe_send_failed, Reason}}, St0}
    end.

schedule_subscription_attempt(ConnPid, DelayMs) when is_pid(ConnPid), is_integer(DelayMs) ->
    erlang:send_after(max(0, DelayMs), self(), {ensure_subscription, ConnPid}),
    ok.

maybe_retry_subscription(ConnPid, Reason, St0) ->
    case maps:get(ConnPid, St0#st.conns, undefined) of
        #{relay_url := RelayUrl, subscribe_attempts := Attempts} = Conn when
            Attempts < ?MAX_SUBSCRIBE_ATTEMPTS
        ->
            Attempts1 = Attempts + 1,
            ?LOG_DEBUG(
                "nsecbunker relay subscription not ready relay=~p attempt=~p reason=~p",
                [RelayUrl, Attempts1, compact_error(Reason)]
            ),
            Conn1 = Conn#{
                subscribe_attempts => Attempts1,
                last_subscribe_error => compact_error(Reason)
            },
            Conns1 = (St0#st.conns)#{ConnPid => Conn1},
            schedule_subscription_attempt(ConnPid, ?SUBSCRIBE_RETRY_MS),
            St0#st{conns = Conns1};
        #{relay_url := RelayUrl} = Conn ->
            ?LOG_WARNING(
                "nsecbunker relay subscription failed permanently relay=~p attempts=~p reason=~p",
                [RelayUrl, maps:get(subscribe_attempts, Conn, 0), compact_error(Reason)]
            ),
            safe_close_gun(ConnPid),
            Conns1 = maps:remove(ConnPid, St0#st.conns),
            St1 = inc_stat(connection_downs, St0#st{conns = Conns1}),
            schedule_reconnect(RelayUrl, St1),
            St1;
        _ ->
            St0
    end.

handle_relay_frame(_ConnPid, _Conn, SubId, RelayUrl, Msg, St0) ->
    case safe_decode(Msg) of
        [<<"EVENT">>, SubId, Event0] when is_map(Event0) ->
            Event = normalize_event(Event0),
            EventId = event_id(Event),
            case seen(EventId, St0) of
                true ->
                    ?LOG_DEBUG(
                        "nsecbunker relay duplicate inbound event ignored relay=~p event_id=~p", [
                            RelayUrl, EventId
                        ]
                    ),
                    {noreply, St0};
                false ->
                    ?LOG_INFO("nsecbunker relay inbound NIP46 event relay=~p event_id=~p", [
                        RelayUrl, EventId
                    ]),
                    dispatch_inbound(Event, RelayUrl),
                    St1 = mark_seen(EventId, St0),
                    St2 = record_inbound_event(EventId, St1),
                    {noreply, inc_stat(inbound_events, inc_stat(dispatched_events, St2))}
            end;
        [<<"EOSE">>, SubId] ->
            ?LOG_DEBUG("nsecbunker relay EOSE relay=~p sub_id=~p", [RelayUrl, SubId]),
            {noreply, inc_stat(eose_frames, St0)};
        [<<"NOTICE">>, Notice] ->
            ?LOG_WARNING("nsecbunker relay notice relay=~p notice=~p", [RelayUrl, Notice]),
            {noreply, inc_stat(notice_frames, St0)};
        [<<"OK">>, _EventId, _Accepted, _Text] ->
            %% OK frames here are for anything published on this persistent connection.
            {noreply, St0};
        Other ->
            ?LOG_DEBUG("nsecbunker relay ignored frame relay=~p shape=~p", [
                RelayUrl, term_shape(Other)
            ]),
            {noreply, St0}
    end.

handle_conn_down(ConnPid, Reason, St0) ->
    case maps:take(ConnPid, St0#st.conns) of
        {#{relay_url := RelayUrl}, Conns1} ->
            ?LOG_WARNING("nsecbunker relay connection down relay=~p reason=~p", [RelayUrl, Reason]),
            St1 = inc_stat(connection_downs, St0#st{conns = Conns1}),
            schedule_reconnect(RelayUrl, St1),
            {noreply, St1};
        error ->
            {noreply, St0}
    end.

schedule_reconnect(RelayUrl, #st{reconnect_ms = Ms}) ->
    erlang:send_after(Ms, self(), {reconnect, RelayUrl}),
    ok.

%% IMPORTANT: do not call damage_nostr_relay_client:inbound_event/1 inline
%% from this gen_server. That call may publish a response through this same
%% module, so inline execution can deadlock. Use a short-lived worker instead.
dispatch_inbound(Event, RelayUrl) ->
    _ = spawn(fun() ->
        Result =
            try damage_nostr_relay_client:inbound_event(Event) of
                R -> R
            catch
                C:R:S -> {crash, C, R, stack_top(S)}
            end,
        ?LOG_INFO("nsecbunker relay inbound dispatch complete relay=~p event_id=~p result=~p", [
            RelayUrl, event_id(Event), compact_error(Result)
        ])
    end),
    ok.

%%====================================================================
%% Publish path
%%====================================================================

publish_to_relays(Event, Relays, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Workers =
        [
            begin
                RelayUrl = relay_url(Relay),
                Pid = spawn(fun() ->
                    Result =
                        try direct_publish_event(Event, Relay, TimeoutMs) of
                            R -> R
                        catch
                            C:R:S -> {error, {publish_crash, C, R, stack_top(S)}}
                        end,
                    Parent ! {Ref, RelayUrl, Result}
                end),
                Pid
            end
         || Relay <- Relays
        ],
    collect_publish_results(Ref, length(Workers), TimeoutMs + 2000, Workers, []).

collect_publish_results(_Ref, 0, _TimeoutMs, _Workers, Acc) ->
    finish_publish_results(lists:reverse(Acc));
collect_publish_results(Ref, Remaining, TimeoutMs, Workers, Acc) ->
    receive
        {Ref, RelayUrl, Result} ->
            collect_publish_results(Ref, Remaining - 1, TimeoutMs, Workers, [
                {RelayUrl, Result} | Acc
            ])
    after TimeoutMs ->
        lists:foreach(fun kill_worker/1, Workers),
        finish_publish_results(lists:reverse([{timeout, publish_collect_timeout} | Acc]))
    end.

finish_publish_results(Results) ->
    Accepted = [{Relay, Map} || {Relay, {ok, Map}} <- Results],
    case Accepted of
        [] ->
            {error, #{error => all_relays_failed, results => compact_results(Results)}};
        _ ->
            {ok, #{accepted => length(Accepted), results => compact_results(Results)}}
    end.

direct_publish_event(Event, Relay, TimeoutMs) ->
    RelayUrl = relay_url(Relay),
    case
        damage_nostr:open_relay_ws(Relay, #{
            connect_timeout => min_int(connect_timeout_ms(), TimeoutMs)
        })
    of
        {ok, ConnPid, StreamRef} ->
            try
                Msg = jsx:encode([<<"EVENT">>, Event]),
                case safe_ws_send(ConnPid, StreamRef, Msg) of
                    ok ->
                        await_publish_ok(ConnPid, StreamRef, event_id(Event), RelayUrl, TimeoutMs);
                    {error, FirstReason} ->
                        %% Some open_ws paths return before websocket upgrade; others
                        %% consume the upgrade confirmation before returning.  Try
                        %% immediate send first, then fall back to waiting for upgrade.
                        case
                            await_ws_upgrade(
                                ConnPid,
                                StreamRef,
                                RelayUrl,
                                min_int(connect_timeout_ms(), TimeoutMs)
                            )
                        of
                            ok ->
                                case safe_ws_send(ConnPid, StreamRef, Msg) of
                                    ok ->
                                        await_publish_ok(
                                            ConnPid, StreamRef, event_id(Event), RelayUrl, TimeoutMs
                                        );
                                    {error, Reason} ->
                                        {error, {publish_send_failed, RelayUrl, Reason}}
                                end;
                            {error, Reason} ->
                                {error,
                                    {publish_websocket_upgrade_failed, RelayUrl, #{
                                        first_send => compact_error(FirstReason),
                                        upgrade => compact_error(Reason)
                                    }}}
                        end
                end
            after
                safe_close_gun(ConnPid)
            end;
        {error, Reason} ->
            {error, {open_relay_failed, RelayUrl, Reason}}
    end.

await_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case safe_decode(Msg) of
                [<<"OK">>, EventId, true, Message] when
                    EventId =:= ExpectedId; ExpectedId =:= <<>>
                ->
                    {ok, #{relay => RelayUrl, event_id => EventId, message => Message}};
                [<<"OK">>, EventId, false, Message] when
                    EventId =:= ExpectedId; ExpectedId =:= <<>>
                ->
                    {error, {relay_rejected_event, RelayUrl, EventId, Message}};
                [<<"NOTICE">>, Notice] ->
                    ?LOG_WARNING("nsecbunker publish relay notice relay=~p notice=~p", [
                        RelayUrl, Notice
                    ]),
                    await_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs);
                Other ->
                    ?LOG_DEBUG("nsecbunker publish ignored frame relay=~p shape=~p", [
                        RelayUrl, term_shape(Other)
                    ]),
                    await_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs)
            end;
        {gun_down, ConnPid, Protocol, Reason, KilledStreams} ->
            {error, {gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams)}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams, UnprocessedStreams} ->
            {error,
                {gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams),
                    safe_len(UnprocessedStreams)}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {gun_error, RelayUrl, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {gun_error, RelayUrl, Reason}}
    after TimeoutMs ->
        {error, {publish_timeout, RelayUrl, ExpectedId}}
    end.

%%====================================================================
%% Config / relay helpers
%%====================================================================

configured_relays() ->
    Config = damage_nsecbunker:config(),
    Relays0 = maps:get(relays, Config, []),
    case Relays0 of
        [] -> damage_nostr:score_relays(damage_nostr:default_relays());
        _ -> normalize_relays(Relays0)
    end.

normalize_relays(Relays0) ->
    damage_nostr:score_relays(damage_nostr:normalize_relays(Relays0)).

normalize_filter(Filter) when is_map(Filter) ->
    maps:from_list([{filter_key(K), normalize_filter_value(V)} || {K, V} <- maps:to_list(Filter)]).

filter_key(kinds) -> <<"kinds">>;
filter_key(authors) -> <<"authors">>;
filter_key(ids) -> <<"ids">>;
filter_key(since) -> <<"since">>;
filter_key(until) -> <<"until">>;
filter_key(limit) -> <<"limit">>;
filter_key(K) when is_binary(K) -> K;
filter_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
filter_key(K) when is_list(K) -> unicode:characters_to_binary(K);
filter_key(K) -> unicode:characters_to_binary(io_lib:format("~p", [K])).

normalize_filter_value(V) when is_map(V) -> normalize_filter(V);
normalize_filter_value(V) when is_list(V) -> [normalize_filter_value(I) || I <- V];
normalize_filter_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
normalize_filter_value(V) -> V.

normalize_event(Event) when is_map(Event) ->
    damage_nostr_event:normalize_event(Event).

relay_url(#{url := Url}) -> bin(Url);
relay_url(#{<<"url">> := Url}) -> bin(Url);
relay_url(Url) -> bin(Url).

find_relay(_RelayUrl, []) ->
    undefined;
find_relay(RelayUrl, [Relay | Rest]) ->
    case relay_url(Relay) =:= RelayUrl of
        true -> Relay;
        false -> find_relay(RelayUrl, Rest)
    end.

connect_timeout_ms() ->
    config_int(relay_connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT_MS).

publish_timeout_ms() ->
    config_int(relay_publish_timeout_ms, ?DEFAULT_PUBLISH_TIMEOUT_MS).

config_int(Key, Default) ->
    Config = damage_nsecbunker:config(),
    case maps:get(Key, Config, Default) of
        I when is_integer(I), I > 0 -> I;
        B when is_binary(B) ->
            try binary_to_integer(B) of
                I when I > 0 -> I;
                _ -> Default
            catch
                _:_ -> Default
            end;
        L when is_list(L) ->
            try list_to_integer(L) of
                I when I > 0 -> I;
                _ -> Default
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%%====================================================================
%% Small helpers
%%====================================================================

safe_ws_send(ConnPid, StreamRef, Msg) ->
    try gun:ws_send(ConnPid, StreamRef, {text, Msg}) of
        ok -> ok;
        Other -> {error, Other}
    catch
        C:R -> {error, {C, R}}
    end.

safe_decode(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        Frame -> Frame
    catch
        C:R -> {decode_failed, C, R, byte_size(bin(Msg))}
    end.

event_id(Event) when is_map(Event) ->
    case field([<<"id">>, id], Event, <<>>) of
        <<>> ->
            try damage_nostr_event:id(Event) of
                Id -> bin(Id)
            catch
                _:_ -> <<>>
            end;
        Id ->
            bin(Id)
    end.

field([], _Map, Default) ->
    Default;
field([K | Rest], Map, Default) ->
    case maps:get(K, Map, undefined) of
        undefined -> field(Rest, Map, Default);
        V -> V
    end.

seen(<<>>, _St) -> false;
seen(EventId, #st{seen_ids = Seen}) -> maps:is_key(EventId, Seen).

mark_seen(<<>>, St) ->
    St;
mark_seen(EventId, St0 = #st{seen_ids = Seen0}) ->
    Seen1 = Seen0#{EventId => erlang:system_time(second)},
    Seen =
        case map_size(Seen1) > ?MAX_SEEN_IDS of
            true -> maps:from_list(lists:sublist(maps:to_list(Seen1), ?MAX_SEEN_IDS div 2));
            false -> Seen1
        end,
    St0#st{seen_ids = Seen}.

record_inbound_event(<<>>, St) ->
    St;
record_inbound_event(EventId, St0 = #st{recent_inbound_event_ids = Recent0}) ->
    Recent1 = [EventId | [Id || Id <- Recent0, Id =/= EventId]],
    St0#st{recent_inbound_event_ids = take_recent(50, Recent1)}.

take_recent(_Max, []) ->
    [];
take_recent(Max, List) when is_integer(Max), Max > 0 ->
    lists:sublist(List, Max).

close_all(Conns) ->
    maps:foreach(
        fun(ConnPid, #{sub_id := SubId, stream_ref := StreamRef}) ->
            safe_close_subscription(ConnPid, StreamRef, SubId)
        end,
        Conns
    ),
    ok.

kill_worker(Pid) when is_pid(Pid) ->
    try exit(Pid, kill) of
        _ -> ok
    catch
        _:_ -> ok
    end;
kill_worker(_) ->
    ok.

safe_close_subscription(ConnPid, StreamRef, SubId) ->
    try gun:ws_send(ConnPid, StreamRef, {text, jsx:encode([<<"CLOSE">>, SubId])}) of
        _ -> ok
    catch
        _:_ -> ok
    end,
    safe_close_gun(ConnPid).

safe_close_gun(ConnPid) when is_pid(ConnPid) ->
    try gun:close(ConnPid) of
        _ -> ok
    catch
        _:_ -> ok
    end;
safe_close_gun(_) ->
    ok.

subscribed_count(Conns) ->
    maps:fold(
        fun(_Pid, Conn, Acc) ->
            case maps:get(subscribed, Conn, false) of
                true -> Acc + 1;
                _ -> Acc
            end
        end,
        0,
        Conns
    ).

connection_status(Conns) ->
    maps:fold(
        fun(_ConnPid, Conn, Acc) ->
            RelayUrl = maps:get(relay_url, Conn, <<>>),
            Acc#{RelayUrl => maps:without([relay, stream_ref], Conn)}
        end,
        #{},
        Conns
    ).

empty_stats() ->
    #{
        inbound_events => 0,
        dispatched_events => 0,
        eose_frames => 0,
        notice_frames => 0,
        connection_downs => 0,
        publish_ok => 0,
        publish_error => 0
    }.

inc_stat(Key, St0 = #st{stats = Stats0}) ->
    Stats = Stats0#{Key => maps:get(Key, Stats0, 0) + 1},
    St0#st{stats = Stats}.

bump_publish_stats({ok, _}, St) -> inc_stat(publish_ok, St);
bump_publish_stats({error, _}, St) -> inc_stat(publish_error, St);
bump_publish_stats(_, St) -> St.

make_sub_id() ->
    <<"nsecbunker_nip46_", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

compact_results(Results) ->
    [{Relay, compact_error(Result)} || {Relay, Result} <- Results].

compact_error({ok, M}) ->
    {ok, compact_error(M)};
compact_error({error, Reason}) ->
    {error, compact_error(Reason)};
compact_error(M) when is_map(M) ->
    case map_size(M) =< 8 of
        true -> maps:map(fun(_K, V) -> compact_error(V) end, M);
        false -> #{type => map, size => map_size(M), keys => maps:keys(M)}
    end;
compact_error(L) when is_list(L) ->
    case length(L) =< 8 of
        true -> [compact_error(V) || V <- L];
        false -> #{type => list, length => length(L)}
    end;
compact_error(T) when is_tuple(T) ->
    case tuple_size(T) =< 8 of
        true -> list_to_tuple([compact_error(V) || V <- tuple_to_list(T)]);
        false -> #{type => tuple, size => tuple_size(T), tag => element(1, T)}
    end;
compact_error(B) when is_binary(B), byte_size(B) > 128 ->
    #{type => binary, bytes => byte_size(B)};
compact_error(Other) ->
    Other.

safe_len(L) when is_list(L) -> length(L);
safe_len(_) -> 0.

stack_top([{M, F, A, _} | _]) -> {M, F, A};
stack_top(_) -> undefined.

term_shape(Term) when is_tuple(Term) ->
    #{type => tuple, size => tuple_size(Term), tag => element(1, Term)};
term_shape(Term) when is_map(Term) ->
    #{type => map, size => map_size(Term), keys => maps:keys(Term)};
term_shape(Term) when is_list(Term) -> #{type => list, length => length(Term)};
term_shape(Term) when is_binary(Term) -> #{type => binary, bytes => byte_size(Term)};
term_shape(Term) ->
    Term.

min_int(A, B) when A =< B -> A;
min_int(_A, B) -> B.

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
