-module(steps_nostr_payout).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-include_lib("eunit/include/eunit.hrl").

-export([
    test/0,
    parse_since/1
]).

%% #{ NpubBin => LimitInt }
-define(CTX_ZAP_LIMITS, nostr_zap_limits).
%% #{ totals => #{EventIdBin => TotalSatsInt}, spent => #{NpubBin => TotalSatsInt} }
-define(CTX_ZAP_STATE, nostr_zap_state).

%% Optional contract tracking keys (expected in Context):
%%   - "nostr_zap_registry_contract" => <<"ct_...">>
%% Uses the current AE keypair in Context (public_key/private_key) as signer.

%% -------------------------------------------------------------------
%% Steps used by feature
%% -------------------------------------------------------------------

%% Given I set zap limit for npub "npub1..." to 100000 sats
step(
    _Config,
    Context0,
    <<"Given">>,
    _Line,
    ["I set zap limit for npub", Npub0, "to", Limit0, "sats"],
    _Body
) ->
    true = steps_utils:is_admin(Context0),
    Npub = normalize_npub(Npub0),
    Limit = to_int(Limit0, 0),

    Limits0 = maps:get(?CTX_ZAP_LIMITS, Context0, #{}),
    Limits1 = maps:put(Npub, Limit, Limits0),
    Context1 = maps:put(?CTX_ZAP_LIMITS, Limits1, Context0),

    %% Optional on-chain update
    _ = maybe_contract_set_limit(Context1, Npub, Limit),
    Context1;
%% Then I list nostr posts for npub "npub1..." in last "24" hours store as "posts"
step(
    _Config,
    Context0,
    <<"Then">>,
    _Line,
    ["I list nostr posts for npub", Npub0, "in last", Hours0, "hours store as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, damage_nostr_nsec),
    Hours = to_int(Hours0, 24),
    Now = erlang:system_time(seconds),
    Since = Now - (Hours * 3600),

    case damage_nostr:get_posts_since(NsecKey, normalize_npub(Npub0), Since) of
        {ok, Events0} when is_list(Events0) ->
            Events = [E || E <- Events0, in_window(E, Since, Now), is_note(E)],
            maps:put(OutVar, Events, Context0);
        Other ->
            maps:put(fail, to_bin(Other), Context0)
    end;
%% Then I list nostr posts for npub "npub1..." since "2026-02-01" store as "posts"
step(
    _Config,
    Context0,
    <<"Then">>,
    _Line,
    ["I list nostr posts for npub", Npub0, "since", Since0, "store as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, damage_nostr_nsec),
    Now = erlang:system_time(seconds),
    Since = parse_since(Since0),

    case damage_nostr:get_posts_since(NsecKey, normalize_npub(Npub0), Since) of
        {ok, Events0} when is_list(Events0) ->
            %% keep notes; range is [Since..Now]
            Events = [E || E <- Events0, in_window(E, Since, Now), is_note(E)],
            maps:put(OutVar, Events, Context0);
        Other ->
            maps:put(fail, to_bin(Other), Context0)
    end;
%% Then I zap posts in "posts" base sats "21" cap sats "10000"
step(
    _Config,
    Context0,
    <<"Then">>,
    _Line,
    ["I zap posts in", PostsVar, "base sats", Base0, "cap sats", Cap0],
    Body
) ->
    true = steps_utils:is_admin(Context0),
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, damage_nostr_nsec),

    Base = to_int(Base0, 0),
    Cap = to_int(Cap0, 10000),

    Posts = maps:get(PostsVar, Context0, []),

    %% Get mutable state
    State0 = maps:get(?CTX_ZAP_STATE, Context0, #{totals => #{}, spent => #{}}),
    Totals0 = maps:get(totals, State0, #{}),
    Spent0 = maps:get(spent, State0, #{}),

    Limits = maps:get(?CTX_ZAP_LIMITS, Context0, #{}),

    {Receipts, Totals1, Spent1} = zap_posts(
        NsecKey, Posts, Base, Cap, Totals0, Spent0, Limits, Context0
    ),

    State1 = #{totals => Totals1, spent => Spent1, last_run_at => erlang:system_time(seconds)},
    maps:put(
        <<"zap_receipts">>,
        Receipts,
        maps:put(?CTX_ZAP_STATE, State1, Context0)
    ).

%% -------------------------------------------------------------------
%% Internals
%% -------------------------------------------------------------------

zap_posts(_NsecKey, [], _Base, _Cap, Totals, Spent, _Limits, _Context) ->
    {[], Totals, Spent};
zap_posts(NsecKey, [E | Rest], Base, Cap, Totals0, Spent0, Limits, Context) ->
    Id = pick_id(E),
    Author = pick_pubkey(E),

    %% per-event cap tracking
    AlreadyEvent = maps:get(Id, Totals0, 0),
    RemainingEvent = Cap - AlreadyEvent,

    %% per-npub limit tracking (overall)
    NpubKey = author_to_npub_key(Author),
    LimitNpub = maps:get(NpubKey, Limits, 0),
    AlreadyNpub = maps:get(NpubKey, Spent0, 0),
    RemainingNpub =
        case LimitNpub > 0 of
            true -> LimitNpub - AlreadyNpub;
            false -> 999999999
        end,

    Amount0 = Base,
    Amount1 = clamp_int(Amount0, 0, RemainingEvent),
    Amount = clamp_int(Amount1, 0, RemainingNpub),

    case Amount =< 0 orelse Id =:= <<>> of
        true ->
            zap_posts(NsecKey, Rest, Base, Cap, Totals0, Spent0, Limits, Context);
        false ->
            Receipt =
                case Author of
                    <<>> -> damage_nostr:zap_note(NsecKey, Id, Amount);
                    _ -> damage_nostr:zap_note(NsecKey, Id, Author, Amount)
                end,

            %% Update local state
            Totals1 = maps:put(Id, AlreadyEvent + Amount, Totals0),
            Spent1 = maps:put(NpubKey, AlreadyNpub + Amount, Spent0),

            %% Optional on-chain tracking
            _ = maybe_contract_record_zap(Context, NpubKey, Id, Amount),

            {ReceiptsRest, Totals2, Spent2} = zap_posts(
                NsecKey, Rest, Base, Cap, Totals1, Spent1, Limits, Context
            ),
            {
                [
                    #{id => Id, author => Author, amount => Amount, receipt => Receipt}
                    | ReceiptsRest
                ],
                Totals2,
                Spent2
            }
    end.

%% We store limits/spent keyed by the raw author pubkey hex (lowercase) if present.
author_to_npub_key(<<>>) -> <<"">>;
author_to_npub_key(Pub) -> to_lower_hex64(Pub).

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

%% Normalize inputs
normalize_npub(Npub0) ->
    Npub = to_bin(Npub0),
    case Npub of
        <<"npub1", _/binary>> -> to_bin(damage_nostr:decode_npub(Npub));
        _ -> Npub
    end.

%% If pubkey already hex64, keep; if bytes, hex it.
to_lower_hex64(Bin) when is_binary(Bin) ->
    %% If it looks like 64 hex chars, normalize case
    case Bin of
        <<_:64/binary>> -> lower_hex(Bin);
        _ -> lower_hex(binary:encode_hex(Bin))
    end.

lower_hex(B) ->
    <<<<(to_lower(C))>> || <<C>> <= B>>.

to_lower(C) when C >= $A, C =< $F -> C + 32;
to_lower(C) -> C.

%% date parsing: unix seconds or YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ
parse_since(Date0) ->
    B = to_bin(Date0),
    case catch binary_to_integer(B) of
        N when is_integer(N), N > 0 -> N;
        _ -> parse_isoish(B)
    end.

parse_isoish(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary, _/binary>> = B) ->
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

map_get_atom_or_bin(<<>>, _, DefaultAtom) ->
    DefaultAtom;
map_get_atom_or_bin(M, K, DefaultAtom) ->
    case maps:get(K, M, DefaultAtom) of
        A when is_atom(A) -> A;
        B when is_binary(B) -> binary_to_atom(B, utf8);
        L when is_list(L) -> list_to_atom(L);
        _ -> DefaultAtom
    end.

%% -------------------------------------------------------------------
%% Optional Sophia tracking
%% -------------------------------------------------------------------

maybe_contract_set_limit(Context, NpubKey, Limit) ->
    case maps:get(<<"nostr_zap_registry_contract">>, Context, undefined) of
        undefined ->
            ok;
        ContractId ->
            case keypair_from_context(Context) of
                {ok, KP} ->
                    %% contract file path is expected to be in repo; use relative string
                    %% If you keep it elsewhere, change this path.
                    damage_ae:contract_call(
                        KP, ContractId, "contracts/nostr_zap_registry.aes", "set_limit", [
                            to_list(NpubKey), Limit
                        ]
                    );
                _ ->
                    ok
            end
    end.

maybe_contract_record_zap(Context, NpubKey, EventId, Sats) ->
    case maps:get(<<"nostr_zap_registry_contract">>, Context, undefined) of
        undefined ->
            ok;
        ContractId ->
            case keypair_from_context(Context) of
                {ok, KP} ->
                    Ts = erlang:system_time(seconds),
                    damage_ae:contract_call(
                        KP,
                        ContractId,
                        "contracts/nostr_zap_registry.aes",
                        "record_zap",
                        [to_list(NpubKey), to_list(EventId), Sats, Ts]
                    );
                _ ->
                    ok
            end
    end.

keypair_from_context(Context) ->
    case {maps:get(public_key, Context, undefined), maps:get(private_key, Context, undefined)} of
        {undefined, _} -> {error, no_public_key};
        {_, undefined} -> {error, no_private_key};
        {Pub, Priv} -> {ok, #{public_key => Pub, private_key => Priv}}
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(T) -> io_lib:format("~p", [T]).

set_zap_limit_step_test_() ->
    Config = [],
    %% Ensure admin
    Context0 = #{admin => true},

    %% Parse tokens exactly as your matcher expects
    Tokens = [
        "I set zap limit for npub",
        <<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>,
        "to",
        <<"100000">>,
        "sats"
    ],

    Context1 =
        step(Config, Context0, <<"Given">>, 1, Tokens, #{}),

    Limits = maps:get(?CTX_ZAP_LIMITS, Context1),
    Npub = normalize_npub(<<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>),

    ?assertEqual(100000, maps:get(Npub, Limits)).

list_posts_last_hours_step_test_() ->
    Config = [],
    Context0 = #{},
    Body = #{<<"nsec_key">> => damage_nostr_nsec},

    Npub = <<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>,
    OutVar = <<"posts">>,

    %% Your matcher includes "hours store as" as one token in the snippet you pasted.
    %% Keep it EXACT or it won’t match.
    Tokens = [
        "I list nostr posts for npub",
        Npub,
        "in last",
        <<"24">>,
        "hours store as",
        OutVar
    ],

    Now = erlang:system_time(seconds),
    E1 = #{<<"kind">> => 1, <<"created_at">> => Now - 60, <<"id">> => <<"e1">>},
    E2 = #{<<"kind">> => 1, <<"created_at">> => Now - 120, <<"id">> => <<"e2">>},

    %% Mock nostr fetch to return 2 events
    meck:expect(
        damage_nostr,
        get_posts_since,
        fun(_NsecKey, _NpubNorm, _Since) -> {ok, [E1, E2]} end
    ),

    Context1 =
        step(Config, Context0, <<"Then">>, 1, Tokens, Body),

    Posts = maps:get(OutVar, Context1),
    ?assertEqual(true, is_list(Posts)),
    ?assertEqual(2, length(Posts)).

list_posts_since_date_step_test_() ->
    Config = [],
    Context0 = #{},
    Body = #{<<"nsec_key">> => damage_nostr_nsec},

    Npub = <<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>,
    OutVar = <<"posts">>,

    Tokens = [
        "I list nostr posts for npub",
        Npub,
        "since",
        <<"2026-02-01">>,
        "store as",
        OutVar
    ],

    %Now = erlang:system_time(seconds),
    %% event inside window
    %E1 = #{<<"kind">> => 1, <<"created_at">> => Now - 60, <<"id">> => <<"e1">>},

    Since0 = <<"2026-01-15">>,
    Since = parse_since(Since0),
    ?LOG_DEBUG("Since ~s~n", [Since]),
    Result = damage_nostr:get_posts_since(
        damage_nostr_nsec, Npub, Since
    ),
    {ok, [Event | _]} = Result,
    Content = maps:get(<<"content">>, Event),

    ?LOG_DEBUG("~s~n", [Content]),

    Context1 =
        step(Config, Context0, <<"Then">>, 1, Tokens, Body),

    Posts = maps:get(OutVar, Context1),
    ?assertEqual(1, length(Posts)).

zap_posts_step_test_() ->
    Config = [],
    %% Ensure admin
    Context0 = #{admin => true},

    PostsVar = <<"posts">>,
    Posts = [#{<<"kind">> => 1, <<"created_at">> => 1, <<"id">> => <<"e1">>}],

    %% Seed context with posts + limits
    NpubNorm = normalize_npub(
        <<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>
    ),
    ContextA = maps:put(PostsVar, Posts, Context0),
    ContextB = maps:put(?CTX_ZAP_LIMITS, #{NpubNorm => 100000}, ContextA),

    %% Mock zap_posts to avoid real network / payments.
    %% Requires zap_posts/9 to be exported under -DTEST as described above.
    Receipts = [#{event_id => <<"e1">>, sats => 21, status => paid}],
    Totals1 = #{NpubNorm => 21},
    Spent1 = #{<<"e1">> => 21},

    meck:expect(
        ?MODULE,
        zap_posts,
        fun(_NsecKey, _PostsIn, _Base, _Cap, _Totals0, _Spent0, _Limits, _Context0) ->
            {Receipts, Totals1, Spent1}
        end
    ),

    Body = #{<<"nsec_key">> => damage_nostr_nsec},
    Tokens = ["I zap posts in", PostsVar, "base sats", <<"21">>, "cap sats", <<"10000">>],

    Context1 =
        step(Config, ContextB, <<"Then">>, 1, Tokens, Body),

    %% Assert state written
    State1 = maps:get(?CTX_ZAP_STATE, Context1),
    ?assertEqual(Totals1, maps:get(totals, State1)),
    ?assertEqual(Spent1, maps:get(spent, State1)),

    %% Assert receipts written
    R = maps:get(<<"zap_receipts">>, Context1),
    ?assertEqual(Receipts, R).

test() ->
    list_posts_since_date_step_test_().
