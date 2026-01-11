%% steps_nostr_monitor.erl
-module(steps_nostr_monitor).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% DamageBDD step entry
-export([step/6]).

%% gen_server API
-export([start_link/1, stop/1, pop_event/2, stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_EVENTS, 200).

-record(st, {
    relay          :: binary(),
    pubhex         :: binary(),
    conn_pid       :: pid() | undefined,
    stream_ref     :: term() | undefined,
    sub_id         :: binary(),
    max_events     :: pos_integer(),
    events         :: [map()],     %% newest first
    waiters        :: [pid()],     %% processes waiting for next event
    connected      :: boolean()
}).

%% -------------------------------------------------------------------
%% DamageBDD Steps
%% -------------------------------------------------------------------
%%
%% Start:
%%   Given I start a nostr monitor for "npub1..." on relay "wss://nos.lol"
%%   Given I start a nostr monitor for "npub1..." on relay "wss://nos.lol" as "nostr_mon"
%%
%% Stop:
%%   Given I stop the nostr monitor
%%   Given I stop the nostr monitor "nostr_mon"
%%
%% Wait/consume:
%%   Then I wait for the next nostr note and store event as "note_event"
%%   Then I wait for the next nostr note from monitor "nostr_mon" and store event as "note_event"
%%
%% Helpers:
%%   Then I store the nostr event content from "note_event" in "note_content"
%%
step(_Config, Context, _Kw, _Line,
     ["I start a nostr monitor for", Npub0, "on relay", Relay0],
     Body) ->
    step(_Config, Context, _Kw, _Line,
         ["I start a nostr monitor for", Npub0, "on relay", Relay0, "as", <<"nostr_mon">>],
         Body);

step(_Config, Context, _Kw, _Line,
     ["I start a nostr monitor for", Npub0, "on relay", Relay0, "as", MonVar],
     Body) ->
    case ensure_not_running(Context, MonVar) of
        ok ->
            Relay = maybe_bin(Relay0),
            Npub  = maybe_bin(Npub0),
            PubHex = normalize_pub_hex(Npub),

            case PubHex of
                <<>> ->
                    maps:put(fail, <<"invalid npub/pubkey">>, Context);
                _ ->
                    MaxEvents = pick_max_events(Body, Context),
                    Args = #{
                        relay => Relay,
                        pubhex => PubHex,
                        max_events => MaxEvents
                    },
                    case start_link(Args) of
                        {ok, Pid} ->
                            %% Store pid + metadata for later steps
                            MonInfo = #{
                                pid => Pid,
                                relay => Relay,
                                pubhex => PubHex,
                                max_events => MaxEvents
                            },
                            maps:put(MonVar, MonInfo, Context);
                        {error, Reason} ->
                            maps:put(fail, to_bin(Reason), Context)
                    end
            end;
        {error, Why} ->
            maps:put(fail, Why, Context)
    end;

step(_Config, Context, _Kw, _Line,
     ["I stop the nostr monitor"],
     _Body) ->
    step(_Config, Context, _Kw, _Line,
         ["I stop the nostr monitor", <<"nostr_mon">>],
         _Body);

step(_Config, Context, _Kw, _Line,
     ["I stop the nostr monitor", MonVar],
     _Body) ->
    case get_mon_pid(Context, MonVar) of
        {ok, Pid} ->
            _ = stop(Pid),
            %% remove monitor entry
            maps:remove(MonVar, Context);
        {error, Why} ->
            maps:put(fail, Why, Context)
    end;

step(_Config, Context, _Kw, _Line,
     ["I wait for the next nostr note and store event as", OutVar],
     Body) ->
    step(_Config, Context, _Kw, _Line,
         ["I wait for the next nostr note from monitor", <<"nostr_mon">>, "and store event as", OutVar],
         Body);

step(_Config, Context, _Kw, _Line,
     ["I wait for the next nostr note from monitor", MonVar, "and store event as", OutVar],
     Body) ->
    TimeoutMs = pick_timeout_ms(Body, Context),
    case get_mon_pid(Context, MonVar) of
        {ok, Pid} ->
            case pop_event(Pid, TimeoutMs) of
                {ok, Event} ->
                    C1 = maps:put(OutVar, Event, Context),
                    append_monitored(Event, C1);
                {error, Reason} ->
                    maps:put(fail, Reason, Context)
            end;
        {error, Why} ->
            maps:put(fail, Why, Context)
    end;

step(_Config, Context, _Kw, _Line,
     ["I store the nostr event content from", EventVar, "in", OutVar],
     _Body) ->
    case maps:get(EventVar, Context, undefined) of
        #{<<"content">> := Content} ->
            maps:put(OutVar, Content, Context);
        #{content := Content} ->
            maps:put(OutVar, maybe_bin(Content), Context);
        _ ->
            maps:put(fail, <<"nostr event not found / missing content">>, Context)
    end.

ensure_not_running(Context, MonVar) ->
    case maps:get(MonVar, Context, undefined) of
        undefined -> ok;
        #{pid := Pid} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {error, <<"nostr monitor already running">>};
                false -> ok
            end;
        _ ->
            ok
    end.

get_mon_pid(Context, MonVar0) ->
    MonVar = maybe_bin(MonVar0),
    case maps:get(MonVar, Context, undefined) of
        #{pid := Pid} when is_pid(Pid) ->
            {ok, Pid};
        _ ->
            {error, <<"nostr monitor not found">>}
    end.

append_monitored(Event, Context) ->
    Prev = maps:get(<<"monitored_events">>, Context, maps:get(monitored_events, Context, [])),
    C1 = maps:put(monitored_events, Prev ++ [Event], Context),
    maps:put(<<"monitored_events">>, Prev ++ [Event], C1).

pick_timeout_ms(Body, Context) ->
    FromCtx =
        case maps:get(<<"nostr_timeout_ms">>, Context, maps:get(nostr_timeout_ms, Context, undefined)) of
            T when is_integer(T), T > 0 -> T;
            _ -> undefined
        end,
    case Body of
        M when is_map(M) ->
            case maps:get(<<"timeout_ms">>, M, undefined) of
                T2 when is_integer(T2), T2 > 0 -> T2;
                _ when is_integer(FromCtx) -> FromCtx;
                _ -> ?DEFAULT_TIMEOUT_MS
            end;
        _ when is_integer(FromCtx) -> FromCtx;
        _ -> ?DEFAULT_TIMEOUT_MS
    end.

pick_max_events(Body, Context) ->
    FromCtx =
        case maps:get(<<"nostr_max_events">>, Context, maps:get(nostr_max_events, Context, undefined)) of
            M when is_integer(M), M > 0 -> M;
            _ -> undefined
        end,
    case Body of
        Map when is_map(Map) ->
            case maps:get(<<"max_events">>, Map, undefined) of
                M2 when is_integer(M2), M2 > 0 -> M2;
                _ when is_integer(FromCtx) -> FromCtx;
                _ -> ?DEFAULT_MAX_EVENTS
            end;
        _ when is_integer(FromCtx) -> FromCtx;
        _ -> ?DEFAULT_MAX_EVENTS
    end.

%% -------------------------------------------------------------------
%% gen_server API
%% -------------------------------------------------------------------

start_link(Args) when is_map(Args) ->
    gen_server:start_link(?MODULE, Args, []).

stop(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, stop, 5000).

pop_event(Pid, TimeoutMs) when is_pid(Pid), is_integer(TimeoutMs), TimeoutMs > 0 ->
    gen_server:call(Pid, {pop_event, TimeoutMs}, TimeoutMs + 1000).

stats(Pid) ->
    gen_server:call(Pid, stats, 5000).

%% -------------------------------------------------------------------
%% gen_server callbacks
%% -------------------------------------------------------------------

init(#{relay := Relay0, pubhex := PubHex0, max_events := MaxEvents}) ->
    process_flag(trap_exit, true),
    Relay = ensure_scheme(maybe_bin(Relay0)),
    PubHex = lowercase_bin(maybe_bin(PubHex0)),
    SubId = make_sub_id(),
    State0 = #st{
        relay = Relay,
        pubhex = PubHex,
        conn_pid = undefined,
        stream_ref = undefined,
        sub_id = SubId,
        max_events = MaxEvents,
        events = [],
        waiters = [],
        connected = false
    },
    self() ! connect,
    {ok, State0}.

handle_call(stop, _From, St) ->
    {stop, normal, ok, St};

handle_call(stats, _From, #st{events = Ev, connected = Conn} = St) ->
    {reply, #{connected => Conn, queued_events => length(Ev)}, St};

handle_call({pop_event, TimeoutMs}, From, #st{events = [E | Rest]} = St) ->
    {reply, {ok, E}, St#st{events = Rest}};
handle_call({pop_event, _TimeoutMs}, From, #st{events = []} = St) ->
    %% No events yet: park caller; we will reply when first event arrives
    Pid = element(1, From),
    erlang:monitor(process, Pid),
    {noreply, St#st{waiters = [From | St#st.waiters]}}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(connect, St0) ->
    case do_connect(St0) of
        {ok, St1} ->
            {noreply, St1};
        {error, Why, St1} ->
            ?LOG_WARNING("nostr monitor connect failed ~p; retrying", [Why]),
            erlang:send_after(2000, self(), connect),
            {noreply, St1}
    end;

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers},
            #st{conn_pid = ConnPid, stream_ref = StreamRef} = St0) ->
    %% Subscribe on successful upgrade
    Filter = #{
        <<"kinds">> => [1],
        <<"authors">> => [St0#st.pubhex]
    },
    Req = jsx:encode([<<"REQ">>, St0#st.sub_id, Filter]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, Req}),
    {noreply, St0#st{connected = true}};

handle_info({gun_ws, ConnPid, StreamRef, {text, MsgBin}},
            #st{conn_pid = ConnPid, stream_ref = StreamRef} = St0) ->
    %% Process incoming frames forever
    case safe_decode(MsgBin) of
        [<<"EVENT">>, SubId, EventMap] when SubId =:= St0#st.sub_id ->
            Ev = normalize_event(EventMap),
            {noreply, enqueue_event(Ev, St0)};
        [<<"NOTICE">>, _Notice] ->
            {noreply, St0};
        [<<"EOSE">>, _SubId] ->
            {noreply, St0};
        _Other ->
            {noreply, St0}
    end;

handle_info({gun_down, ConnPid, _Proto, _Reason, _Killed, _Unprocessed},
            #st{conn_pid = ConnPid} = St0) ->
    %% Relay went away — reconnect
    ?LOG_WARNING("nostr monitor disconnected; reconnecting", []),
    erlang:send_after(1000, self(), connect),
    {noreply, St0#st{conn_pid = undefined, stream_ref = undefined, connected = false}};

handle_info({'DOWN', _MRef, process, _Pid, _Reason}, St0) ->
    %% A waiter died; prune waiters in a cheap way by filtering later
    {noreply, St0};

handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, #st{conn_pid = ConnPid, stream_ref = StreamRef, sub_id = SubId}) ->
    %% Best-effort CLOSE + close connection
    catch begin
        case {ConnPid, StreamRef} of
            {P, S} when is_pid(P) ->
                _ = gun:ws_send(P, S, {text, jsx:encode([<<"CLOSE">>, SubId])}),
                gun:close(P);
            _ -> ok
        end
    end,
    ok.

%% -------------------------------------------------------------------
%% Internal connection + queue management
%% -------------------------------------------------------------------

do_connect(#st{relay = Relay} = St0) ->
    {Host, Port, Path, Tls} = parse_relay(Relay),
    Opts =
        case Tls of
            true -> #{transport => tls, tls_opts => [{verify, verify_peer}]};
            false -> #{transport => tcp}
        end,
    case gun:open(binary_to_list(Host), Port, Opts) of
        {ok, ConnPid} ->
            StreamRef = gun:ws_upgrade(ConnPid, binary_to_list(Path)),
            {ok, St0#st{conn_pid = ConnPid, stream_ref = StreamRef, connected = false}};
        {error, Why} ->
            {error, Why, St0}
    end.

enqueue_event(Ev, #st{events = Ev0, max_events = Max, waiters = Waiters} = St0) ->
    %% If a waiter exists, reply immediately instead of queueing
    case take_alive_waiter(Waiters) of
        {none, Waiters2} ->
            Ev1 = [Ev | Ev0],
            Ev2 = trim(Max, Ev1),
            St0#st{events = Ev2, waiters = Waiters2};
        {{some, From}, Waiters2} ->
            gen_server:reply(From, {ok, Ev}),
            St0#st{waiters = Waiters2}
    end.

take_alive_waiter([]) -> {none, []};
take_alive_waiter([From | Rest]) ->
    Pid = element(1, From),
    case is_process_alive(Pid) of
        true -> {{some, From}, Rest};
        false ->
            {W, Rest2} = take_alive_waiter(Rest),
            {W, Rest2}
    end.

trim(Max, List) ->
    %% keep newest Max events (list is newest-first)
    case length(List) > Max of
        true -> lists:sublist(List, Max);
        false -> List
    end.

%% -------------------------------------------------------------------
%% Encoding / parsing helpers
%% -------------------------------------------------------------------

normalize_pub_hex(NpubOrHex) ->
    try
        Hex0 = damage_nostr:decode_npub(NpubOrHex),
        lowercase_bin(maybe_bin(Hex0))
    catch
        _:_ ->
            lowercase_bin(maybe_bin(NpubOrHex))
    end.

safe_decode(Bin) ->
    try jsx:decode(Bin) of
        Val -> Val
    catch
        _:_ ->
            try jsx:decode(Bin, [{labels, atom}]) of
                Val2 -> Val2
            catch
                _:_ -> []
            end
    end.

normalize_event(Ev) when is_map(Ev) ->
    case Ev of
        #{<<"id">> := _} ->
            Ev#{<<"sig">> => maps:get(<<"sig">>, Ev, <<>>)};
        #{id := _Id} ->
            #{
                <<"id">> => to_bin(maps:get(id, Ev, <<>>)),
                <<"pubkey">> => to_bin(maps:get(pubkey, Ev, <<>>)),
                <<"created_at">> => maps:get(created_at, Ev, 0),
                <<"kind">> => maps:get(kind, Ev, 0),
                <<"tags">> => maps:get(tags, Ev, []),
                <<"content">> => to_bin(maps:get(content, Ev, <<>>)),
                <<"sig">> => to_bin(maps:get(sig, Ev, <<>>))
            };
        _ ->
            Ev
    end.

make_sub_id() ->
    I = erlang:unique_integer([positive, monotonic]),
    list_to_binary("sub_" ++ integer_to_list(I)).

ensure_scheme(Relay) when is_binary(Relay) ->
    case Relay of
        <<"ws://", _/binary>> -> Relay;
        <<"wss://", _/binary>> -> Relay;
        _ -> <<"wss://", Relay/binary>>
    end.

parse_relay(Relay0) ->
    Relay = ensure_scheme(Relay0),
    M = uri_string:parse(binary_to_list(Relay)),
    Host = list_to_binary(maps:get(host, M, "")),
    Scheme = maps:get(scheme, M, "wss"),
    Port =
        case maps:get(port, M, undefined) of
            undefined ->
                case Scheme of
                    "ws" -> 80;
                    _ -> 443
                end;
            P -> P
        end,
    Path0 = maps:get(path, M, "/"),
    Path = list_to_binary(if Path0 =:= "" -> "/"; true -> Path0 end),
    Tls = (Scheme =:= "wss"),
    {Host, Port, Path, Tls}.

maybe_bin(B) when is_binary(B) -> B;
maybe_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
maybe_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
maybe_bin(I) when is_integer(I) -> integer_to_binary(I);
maybe_bin(Other) -> to_bin(Other).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

lowercase_bin(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(Bin))).
