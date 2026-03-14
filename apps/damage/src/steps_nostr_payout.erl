-module(steps_nostr_payout).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-include_lib("eunit/include/eunit.hrl").

-export([
    test/0,
    parse_since/1,
    deploy_contract/1
]).

-import(damage_ae, [contract_path/1]).
%% #{ NpubBin => LimitInt }
-define(CTX_ZAP_LIMITS, nostr_zap_limits).
%% #{ totals => #{EventIdBin => TotalSatsInt}, spent => #{NpubBin => TotalSatsInt} }
-define(CTX_ZAP_STATE, nostr_zap_state).
-define(NOSTR_ZAP_REGISTRY_CONTRACT, "ct_HPZe6tZM6VQqTQiozLiGxnfJPcRuVBVNLpkjkgZEUe5ojR9kP").
%% Poolboy pool used to parallelize zaps (acts as a concurrency limiter).
%%
%% We borrow a worker from the pool as a permit, then perform the zap in the
%% spawned job process. This bounds concurrency without requiring a dedicated
%% zap worker module.
-define(ZAP_POOL, nostr_zap_pool).
-define(DEFAULT_ZAP_POOL_SIZE, 8).
-define(DEFAULT_ZAP_POOL_OVERFLOW, 16).

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
    NpubKey = npub_to_key(Npub0),
    Limit = to_int(Limit0, 0),

    Limits0 = maps:get(?CTX_ZAP_LIMITS, Context0, #{}),
    Limits1 = maps:put(NpubKey, Limit, Limits0),
    Context1 = maps:put(?CTX_ZAP_LIMITS, Limits1, Context0),

    %% Optional on-chain update
    #{"tx_hash" := TxHash} = maybe_contract_set_limit(Context1, NpubKey, Limit),

    maps:put(onchain_zap_receipt, TxHash, Context1);
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
            ?LOG_DEBUG("Got events ~p", [length(Events)]),
            maps:put(OutVar, Events, Context0);
        Other ->
            maps:put(fail, to_bin(Other), Context0)
    end;
%% Then I get the zap spent for npub "npub1..." as "balance"
step(
    _Config,
    Context0,
    <<"Then">>,
    _Line,
    ["I get the zap spent for npub", Npub0, "as", OutVar],
    _Body
) ->
    true = steps_utils:is_admin(Context0),
    NpubKey = npub_to_key(Npub0),
    case catch maybe_contract_get_spent(Context0, NpubKey) of
        {ok, Spent} when is_integer(Spent) ->
            maps:put(OutVar, Spent, Context0);
        Other ->
            maps:put(fail, damage_utils:strf("get_spent failed: ~p", [Other]), Context0)
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

    {Receipts, Totals1, Spent1, Errors} = zap_posts(
        NsecKey, Posts, Base, Cap, Totals0, Spent0, Limits, Context0
    ),

    State1 = #{totals => Totals1, spent => Spent1, last_run_at => erlang:system_time(seconds)},
    Context1 =
        maps:put(
            <<"zap_receipts">>,
            Receipts,
            maps:put(?CTX_ZAP_STATE, State1, Context0)
        ),
    Context2 = maps:put(<<"nostr_zap_errors">>, Errors, Context1),

    %% If you want zaps to be “must succeed”, fail the scenario when any error exists.
    case Errors =:= [] of
        true ->
            Context2;
        false ->
            maps:put(
                fail,
                damage_utils:strf("nostr zap failures: ~p", [Errors]),
                Context2
            )
    end.

%% -------------------------------------------------------------------
%% Internals
%% -------------------------------------------------------------------

%% Parallelized zap executor.
%%
%% IMPORTANT: on-chain tracking is performed SEQUENTIALLY after the parallel
%% zap run to avoid AE nonce collisions for a single signer account.
zap_posts(_NsecKey, [], _Base, _Cap, Totals, Spent, _Limits, _Context) ->
    {[], Totals, Spent, []};
zap_posts(NsecKey, Posts, Base, Cap, Totals0, Spent0, Limits, Context) when is_list(Posts) ->
    %% 1) Plan amounts deterministically (sequential cap/limit accounting)
    {Jobs, _TotalsPlanned, _SpentPlanned} = plan_zaps(Posts, Base, Cap, Totals0, Spent0, Limits),

    %% 2) Execute zaps concurrently (bounded by pool size)
    Results = run_zap_jobs_parallel(NsecKey, Jobs),

    %% 3) Apply only successful zaps to local totals/spent
    {Receipts0, Totals1, Spent1, Errors0} = fold_zap_results(Results, Totals0, Spent0),

    %% 4) Record on-chain SEQUENTIALLY (nonce-safe)
    {Receipts1, Errors1} = record_zaps_onchain_sequential(Context, Receipts0),

    {Receipts1, Totals1, Spent1, Errors0 ++ Errors1}.

plan_zaps(Posts, Base, Cap, Totals0, Spent0, Limits) ->
    {JobsAcc, TotAcc, SpAcc} =
        lists:foldl(
            fun(E, {Jobs0, Tot0, Sp0}) ->
                Id = pick_id(E),
                Author = pick_pubkey(E),

                %% per-event cap tracking
                AlreadyEvent = maps:get(Id, Tot0, 0),
                RemainingEvent = Cap - AlreadyEvent,

                %% per-npub limit tracking (overall)
                NpubKey = author_to_npub_key(Author),
                LimitNpub = maps:get(NpubKey, Limits, 0),
                AlreadyNpub = maps:get(NpubKey, Sp0, 0),
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
                        {Jobs0, Tot0, Sp0};
                    false ->
                        Job = #{id => Id, author => Author, npub_key => NpubKey, amount => Amount},
                        {[Job | Jobs0], Tot0, Sp0}
                end
            end,
            {[], Totals0, Spent0},
            Posts
        ),
    {lists:reverse(JobsAcc), TotAcc, SpAcc}.

run_zap_jobs_parallel(_NsecKey, []) ->
    [];
run_zap_jobs_parallel(NsecKey, Jobs) ->
    case ensure_zap_pool() of
        ok -> ok;
        {error, Why} -> exit(Why)
    end,
    Parent = self(),

    Refs =
        [
            begin
                Ref = make_ref(),
                spawn_monitor(fun() ->
                    Res = zap_job(NsecKey, Job),
                    Parent ! {Ref, Job, Res}
                end),
                Ref
            end
         || Job <- Jobs
        ],
    collect_job_results(Refs, []).

zap_job(NsecKey, #{id := Id, author := Author, amount := Amount}) ->
    %% Borrow a pool worker as a permit, then run zap in *this* process.
    poolboy:transaction(
        ?ZAP_POOL,
        fun(_Worker) ->
            try
                case Author of
                    <<>> -> {ok, damage_nostr:zap_note(NsecKey, Id, Amount)};
                    _ -> {ok, damage_nostr:zap_note(NsecKey, Id, Author, Amount)}
                end
            catch
                C:R:S ->
                    ?LOG_WARNING("zap_note failed ~p:~p ~p", [C, R, S]),
                    {error, {C, R}}
            end
        end,
        infinity
    ).

collect_job_results([], Acc) ->
    lists:reverse(Acc);
collect_job_results(Refs, Acc) ->
    receive
        {Ref, Job, Res} ->
            collect_job_results(lists:delete(Ref, Refs), [{Job, Res} | Acc]);
        {'DOWN', _MRef, process, _Pid, _Reason} ->
            %% ignore: we rely on {Ref,Job,Res}
            collect_job_results(Refs, Acc)
    after 1800000 ->
        Missing = length(Refs),
        ?LOG_WARNING("zap parallel timeout: ~p jobs did not return", [Missing]),
        lists:reverse(Acc) ++ [{#{}, {error, timeout}} || _ <- Refs]
    end.

fold_zap_results(Results, Totals0, Spent0) ->
    {ReceiptsAcc, TotAcc, SpAcc, ErrAcc} =
        lists:foldl(
            fun({Job, Res}, {R0, T0, S0, E0}) ->
                case Job of
                    #{id := Id, author := Author, npub_key := NpubKey, amount := Amount} ->
                        case Res of
                            {ok, Receipt} ->
                                T1 = maps:put(Id, maps:get(Id, T0, 0) + Amount, T0),
                                S1 = maps:put(NpubKey, maps:get(NpubKey, S0, 0) + Amount, S0),
                                {
                                    [
                                        #{
                                            id => Id,
                                            author => Author,
                                            npub_key => NpubKey,
                                            amount => Amount,
                                            receipt => Receipt
                                        }
                                        | R0
                                    ],
                                    T1,
                                    S1,
                                    E0
                                };
                            {error, Why} ->
                                {
                                    [
                                        #{
                                            id => Id,
                                            author => Author,
                                            npub_key => NpubKey,
                                            amount => 0,
                                            receipt => {error, Why}
                                        }
                                        | R0
                                    ],
                                    T0,
                                    S0,
                                    [{zap_failed, Id, NpubKey, Why} | E0]
                                }
                        end;
                    _ ->
                        %% unknown/timeout placeholder
                        {[#{amount => 0, receipt => {error, timeout}} | R0], T0, S0, [
                            {zap_failed, timeout} | E0
                        ]}
                end
            end,
            {[], Totals0, Spent0, []},
            Results
        ),
    {lists:reverse(ReceiptsAcc), TotAcc, SpAcc, lists:reverse(ErrAcc)}.

record_zaps_onchain_sequential(Context, Receipts0) ->
    ?LOG_DEBUG("record_zaps_onchain_sequential ~p", [Receipts0]),
    {RsRev, EsRev} =
        lists:foldl(
            fun(R, {AccR, AccE}) ->
                Id = maps:get(id, R, <<>>),
                Amount = maps:get(amount, R, 0),
                NpubKey = maps:get(npub_key, R, <<>>),

                case Amount > 0 andalso Id =/= <<>> andalso NpubKey =/= <<>> of
                    true ->
                        case catch maybe_contract_record_zap(Context, NpubKey, Id, Amount) of
                            #{"tx_hash" := TxHash} ->
                                {[maps:put(tx_hash, TxHash, R) | AccR], AccE};
                            Other ->
                                ?LOG_ERROR("onchain record_zap failed id=~p npub=~p err=~p", [
                                    Id, NpubKey, Other
                                ]),
                                R1 =
                                    maps:put(
                                        tx_hash,
                                        <<>>,
                                        maps:put(onchain_error, to_bin(Other), R)
                                    ),
                                {[R1 | AccR], [{onchain_failed, Id, NpubKey, Other} | AccE]}
                        end;
                    false ->
                        {[maps:put(tx_hash, <<>>, R) | AccR], AccE}
                end
            end,
            {[], []},
            Receipts0
        ),
    {lists:reverse(RsRev), lists:reverse(EsRev)}.

ensure_zap_pool() ->
    case whereis(?ZAP_POOL) of
        undefined ->
            Size = application:get_env(damage, nostr_zap_pool_size, ?DEFAULT_ZAP_POOL_SIZE),
            Overflow = application:get_env(
                damage, nostr_zap_pool_overflow, ?DEFAULT_ZAP_POOL_OVERFLOW
            ),
            PoolArgs = [
                {name, {local, ?ZAP_POOL}},
                %% Reuse existing DamageBDD poolboy worker module as a lightweight worker.
                %% We treat the pool as a concurrency semaphore for zaps.
                {worker_module, damage},
                {size, Size},
                {max_overflow, Overflow}
            ],
            WorkerArgs = [],
            case poolboy:start_link(PoolArgs, WorkerArgs) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, {zap_pool_start_failed, Reason}}
            end;
        _Pid ->
            ok
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

contract_call(AeAccount, Func, Args) when is_binary(AeAccount) ->
    #{public_key := _PubKey, private_key := PrivateKey} =
        identity_server:get_account(AeAccount),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    Keypair = #{public_key => AeAccount, private_key => PrivateKey},
    {ok, ContractId} = account_registry:get_contract(Keypair, "nostr_zap_registry"),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        ContractId,
        "contracts/nostr_zap_registry.aes",
        Func,
        Args
    ).
maybe_contract_get_spent(#{public_key := AeAccount} = _Context, NpubKey) when
    is_binary(AeAccount)
->
    #{"return_value" := Res} = contract_call(AeAccount, "get_spent", [to_list(NpubKey)]),
    case parse_int_result(Res) of
        {ok, I} -> {ok, I};
        Err -> Err
    end;
maybe_contract_get_spent(_Context, _NpubKey) ->
    {error, missing_public_key}.

maybe_contract_set_limit(#{public_key := AeAccount} = _Context, NpubKey, Limit) ->
    contract_call(AeAccount, "set_limit", [NpubKey, Limit]).

maybe_contract_record_zap(#{public_key := AeAccount} = _Context, NpubKey, EventId, Sats) ->
    Ts = erlang:system_time(seconds),
    contract_call(
        AeAccount,
        "record_zap",
        [to_list(NpubKey), to_list(EventId), Sats, Ts]
    ).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(T) -> io_lib:format("~p", [T]).
%% Contract expects npub as a string key.
%% We standardize on lower-hex64 of the pubkey, same as record_zap uses.
npub_to_key(Npub0) ->
    NpubB = to_bin(Npub0),
    case NpubB of
        <<"npub1", _/binary>> ->
            %% decode_npub likely returns pubkey bytes; normalize to lower hex64
            to_lower_hex64(to_bin(damage_nostr:decode_npub(NpubB)));
        _ ->
            %% allow already-hex keys or raw bytes
            to_lower_hex64(NpubB)
    end.

parse_int_result(I) when is_integer(I) -> {ok, I};
parse_int_result(#{"result" := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{result := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{"value" := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{value := I}) when is_integer(I) -> {ok, I};
parse_int_result(Other) -> {error, {unexpected_int_result, Other}}.

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
deploy_contract(AeAccount) when is_list(AeAccount) ->
    deploy_contract(to_bin(AeAccount));
deploy_contract(AeAccount) ->
    #{public_key := AeAccount, private_key := PrivateKey} =
        identity_server:get_account(AeAccount),
    Keypair = #{public_key => AeAccount, private_key => PrivateKey},
    %damage_ae:set_private_key(AeAccount, PrivateKey),
    case account_registry:get_contract(Keypair, "nostr_zap_registry") of
        {ok, ContractId} ->
            ContractId;
        _ ->
            #{"contract_id" := ContractId} = damage_ae:contract_deploy(
                contract_path("contracts/nostr_zap_registry.aes"), [AeAccount]
            ),
            ?LOG_DEBUG("nostr_zap_registry ~p ~p", [Keypair, ContractId]),
            account_registry:register_contract(Keypair, "nostr_zap_registry", ContractId)
    end.
