%%%-------------------------------------------------------------------
%%% damage_nwc_ledger_events.erl
%%%
%%% Read NWC ledger state from public Aeternity Middleware contract logs.
%%% No dry-runs, no user private key, no read-only contract calls in the
%%% NIP-47 hot path.
%%%-------------------------------------------------------------------
-module(damage_nwc_ledger_events).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    ledger_events/2,
    ledger_events/3,
    client_events/3,
    client_balance_msat/2,
    client_transactions/4,
    client_policy/2,
    sessions/2
]).

-define(PAGE_LIMIT, 100).
-define(MAX_PAGES, 12).
-define(HTTP_TIMEOUT, 30000).

%% -------------------------------------------------------------------
%% Public middleware log reader
%% -------------------------------------------------------------------

ledger_events(LedgerCt, Limit) ->
    ledger_events(LedgerCt, Limit, backward).

ledger_events(LedgerCt0, Limit0, Direction0) ->
    LedgerCt = to_s(LedgerCt0),
    Limit = clamp_int(Limit0, 1, ?PAGE_LIMIT * ?MAX_PAGES),
    Direction = direction(Direction0),
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            PageLimit = erlang:min(?PAGE_LIMIT, Limit),
            Query = uri_string:compose_query([
                {"direction", Direction},
                {"contract_id", LedgerCt},
                {"limit", integer_to_list(PageLimit)}
            ]),
            Path = PathPrefix ++ "v3/contracts/logs?" ++ Query,
            Res = fetch_pages(ConnPid, PathPrefix, Path, Limit, ?MAX_PAGES, []),
            catch gun:close(ConnPid),
            Res;
        Error ->
            Error
    end.

fetch_pages(_ConnPid, _PathPrefix, _Path, Need, _PagesLeft, Acc) when length(Acc) >= Need ->
    {ok, lists:sublist(Acc, Need)};
fetch_pages(_ConnPid, _PathPrefix, undefined, _Need, _PagesLeft, Acc) ->
    {ok, Acc};
fetch_pages(_ConnPid, _PathPrefix, _Path, _Need, 0, Acc) ->
    {ok, Acc};
fetch_pages(ConnPid, PathPrefix, Path, Need, PagesLeft, Acc) ->
    ?LOG_DEBUG("NWC ledger events public API path ~p", [Path]),
    StreamRef = gun:get(ConnPid, Path),
    case await_json(ConnPid, StreamRef, ?HTTP_TIMEOUT) of
        #{data := Data0} = Page when is_list(Data0) ->
            Data = Acc ++ Data0,
            Next = next_path(PathPrefix, map_get_any([next, <<"next">>], Page, undefined)),
            fetch_pages(ConnPid, PathPrefix, Next, Need, PagesLeft - 1, Data);
        #{<<"data">> := Data0} = Page when is_list(Data0) ->
            Data = Acc ++ Data0,
            Next = next_path(PathPrefix, map_get_any([next, <<"next">>], Page, undefined)),
            fetch_pages(ConnPid, PathPrefix, Next, Need, PagesLeft - 1, Data);
        #{data := null} ->
            {ok, Acc};
        #{<<"data">> := null} ->
            {ok, Acc};
        {error, _} = Error ->
            Error;
        Other ->
            {error, {bad_ledger_events_response, Other}}
    end.

await_json(ConnPid, StreamRef, Timeout) ->
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            jsx:decode(Body, [{labels, atom}, return_maps]);
        {response, nofin, Status, _Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            {error, {http_status, Status, Body}};
        {response, fin, Status, _Headers} when Status >= 200, Status < 300 ->
            #{data => []};
        Other ->
            {error, Other}
    end.

next_path(_PathPrefix, undefined) ->
    undefined;
next_path(_PathPrefix, null) ->
    undefined;
next_path(PathPrefix, Next0) ->
    Next = to_s(Next0),
    case Next of
        "" ->
            undefined;
        [$h, $t, $t, $p | _] ->
            case uri_string:parse(Next) of
                #{path := Path, query := Query} -> Path ++ "?" ++ Query;
                #{path := Path} -> Path;
                _ -> undefined
            end;
        [$/ | _] ->
            Next;
        _ ->
            PathPrefix ++ string:trim(Next, leading, "/")
    end.

%% -------------------------------------------------------------------
%% Client-scoped replay
%% -------------------------------------------------------------------

client_events(LedgerCt, ClientPubHex0, RawLimit0) ->
    ClientPubHex = hex64(ClientPubHex0),
    ExpectedHash = client_pubkey_hash_hex(ClientPubHex),
    RawLimit = clamp_int(RawLimit0, 1, ?PAGE_LIMIT * ?MAX_PAGES),
    case ledger_events(LedgerCt, RawLimit, backward) of
        {ok, RawEvents} ->
            Events = [
                E
             || Raw <- RawEvents,
                {ok, E} <- [decode_event(Raw)],
                maps:get(client_pubkey_hash, E, <<>>) =:= ExpectedHash
            ],
            ?LOG_DEBUG(
                "NWC ledger public replay ledger=~p client=~p fetched=~p matched=~p",
                [LedgerCt, short_key(ClientPubHex), length(RawEvents), length(Events)]
            ),
            {ok, Events};
        Error ->
            Error
    end.

client_balance_msat(LedgerCt, ClientPubHex) ->
    case client_events(LedgerCt, ClientPubHex, 1000) of
        {ok, Events} ->
            case first_balance_after(Events) of
                {ok, Balance} -> {ok, Balance};
                not_found -> {ok, replay_balance(lists:reverse(Events))}
            end;
        Error ->
            Error
    end.

client_transactions(LedgerCt, ClientPubHex, Limit0, Offset0) ->
    Limit = clamp_int(Limit0, 1, 100),
    Offset = clamp_int(Offset0, 0, 1000000),
    RawLimit = clamp_int(Limit + Offset + 200, 100, ?PAGE_LIMIT * ?MAX_PAGES),
    case client_events(LedgerCt, ClientPubHex, RawLimit) of
        {ok, Events0} ->
            Events = [
                E
             || #{kind := Kind} = E <- Events0,
                Kind =:= <<"credit">> orelse Kind =:= <<"debit">>
            ],
            {ok, take(Limit, drop(Offset, Events))};
        Error ->
            Error
    end.

client_policy(LedgerCt, ClientPubHex0) ->
    ClientPubHex = hex64(ClientPubHex0),
    Base = session_index_policy(ClientPubHex),
    case client_events(LedgerCt, ClientPubHex, 1000) of
        {ok, Events} ->
            Chronological = lists:reverse(Events),
            Policy0 = lists:foldl(fun apply_policy_event/2, Base, Chronological),
            Spent = lists:sum([
                maps:get(amount_msat, E, 0)
             || E <- Events,
                maps:get(kind, E, undefined) =:= <<"debit">>
            ]),
            {ok, maps:put(spent_msat, Spent, Policy0)};
        Error ->
            Error
    end.

sessions(LedgerCt, Limit0) ->
    Limit = clamp_int(Limit0, 1, ?PAGE_LIMIT * ?MAX_PAGES),
    case ledger_events(LedgerCt, Limit, backward) of
        {ok, RawEvents} ->
            Events = [E || Raw <- RawEvents, {ok, E} <- [decode_event(Raw)]],
            {ok, finalize_sessions(fold_sessions(lists:reverse(Events), #{}))};
        Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% Event decoding
%% -------------------------------------------------------------------

decode_event(Raw0) when is_map(Raw0) ->
    Raw = normalize_json(Raw0),
    case ledger_event_args(Raw) of
        [Hash0, Kind0, Payload0 | _] ->
            Kind = int_value(arg_value(Kind0), -1),
            ClientHash = normalize_hash(arg_value(Hash0)),
            Payload = decode_payload(arg_value(Payload0)),
            PayloadMap = decode_payload_parts(Kind, Payload),
            case ClientHash of
                <<>> ->
                    not_found;
                _ ->
                    {ok,
                        maps:merge(
                            #{
                                client_pubkey_hash => ClientHash,
                                kind => normalize_kind(Kind),
                                event_kind => Kind,
                                type => event_type(Kind),
                                tx_hash => to_bin(
                                    map_get_any(
                                        [tx_hash, hash, <<"tx_hash">>, <<"hash">>], Raw, <<>>
                                    )
                                ),
                                height => event_height(Raw),
                                block_time => event_time(Raw),
                                raw => Raw
                            },
                            PayloadMap
                        )}
            end;
        _ ->
            not_found
    end;
decode_event(_) ->
    not_found.

ledger_event_args(Raw) ->
    Direct = first_defined([
        map_get_any(
            [args, <<"args">>, arguments, <<"arguments">>, decoded_args, <<"decoded_args">>],
            Raw,
            undefined
        ),
        map_get_path(Raw, [payload, args]),
        map_get_path(Raw, [<<"payload">>, <<"args">>]),
        map_get_path(Raw, [payload, arguments]),
        map_get_path(Raw, [<<"payload">>, <<"arguments">>])
    ]),
    case Direct of
        Args when is_list(Args), length(Args) >= 3 ->
            Args;
        _ ->
            topics_data_args(Raw)
    end.

topics_data_args(Raw) ->
    Topics = first_defined([
        map_get_any([topics, <<"topics">>], Raw, undefined),
        map_get_path(Raw, [payload, topics]),
        map_get_path(Raw, [<<"payload">>, <<"topics">>])
    ]),
    Data = first_defined([
        map_get_any([data, <<"data">>, payload, <<"payload">>], Raw, undefined),
        map_get_path(Raw, [payload, data]),
        map_get_path(Raw, [<<"payload">>, <<"data">>])
    ]),
    case {Topics, Data} of
        {[_, Hash, Kind | _], D} when D =/= undefined -> [Hash, Kind, D];
        {[Hash, Kind | _], D} when D =/= undefined -> [Hash, Kind, D];
        _ -> []
    end.

arg_value(#{<<"value">> := V}) -> V;
arg_value(#{value := V}) -> V;
arg_value({_Type, V}) -> V;
arg_value(V) -> V.

normalize_hash(H0) ->
    H = decode_hash(H0),
    case H of
        B when is_binary(B), byte_size(B) =:= 32 -> lower_hex(B);
        B when is_binary(B) -> lower_ascii(B);
        L when is_list(L) -> normalize_hash(unicode:characters_to_binary(L));
        _ -> to_bin(H)
    end.

decode_hash(B) when is_binary(B) ->
    case B of
        <<"ba_", _/binary>> -> maybe_decode_encoded(B);
        <<"cb_", _/binary>> -> maybe_decode_encoded(B);
        <<"h_", _/binary>> -> maybe_decode_encoded(B);
        _ -> B
    end;
decode_hash(V) ->
    V.

decode_payload(Payload) when is_binary(Payload) ->
    case Payload of
        <<"ba_", _/binary>> -> maybe_decode_encoded(Payload);
        <<"cb_", _/binary>> -> maybe_decode_encoded(Payload);
        _ -> Payload
    end;
decode_payload(Payload) when is_list(Payload) ->
    decode_payload(unicode:characters_to_binary(Payload));
decode_payload(Payload) ->
    to_bin(Payload).

maybe_decode_encoded(Encoded) ->
    maybe_decode_encoded(Encoded, [bytearray, contract_bytearray, hash]).

maybe_decode_encoded(Encoded, [Type | Rest]) ->
    case catch aeser_api_encoder:decode(Type, Encoded) of
        {Type, Bin} when is_binary(Bin) -> Bin;
        {_OtherType, Bin} when is_binary(Bin) -> Bin;
        Bin when is_binary(Bin) -> Bin;
        _ -> maybe_decode_encoded(Encoded, Rest)
    end;
maybe_decode_encoded(Encoded, []) ->
    Encoded.

decode_payload_parts(Kind, Payload) ->
    Parts = binary:split(Payload, <<"|">>, [global]),
    decode_payload_parts0(Kind, Parts).

decode_payload_parts0(Kind, [Amount0, Ref0, MetaHash0, Height0, BalanceAfter0 | _]) when
    Kind =:= 0; Kind =:= 1
->
    Amount = int_value(Amount0, 0),
    #{
        amount_msat => Amount,
        delta_msat =>
            case Kind of
                0 -> Amount;
                1 -> -Amount
            end,
        ref => to_bin(Ref0),
        meta_sha256 => normalize_meta_hash(MetaHash0),
        height => int_value(Height0, 0),
        balance_after => int_value(BalanceAfter0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0)
    };
decode_payload_parts0(Kind, [MaxSingle0, MaxTotal0, ExpiresHeight0, Height0, BalanceAfter0 | _]) when
    Kind =:= 2; Kind =:= 4
->
    #{
        max_single_msat => int_value(MaxSingle0, 0),
        max_total_msat => int_value(MaxTotal0, 0),
        expires_height => int_value(ExpiresHeight0, 0),
        height => int_value(Height0, 0),
        balance_after => int_value(BalanceAfter0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0)
    };
decode_payload_parts0(3, [_MaxSingle0, _MaxTotal0, _ExpiresHeight0, Height0, BalanceAfter0 | _]) ->
    #{
        height => int_value(Height0, 0),
        balance_after => int_value(BalanceAfter0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0),
        revoked => true
    };
decode_payload_parts0(_Kind, _Parts) ->
    #{}.

normalize_kind(0) -> <<"credit">>;
normalize_kind(1) -> <<"debit">>;
normalize_kind(2) -> <<"register">>;
normalize_kind(3) -> <<"revoke">>;
normalize_kind(4) -> <<"set_limits">>;
normalize_kind(_) -> <<"event">>.

event_type(0) -> <<"credit">>;
event_type(1) -> <<"debit">>;
event_type(2) -> <<"minted">>;
event_type(3) -> <<"revoked">>;
event_type(4) -> <<"limits_updated">>;
event_type(_) -> <<"event">>.

first_balance_after([#{balance_after_msat := Balance} | _]) when is_integer(Balance) ->
    {ok, Balance};
first_balance_after([#{balance_after := Balance} | _]) when is_integer(Balance) ->
    {ok, Balance};
first_balance_after([_ | Rest]) ->
    first_balance_after(Rest);
first_balance_after([]) ->
    not_found.

replay_balance(Events) ->
    lists:foldl(
        fun
            (#{kind := <<"credit">>, amount_msat := Amount}, Acc) -> Acc + Amount;
            (#{kind := <<"debit">>, amount_msat := Amount}, Acc) -> Acc - Amount;
            (_, Acc) -> Acc
        end,
        0,
        Events
    ).

session_index_policy(ClientPubHex) ->
    Default = #{
        revoked => false,
        max_single_msat => 0,
        max_total_msat => 0,
        expires_height => 0,
        spent_msat => 0
    },
    case catch damage_nwc_session_index:get(ClientPubHex) of
        {ok, #{meta := Meta0}} when is_map(Meta0) ->
            Meta = normalize_json(Meta0),
            Policy0 = map_get_any([policy, <<"policy">>], Meta, #{}),
            Policy =
                case Policy0 of
                    P when is_map(P) -> normalize_json(P);
                    _ -> #{}
                end,
            maps:merge(Default, #{
                revoked => bool_value(
                    map_get_any([revoked, <<"revoked">>], maps:merge(Meta, Policy), false), false
                ),
                max_single_msat => int_value(
                    map_get_any(
                        [max_single_msat, <<"max_single_msat">>], maps:merge(Meta, Policy), 0
                    ),
                    0
                ),
                max_total_msat => int_value(
                    map_get_any(
                        [max_total_msat, <<"max_total_msat">>], maps:merge(Meta, Policy), 0
                    ),
                    0
                ),
                expires_height => int_value(
                    map_get_any(
                        [expires_height, <<"expires_height">>], maps:merge(Meta, Policy), 0
                    ),
                    0
                )
            });
        _ ->
            Default
    end.

apply_policy_event(#{event_kind := 2} = Event, Policy) ->
    maps:merge(Policy, maps:merge(policy_fields(Event), #{revoked => false}));
apply_policy_event(#{event_kind := 3}, Policy) ->
    maps:put(revoked, true, Policy);
apply_policy_event(#{event_kind := 4} = Event, Policy) ->
    maps:merge(Policy, maps:merge(policy_fields(Event), #{revoked => false}));
apply_policy_event(_Event, Policy) ->
    Policy.

policy_fields(Event) ->
    maps:with([max_single_msat, max_total_msat, expires_height], Event).

fold_sessions([Event | Rest], Acc0) ->
    Key = maps:get(client_pubkey_hash, Event, <<>>),
    S0 = maps:get(Key, Acc0, placeholder_session(Key)),
    S1 = apply_session_event(Event, S0),
    fold_sessions(Rest, maps:put(Key, S1, Acc0));
fold_sessions([], Acc) ->
    Acc.

placeholder_session(Key) ->
    #{
        client_pubkey_hash => Key,
        client_pubkey => Key,
        status => <<"active">>,
        created_at => 0,
        last_used_at => 0,
        max_single_msat => 0,
        max_total_msat => 0,
        spent_msat => 0,
        balance_msat => 0,
        events => []
    }.

apply_session_event(Event, S0) ->
    Kind = maps:get(event_kind, Event, -1),
    Events = maps:get(events, S0, []) ++ [maps:remove(raw, Event)],
    S1 = S0#{events => Events},
    S2 = maps:put(
        last_used_at, erlang:max(maps:get(last_used_at, S1, 0), maps:get(block_time, Event, 0)), S1
    ),
    S3 =
        case maps:get(balance_after_msat, Event, undefined) of
            B when is_integer(B) -> maps:put(balance_msat, B, S2);
            _ -> S2
        end,
    case Kind of
        0 ->
            S3;
        1 ->
            maps:put(spent_msat, maps:get(spent_msat, S3, 0) + maps:get(amount_msat, Event, 0), S3);
        2 ->
            S4 = maps:merge(S3, policy_fields(Event)),
            S5 = S4#{status => <<"active">>},
            case maps:get(created_at, S5, 0) of
                0 -> maps:put(created_at, maps:get(block_time, Event, 0), S5);
                _ -> S5
            end;
        3 ->
            maps:put(status, <<"revoked">>, S3);
        4 ->
            maps:merge(S3, policy_fields(Event));
        _ ->
            S3
    end.

finalize_sessions(Map) ->
    Sessions = [finalize_session(S) || S <- maps:values(Map)],
    lists:sort(
        fun(A, B) -> maps:get(last_used_at, A, 0) >= maps:get(last_used_at, B, 0) end, Sessions
    ).

finalize_session(S0) ->
    Balance = maps:get(balance_msat, S0, 0),
    MaxTotal = maps:get(max_total_msat, S0, 0),
    Spent = maps:get(spent_msat, S0, 0),
    Allowance =
        case MaxTotal > 0 of
            true -> erlang:max(0, MaxTotal - Spent);
            false -> Balance
        end,
    Remaining =
        case MaxTotal > 0 of
            true -> erlang:min(Balance, Allowance);
            false -> Balance
        end,
    S0#{
        balance_sat => Balance div 1000,
        spent_sat => Spent div 1000,
        remaining_msat => Remaining,
        remaining_sat => Remaining div 1000,
        max_single_sat => maps:get(max_single_msat, S0, 0) div 1000,
        max_total_sat => MaxTotal div 1000
    }.

%% -------------------------------------------------------------------
%% Utilities
%% -------------------------------------------------------------------

client_pubkey_hash_hex(ClientPubHex) ->
    lower_hex(crypto:hash(sha256, hex64(ClientPubHex))).

hex64(B0) ->
    B = to_bin(B0),
    Lower = lower_ascii(B),
    case re:run(Lower, <<"^[0-9a-f]{64}$">>, [{capture, none}]) of
        match -> Lower;
        nomatch -> lower_hex(B)
    end.

normalize_meta_hash(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 -> lower_hex(Bin);
normalize_meta_hash(Bin) when is_binary(Bin) -> Bin;
normalize_meta_hash(Other) -> to_bin(Other).

event_height(Event) ->
    first_positive_int([
        map_get_any([height, <<"height">>, block_height, <<"block_height">>], Event, 0),
        map_get_path(Event, [payload, block_height]),
        map_get_path(Event, [<<"payload">>, <<"block_height">>])
    ]).

event_time(Event) ->
    T = first_positive_int([
        map_get_any(
            [
                micro_time,
                <<"micro_time">>,
                block_time,
                <<"block_time">>,
                time,
                <<"time">>,
                timestamp,
                <<"timestamp">>
            ],
            Event,
            0
        ),
        map_get_path(Event, [payload, micro_time]),
        map_get_path(Event, [<<"payload">>, <<"micro_time">>]),
        map_get_path(Event, [payload, block_time]),
        map_get_path(Event, [<<"payload">>, <<"block_time">>])
    ]),
    case T > 20000000000 of
        true -> T div 1000;
        false -> T
    end.

first_positive_int([H | T]) ->
    case int_value(H, 0) of
        I when I > 0 -> I;
        _ -> first_positive_int(T)
    end;
first_positive_int([]) ->
    0.

map_get_path(Map, [K | Ks]) when is_map(Map) ->
    case maps:get(K, Map, undefined) of
        undefined -> undefined;
        V -> map_get_path(V, Ks)
    end;
map_get_path(V, []) ->
    V;
map_get_path(_Other, _Path) ->
    undefined.

map_get_any([K | Ks], Map, Default) when is_map(Map) ->
    case maps:get(K, Map, undefined) of
        undefined -> map_get_any(Ks, Map, Default);
        V -> V
    end;
map_get_any([], _Map, Default) ->
    Default.

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([null | Rest]) -> first_defined(Rest);
first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([H | _]) -> H;
first_defined([]) -> undefined.

normalize_json(Map) when is_map(Map) ->
    maps:from_list([{to_key(K), normalize_json(V)} || {K, V} <- maps:to_list(Map)]);
normalize_json(List) when is_list(List) ->
    [normalize_json(V) || V <- List];
normalize_json(V) ->
    V.

to_key(K) when is_atom(K) -> K;
to_key(K) when is_binary(K) -> K;
to_key(K) -> to_bin(K).

int_value(V, _Default) when is_integer(V) -> V;
int_value(V, _Default) when is_float(V) -> trunc(V);
int_value(V, Default) when is_binary(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(V, Default) when is_list(V) ->
    case catch list_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(_, Default) ->
    Default.

bool_value(true, _Default) -> true;
bool_value(false, _Default) -> false;
bool_value(<<"true">>, _Default) -> true;
bool_value(<<"false">>, _Default) -> false;
bool_value(<<"1">>, _Default) -> true;
bool_value(<<"0">>, _Default) -> false;
bool_value(_, Default) -> Default.

clamp_int(I, Min, _Max) when is_integer(I), I < Min -> Min;
clamp_int(I, _Min, Max) when is_integer(I), I > Max -> Max;
clamp_int(I, _Min, _Max) when is_integer(I) -> I;
clamp_int(_, Min, _Max) -> Min.

direction(forward) -> "forward";
direction(backward) -> "backward";
direction(<<"forward">>) -> "forward";
direction(<<"backward">>) -> "backward";
direction("forward") -> "forward";
direction("backward") -> "backward";
direction(_) -> "backward".

take(N, _List) when N =< 0 -> [];
take(_N, []) -> [];
take(N, [H | T]) -> [H | take(N - 1, T)].

drop(N, List) when N =< 0 -> List;
drop(_N, []) -> [];
drop(N, [_ | T]) -> drop(N - 1, T).

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L;
to_s(A) when is_atom(A) -> atom_to_list(A);
to_s(I) when is_integer(I) -> integer_to_list(I).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

lower_ascii(Bin) when is_binary(Bin) ->
    try
        list_to_binary(string:lowercase(binary_to_list(Bin)))
    catch
        _:_ -> Bin
    end.

short_key(Key) when is_binary(Key), byte_size(Key) > 12 ->
    <<Head:12/binary, _/binary>> = Key,
    <<Head/binary, "...">>;
short_key(Key) ->
    to_bin(Key).
