%% steps_nostr_payout.erl
-module(steps_nostr_payout).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-export([test/0]).

%% -------------------------------------------------------------------
%% Listing posts
%% -------------------------------------------------------------------
%%
%% Then I list nostr posts for npub "npub1..." in last "24" hours store as "posts"
%% Body:
%% {
%%   "nsec_key": "nostr_nsec" | "damage_nostr_nsec",
%%   "limit": 200
%% }
%%
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    ["I list nostr posts for npub", Npub0, "in last", Hours0, "hours", "store as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, nostr_nsec),
    %Limit = map_get_int(Body, <<"limit">>, 200),

    Hours = to_int(Hours0, 24),
    Now = erlang:system_time(seconds),
    Since = Now - (Hours * 3600),

    case damage_nostr:get_posts_since(NsecKey, normalize_npub(Npub0), Since) of
        {ok, Events0} when is_list(Events0) ->
            %% Keep only kind=1 notes, and within [Since..Now]
            Events = [E || E <- Events0, in_window(E, Since, Now), is_note(E)],
            maps:put(OutVar, Events, Context);
        Other ->
            maps:put(fail, to_bin(Other), Context)
    end;
%% Explicit range (unix seconds)
%%
%% Then I list nostr posts for npub "npub1..." since "1700000000" until "1700086400" store as "posts"
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    ["I list nostr posts for npub", Npub0, "since", Since0, "until", Until0, "store as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, nostr_nsec),
    Limit = map_get_int(Body, <<"limit">>, 500),

    Since = to_int(Since0, 0),
    Until = to_int(Until0, erlang:system_time(seconds)),

    case damage_nostr:get_posts_since(NsecKey, normalize_npub(Npub0), Since) of
        {ok, Events0} when is_list(Events0) ->
            Events1 = take_limit(Events0, Limit),
            Events = [E || E <- Events1, in_window(E, Since, Until), is_note(E)],
            maps:put(OutVar, Events, Context);
        Other ->
            maps:put(fail, to_bin(Other), Context)
    end;
%% -------------------------------------------------------------------
%% NEW: Zap all posts by npub since date
%% -------------------------------------------------------------------
%%
%% Then I zap all posts by npub "npub1..." since "2026-02-01" base sats "21" cap sats "10000"
%%      store state as "payout_state_out" store receipts as "zap_receipts"
%%
%% Then I zap all posts by npub "npub1..." since "1700000000" base sats "21" cap sats "10000"
%%      using state "payout_state" store state as "payout_state_out" store receipts as "zap_receipts"
%%
%% Body:
%% {
%%   "nsec_key": "nostr_nsec",
%%   "limit": 500
%% }
%%
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    [
        "I zap all posts by npub",
        Npub0,
        "since",
        Date0,
        "base sats",
        Base0,
        "cap sats",
        Cap0,
        "using state",
        StateInVar,
        "store state as",
        StateOutVar,
        "store receipts as",
        ReceiptsOutVar
    ],
    Body
) ->
    true = steps_utils:is_admin(Context),
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, nostr_nsec),
    Limit = map_get_int(Body, <<"limit">>, 500),

    Base = to_int(Base0, 0),
    Cap = to_int(Cap0, 10000),

    Since = parse_since(Date0),
    Now = erlang:system_time(seconds),

    %% Pull posts
    case damage_nostr:get_posts_since(NsecKey, normalize_npub(Npub0), Since) of
        {ok, Events0} when is_list(Events0) ->
            Events1 = take_limit(Events0, Limit),
            Posts = [E || E <- Events1, in_window(E, Since, Now), is_note(E)],

            StateIn = maps:get(StateInVar, Context, #{}),
            Totals0 = maps:get(totals, StateIn, #{}),

            {Receipts, Totals1} = zap_posts(NsecKey, Posts, Base, Cap, Totals0),

            StateOut = #{
                totals => Totals1,
                last_run_at => erlang:system_time(seconds)
            },

            Context1 = maps:put(StateOutVar, StateOut, Context),
            maps:put(ReceiptsOutVar, Receipts, Context1);
        Other ->
            maps:put(fail, to_bin(Other), Context)
    end;
%% Convenience: no prior state provided
step(
    Config,
    Context,
    <<"Then">>,
    Line,
    [
        "I zap all posts by npub",
        Npub0,
        "since",
        Date0,
        "base sats",
        Base0,
        "cap sats",
        Cap0,
        "store state as",
        StateOutVar,
        "store receipts as",
        ReceiptsOutVar
    ],
    Body
) ->
    step(
        Config,
        Context,
        <<"Then">>,
        Line,
        [
            "I zap all posts by npub",
            Npub0,
            "since",
            Date0,
            "base sats",
            Base0,
            "cap sats",
            Cap0,
            "using state",
            <<"payout_state">>,
            "store state as",
            StateOutVar,
            "store receipts as",
            ReceiptsOutVar
        ],
        Body
    );
%% -------------------------------------------------------------------
%% Zapping posts with cap + state in/out
%% -------------------------------------------------------------------
%%
%% Then I zap posts in "posts" base sats "21" cap sats "10000"
%%      using state "payout_state" store state as "payout_state_out" store receipts as "zap_receipts"
%%
%% Body:
%% {
%%   "nsec_key": "nostr_nsec",
%%   "reaction_bonus_fn": "none"   %% placeholder hook
%% }
%%
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    [
        "I zap posts in",
        PostsVar,
        "base sats",
        Base0,
        "cap sats",
        Cap0,
        "using state",
        StateInVar,
        "store state as",
        StateOutVar,
        "store receipts as",
        ReceiptsOutVar
    ],
    Body
) ->
    true = steps_utils:is_admin(Context),
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, nostr_nsec),

    Base = to_int(Base0, 0),
    Cap = to_int(Cap0, 10000),

    Posts = maps:get(PostsVar, Context, []),
    StateIn = maps:get(StateInVar, Context, #{}),

    %% State layout:
    %% #{
    %%   totals => #{ EventIdBin => TotalSatsInt },
    %%   last_run_at => UnixSeconds
    %% }
    Totals0 = maps:get(totals, StateIn, #{}),

    {Receipts, Totals1} = zap_posts(NsecKey, Posts, Base, Cap, Totals0),

    StateOut = #{
        totals => Totals1,
        last_run_at => erlang:system_time(seconds)
    },

    Context1 = maps:put(StateOutVar, StateOut, Context),
    maps:put(ReceiptsOutVar, Receipts, Context1);
%% Convenience: if you don’t have prior state, start from empty
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    [
        "I zap posts in",
        PostsVar,
        "base sats",
        Base0,
        "cap sats",
        Cap0,
        "store state as",
        StateOutVar,
        "store receipts as",
        ReceiptsOutVar
    ],
    Body
) ->
    step(
        _Config,
        Context,
        <<"Then">>,
        _Line,
        [
            "I zap posts in",
            PostsVar,
            "base sats",
            Base0,
            "cap sats",
            Cap0,
            "using state",
            <<"payout_state">>,
            "store state as",
            StateOutVar,
            "store receipts as",
            ReceiptsOutVar
        ],
        Body
    ).

%% -------------------------------------------------------------------
%% Internals
%% -------------------------------------------------------------------

zap_posts(_NsecKey, [], _Base, _Cap, Totals) ->
    {[], Totals};
zap_posts(NsecKey, [E | Rest], Base, Cap, Totals0) ->
    Id = pick_id(E),
    Author = pick_pubkey(E),

    Already = maps:get(Id, Totals0, 0),
    Remaining = Cap - Already,

    %% TODO: reaction bonus hook can be layered as:
    %% Bonus = calc_bonus(E, ...),
    %% Amount0 = Base + Bonus
    Amount0 = Base,
    Amount = clamp_int(Amount0, 0, Remaining),

    case Amount =< 0 orelse Id =:= <<>> of
        true ->
            zap_posts(NsecKey, Rest, Base, Cap, Totals0);
        false ->
            %% If Author present, prefer zap_note/4 (already in your damage_nostr)
            Receipt =
                case Author of
                    <<>> -> damage_nostr:zap_note(NsecKey, Id, Amount);
                    _ -> damage_nostr:zap_note(NsecKey, Id, Author, Amount)
                end,
            Totals1 = maps:put(Id, Already + Amount, Totals0),
            {ReceiptsRest, Totals2} = zap_posts(NsecKey, Rest, Base, Cap, Totals1),
            {
                [
                    #{id => Id, author => Author, amount => Amount, receipt => Receipt}
                    | ReceiptsRest
                ],
                Totals2
            }
    end.

pick_id(#{<<"id">> := I}) -> I;
pick_id(#{id := I}) -> to_bin(I);
pick_id(_) -> <<>>.

pick_pubkey(#{<<"pubkey">> := P}) -> P;
pick_pubkey(#{pubkey := P}) -> to_bin(P);
pick_pubkey(_) -> <<>>.

created_at(#{<<"created_at">> := T}) when is_integer(T) -> T;
created_at(#{created_at := T}) when is_integer(T) -> T;
created_at(_) -> 0.

is_note(#{<<"kind">> := 1}) -> true;
is_note(#{kind := 1}) -> true;
is_note(_) -> false.

in_window(E, Since, Until) ->
    T = created_at(E),
    T >= Since andalso T =< Until.

take_limit(L, N) when is_integer(N), N > 0 -> lists:sublist(L, N);
take_limit(L, _) -> L.

normalize_npub(Npub0) ->
    %% damage_nostr:get_posts_since wants Npub (decoded?) in your code it does lower_hex(Npub)
    %% so pass through decode if it’s npub1..., else assume already bytes/hex.
    Npub = to_bin(Npub0),
    case Npub of
        <<"npub1", _/binary>> ->
            %% decode_npub returns a list (hex?) in your implementation; normalize to binary
            to_bin(damage_nostr:decode_npub(Npub));
        _ ->
            Npub
    end.

%% date parsing: unix seconds or YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ
parse_since(Date0) ->
    B = to_bin(Date0),
    case catch binary_to_integer(B) of
        N when is_integer(N), N > 0 ->
            N;
        _ ->
            parse_isoish(B)
    end.

parse_isoish(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary, _/binary>> = B) ->
    %% For YYYY-MM-DD and YYYY-MM-DDTHH:MM:SSZ, we use UTC midnight if no time.
    %% Simple parser without timezone math: if time present, parse HH:MM:SS too.
    {Year, Month, Day} = {bin2i(Y), bin2i(M), bin2i(D)},
    {Hour, Min, Sec} =
        case B of
            <<_Date:10/binary, "T", HH:2/binary, ":", MM:2/binary, ":", SS:2/binary, _/binary>> ->
                {bin2i(HH), bin2i(MM), bin2i(SS)};
            _ ->
                {0, 0, 0}
        end,
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Min, Sec}}) -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}});
parse_isoish(_Other) ->
    %% fallback: now - 24h
    erlang:system_time(seconds) - 86400.

bin2i(Bin2) ->
    case catch binary_to_integer(Bin2) of
        I when is_integer(I) -> I;
        _ -> 0
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(T) -> unicode:characters_to_binary(io_lib:format("~p", [T])).

to_int(I, _Default) when is_integer(I) -> I;
to_int(B, Default) when is_binary(B) ->
    case catch binary_to_integer(B) of
        N when is_integer(N) -> N;
        _ -> Default
    end;
to_int(L, Default) when is_list(L) ->
    case catch list_to_integer(L) of
        N when is_integer(N) -> N;
        _ -> Default
    end;
to_int(_, Default) ->
    Default.

clamp_int(V, Min, _Max) when V < Min -> Min;
clamp_int(V, _Min, Max) when V > Max -> Max;
clamp_int(V, _Min, _Max) -> V.

map_get_int(M, K, Default) ->
    to_int(maps:get(K, M, Default), Default).

map_get_atom_or_bin(M, K, DefaultAtom) ->
    case maps:get(K, M, DefaultAtom) of
        A when is_atom(A) -> A;
        B when is_binary(B) -> binary_to_atom(B, utf8);
        L when is_list(L) -> list_to_atom(L);
        _ -> DefaultAtom
    end.

test() -> ok.
