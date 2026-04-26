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

-import(damage_ae, [contract_path/2]).

%% #{ NpubBin => LimitInt }
-define(CTX_ZAP_LIMITS, nostr_zap_limits).
%% #{ totals => #{EventIdBin => TotalSatsInt}, spent => #{NpubBin => TotalSatsInt} }
-define(CTX_ZAP_STATE, nostr_zap_state).
-define(NOSTR_ZAP_REGISTRY_CONTRACT, "ct_HPZe6tZM6VQqTQiozLiGxnfJPcRuVBVNLpkjkgZEUe5ojR9kP").

%% Poolboy pool used to parallelize zaps (acts as a concurrency limiter).
-define(ZAP_POOL, nostr_zap_pool).
-define(DEFAULT_ZAP_POOL_SIZE, 8).
-define(DEFAULT_ZAP_POOL_OVERFLOW, 16).

%% Stream/timeout tuning
-define(DEFAULT_ZAP_JOB_TIMEOUT_MS, 120000).
-define(DEFAULT_PROGRESS_HEARTBEAT_MS, 5000).

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
    Config,
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
    Strict = map_get_bool(Body, <<"strict">>, false),
    JobTimeoutMs =
        to_int(
            map_get(Body, <<"job_timeout_ms">>, ?DEFAULT_ZAP_JOB_TIMEOUT_MS),
            ?DEFAULT_ZAP_JOB_TIMEOUT_MS
        ),

    Posts = maps:get(PostsVar, Context0, []),

    State0 = maps:get(?CTX_ZAP_STATE, Context0, #{totals => #{}, spent => #{}}),
    Totals0 = maps:get(totals, State0, #{}),
    Spent0 = maps:get(spent, State0, #{}),
    Limits = maps:get(?CTX_ZAP_LIMITS, Context0, #{}),

    {Receipts, Totals1, Spent1, Errors} = zap_posts(
        Config,
        NsecKey,
        Posts,
        Base,
        Cap,
        Totals0,
        Spent0,
        Limits,
        Context0,
        #{
            strict => Strict,
            job_timeout_ms => JobTimeoutMs
        }
    ),

    State1 = #{
        totals => Totals1,
        spent => Spent1,
        last_run_at => erlang:system_time(seconds)
    },
    Summary = #{
        total => length(Posts),
        planned => length(Receipts),
        zap_ok => count_zap_successes(Receipts),
        onchain_ok => count_onchain_successes(Receipts),
        failed => length(Errors)
    },

    Context1 =
        maps:put(
            <<"zap_receipts">>,
            Receipts,
            maps:put(
                <<"nostr_zap_summary">>,
                Summary,
                maps:put(?CTX_ZAP_STATE, State1, Context0)
            )
        ),
    Context2 = maps:put(<<"nostr_zap_errors">>, Errors, Context1),

    case Strict andalso Errors =/= [] of
        true ->
            maps:put(
                fail,
                damage_utils:strf("nostr zap failures: ~p", [Errors]),
                Context2
            );
        false ->
            Context2
    end.

%% -------------------------------------------------------------------
%% Internals
%% -------------------------------------------------------------------

zap_posts(Config, NsecKey, Posts, Base, Cap, Totals0, Spent0, Limits, Context, Opts) when
    is_list(Posts)
->
    ?LOG_WARNING(
        "zap_posts start posts=~p base=~p cap=~p prior_totals=~p prior_spent=~p limits=~p opts=~p",
        [length(Posts), Base, Cap, maps:size(Totals0), maps:size(Spent0), maps:size(Limits), Opts]
    ),
    {Jobs, _TotalsPlanned, _SpentPlanned} = plan_zaps(Posts, Base, Cap, Totals0, Spent0, Limits),
    ?LOG_WARNING(
        "zap_posts planned jobs=~p skipped=~p",
        [length(Jobs), length(Posts) - length(Jobs)]
    ),
    log_planned_jobs(Jobs),
    emit_progress(
        Config,
        damage_utils:strf("planned ~p zaps", [length(Jobs)])
    ),
    run_zap_jobs_streaming(Config, NsecKey, Jobs, Totals0, Spent0, Context, Opts).

log_planned_jobs(Jobs) ->
    lists:foreach(
        fun(Job) ->
            ?LOG_INFO(
                "planned job event=~p npub=~p amount=~p author=~p",
                [
                    maps:get(id, Job, <<>>),
                    maps:get(npub_key, Job, <<>>),
                    maps:get(amount, Job, 0),
                    maps:get(author, Job, <<>>)
                ]
            )
        end,
        Jobs
    ).

plan_zaps(Posts, Base, Cap, Totals0, Spent0, Limits) ->
    {JobsAcc, TotAcc, SpAcc} =
        lists:foldl(
            fun(E, {Jobs0, Tot0, Sp0}) ->
                Id = pick_id(E),
                Author = pick_pubkey(E),

                AlreadyEvent = maps:get(Id, Tot0, 0),
                RemainingEvent = Cap - AlreadyEvent,

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

                case Amount =< 0 orelse Id =:= <<>> orelse NpubKey =:= <<>> of
                    true ->
                        {Jobs0, Tot0, Sp0};
                    false ->
                        Job = #{id => Id, author => Author, npub_key => NpubKey, amount => Amount},
                        Tot1 = maps:put(Id, maps:get(Id, Tot0, 0) + Amount, Tot0),
                        Sp1 = maps:put(NpubKey, maps:get(NpubKey, Sp0, 0) + Amount, Sp0),
                        {[Job | Jobs0], Tot1, Sp1}
                end
            end,
            {[], Totals0, Spent0},
            Posts
        ),
    {lists:reverse(JobsAcc), TotAcc, SpAcc}.

run_zap_jobs_streaming(Config, NsecKey, Jobs, Totals0, Spent0, Context, Opts) ->
    case ensure_zap_pool() of
        ok -> ok;
        {error, Why} -> exit(Why)
    end,

    Parent = self(),
    JobTimeoutMs = maps:get(job_timeout_ms, Opts, ?DEFAULT_ZAP_JOB_TIMEOUT_MS),

    ?LOG_WARNING(
        "run_zap_jobs_streaming jobs=~p timeout_ms=~p pool=~p",
        [length(Jobs), JobTimeoutMs, ?ZAP_POOL]
    ),

    Pending0 =
        lists:foldl(
            fun(Job, Acc) ->
                Ref = make_ref(),
                StartedMs = erlang:monotonic_time(millisecond),
                {Pid, MRef} =
                    spawn_monitor(fun() ->
                        Res = zap_job(NsecKey, Job, JobTimeoutMs),
                        Parent ! {zap_result, Ref, Job, Res}
                    end),
                ?LOG_INFO(
                    "spawned zap job ref=~p pid=~p event=~p npub=~p amount=~p timeout_ms=~p",
                    [
                        Ref,
                        Pid,
                        maps:get(id, Job, <<>>),
                        maps:get(npub_key, Job, <<>>),
                        maps:get(amount, Job, 0),
                        JobTimeoutMs
                    ]
                ),
                maps:put(
                    Ref,
                    #{
                        job => Job,
                        pid => Pid,
                        mref => MRef,
                        started_ms => StartedMs,
                        timeout_ms => JobTimeoutMs
                    },
                    Acc
                )
            end,
            #{},
            Jobs
        ),

    collect_and_record_results(
        Config,
        Pending0,
        Totals0,
        Spent0,
        [],
        [],
        Context,
        length(Jobs),
        0
    ).

collect_and_record_results(
    Config,
    Pending,
    Totals0,
    Spent0,
    ReceiptsAcc,
    ErrorsAcc,
    _Context,
    Total,
    _Done
) when map_size(Pending) =:= 0 ->
    emit_progress(
        Config,
        damage_utils:strf(
            "summary zap_ok=~p onchain_ok=~p failed=~p total=~p",
            [
                count_zap_successes(ReceiptsAcc),
                count_onchain_successes(ReceiptsAcc),
                length(ErrorsAcc),
                Total
            ]
        )
    ),
    {lists:reverse(ReceiptsAcc), Totals0, Spent0, lists:reverse(ErrorsAcc)};
collect_and_record_results(
    Config,
    Pending0,
    Totals0,
    Spent0,
    ReceiptsAcc,
    ErrorsAcc,
    Context,
    Total,
    Done
) ->
    receive
        {zap_result, Ref, Job, Res} ->
            Meta = maps:get(Ref, Pending0, #{}),
            StartedMs = maps:get(started_ms, Meta, erlang:monotonic_time(millisecond)),
            ElapsedMs = erlang:monotonic_time(millisecond) - StartedMs,
            ?LOG_WARNING(
                "zap_result ref=~p event=~p npub=~p amount=~p elapsed_ms=~p res=~p",
                [
                    Ref,
                    maps:get(id, Job, <<>>),
                    maps:get(npub_key, Job, <<>>),
                    maps:get(amount, Job, 0),
                    ElapsedMs,
                    summarize_result(Res)
                ]
            ),
            Pending1 = maps:remove(Ref, Pending0),
            {Receipt, Totals1, Spent1, Errors1} =
                apply_zap_result(
                    Config,
                    Context,
                    Done + 1,
                    Total,
                    Job,
                    Res,
                    Totals0,
                    Spent0,
                    ErrorsAcc
                ),
            collect_and_record_results(
                Config,
                Pending1,
                Totals1,
                Spent1,
                [Receipt | ReceiptsAcc],
                Errors1,
                Context,
                Total,
                Done + 1
            );
        {'DOWN', MRef, process, Pid, Reason} ->
            ?LOG_WARNING("zap job down pid=~p mref=~p reason=~p", [Pid, MRef, Reason]),
            Pending1 = remove_stale_monitor_ref(Pending0, MRef),
            collect_and_record_results(
                Config,
                Pending1,
                Totals0,
                Spent0,
                ReceiptsAcc,
                ErrorsAcc,
                Context,
                Total,
                Done
            )
    after ?DEFAULT_PROGRESS_HEARTBEAT_MS ->
        log_pending_jobs(Pending0),
        emit_pending_preview(Config, Pending0),
        {Pending1, Receipts1, Errors1, Done1} =
            maybe_expire_jobs(
                Config,
                Pending0,
                ReceiptsAcc,
                ErrorsAcc,
                Done,
                Total,
                Totals0,
                Spent0
            ),
        emit_progress(
            Config,
            damage_utils:strf(
                "progress completed=~p pending=~p",
                [Done1, map_size(Pending1)]
            )
        ),
        collect_and_record_results(
            Config,
            Pending1,
            Totals0,
            Spent0,
            Receipts1,
            Errors1,
            Context,
            Total,
            Done1
        )
    end.

apply_zap_result(Config, Context, Index, Total, Job, Res, Totals0, Spent0, Errors0) ->
    Id = maps:get(id, Job, <<>>),
    Author = maps:get(author, Job, <<>>),
    NpubKey = maps:get(npub_key, Job, <<>>),
    Amount = maps:get(amount, Job, 0),

    case Res of
        {ok, Receipt0} when Amount > 0, Id =/= <<>>, NpubKey =/= <<>> ->
            EventTotal1 = maps:get(Id, Totals0, 0) + Amount,
            NpubSpent1 = maps:get(NpubKey, Spent0, 0) + Amount,
            Totals1 = maps:put(Id, EventTotal1, Totals0),
            Spent1 = maps:put(NpubKey, NpubSpent1, Spent0),

            Receipt1 = #{
                id => Id,
                author => Author,
                npub_key => NpubKey,
                amount => Amount,
                event_total => EventTotal1,
                npub_spent => NpubSpent1,
                receipt => Receipt0
            },

            emit_progress(
                Config,
                progress_line(ok, Index, Total, Receipt1)
            ),

            case valid_receipt_for_onchain(Receipt1) of
                true ->
                    OnchainStartMs = erlang:monotonic_time(millisecond),
                    ?LOG_WARNING(
                        "record_zap start event=~p npub=~p sats=~p",
                        [Id, NpubKey, Amount]
                    ),
                    case catch maybe_contract_record_zap(Context, NpubKey, Id, Amount) of
                        #{"tx_hash" := TxHash} when is_binary(TxHash), TxHash =/= <<>> ->
                            OnchainEndMs = erlang:monotonic_time(millisecond),
                            ?LOG_WARNING(
                                "record_zap ok event=~p tx=~p onchain_ms=~p",
                                [Id, TxHash, OnchainEndMs - OnchainStartMs]
                            ),
                            Receipt2 = maps:put(tx_hash, TxHash, Receipt1),
                            emit_progress(
                                Config,
                                progress_line(onchain_ok, Index, Total, Receipt2)
                            ),
                            {Receipt2, Totals1, Spent1, Errors0};
                        #{"tx_hash" := <<>>} ->
                            OnchainEndMs = erlang:monotonic_time(millisecond),
                            ?LOG_ERROR(
                                "record_zap failed event=~p onchain_ms=~p err=empty_tx_hash",
                                [Id, OnchainEndMs - OnchainStartMs]
                            ),
                            Receipt2 =
                                maps:put(
                                    onchain_error,
                                    <<"empty tx hash">>,
                                    maps:put(tx_hash, <<>>, Receipt1)
                                ),
                            emit_progress(
                                Config,
                                progress_line(onchain_failed, Index, Total, Receipt2)
                            ),
                            {
                                Receipt2,
                                Totals1,
                                Spent1,
                                [{onchain_failed, Id, NpubKey, empty_tx_hash} | Errors0]
                            };
                        {error, empty_transaction} ->
                            OnchainEndMs = erlang:monotonic_time(millisecond),
                            ?LOG_ERROR(
                                "record_zap skipped event=~p onchain_ms=~p err=empty_transaction",
                                [Id, OnchainEndMs - OnchainStartMs]
                            ),
                            Receipt2 =
                                maps:put(
                                    onchain_error,
                                    <<"empty transaction">>,
                                    maps:put(tx_hash, <<>>, Receipt1)
                                ),
                            emit_progress(
                                Config,
                                progress_line(skipped, Index, Total, Receipt2)
                            ),
                            {
                                Receipt2,
                                Totals1,
                                Spent1,
                                [{zap_skipped, Id, NpubKey, empty_transaction} | Errors0]
                            };
                        Other ->
                            OnchainEndMs = erlang:monotonic_time(millisecond),
                            ?LOG_ERROR(
                                "record_zap failed event=~p onchain_ms=~p err=~p",
                                [Id, OnchainEndMs - OnchainStartMs, Other]
                            ),
                            Receipt2 =
                                maps:put(
                                    onchain_error,
                                    to_bin(Other),
                                    maps:put(tx_hash, <<>>, Receipt1)
                                ),
                            emit_progress(
                                Config,
                                progress_line(onchain_failed, Index, Total, Receipt2)
                            ),
                            {
                                Receipt2,
                                Totals1,
                                Spent1,
                                [{onchain_failed, Id, NpubKey, Other} | Errors0]
                            }
                    end;
                false ->
                    Receipt2 =
                        maps:put(
                            onchain_error,
                            <<"skipped empty transaction">>,
                            maps:put(tx_hash, <<>>, Receipt1)
                        ),
                    emit_progress(
                        Config,
                        progress_line(skipped, Index, Total, Receipt2)
                    ),
                    {
                        Receipt2,
                        Totals1,
                        Spent1,
                        [{zap_skipped, Id, NpubKey, empty_transaction} | Errors0]
                    }
            end;
        {ok, _Receipt0} ->
            Receipt1 = #{
                id => Id,
                author => Author,
                npub_key => NpubKey,
                amount => 0,
                event_total => maps:get(Id, Totals0, 0),
                npub_spent => maps:get(NpubKey, Spent0, 0),
                receipt => {error, invalid_zap_result},
                tx_hash => <<>>
            },
            emit_progress(
                Config,
                progress_line(skipped, Index, Total, Receipt1)
            ),
            {
                Receipt1,
                Totals0,
                Spent0,
                [{zap_skipped, Id, NpubKey, invalid_zap_result} | Errors0]
            };
        {error, Why} ->
            Receipt1 = #{
                id => Id,
                author => Author,
                npub_key => NpubKey,
                amount => 0,
                event_total => maps:get(Id, Totals0, 0),
                npub_spent => maps:get(NpubKey, Spent0, 0),
                receipt => {error, Why},
                tx_hash => <<>>
            },
            emit_progress(
                Config,
                progress_line(failed, Index, Total, Receipt1)
            ),
            {
                Receipt1,
                Totals0,
                Spent0,
                [{zap_failed, Id, NpubKey, Why} | Errors0]
            }
    end.

maybe_expire_jobs(Config, Pending0, ReceiptsAcc, ErrorsAcc, Done0, Total, Totals0, Spent0) ->
    NowMs = erlang:monotonic_time(millisecond),

    maps:fold(
        fun(Ref, Meta, {PendingAcc, ReceiptsAcc0, ErrorsAcc0, DoneAcc}) ->
            StartedMs = maps:get(started_ms, Meta, NowMs),
            TimeoutMs = maps:get(timeout_ms, Meta, ?DEFAULT_ZAP_JOB_TIMEOUT_MS),
            Job = maps:get(job, Meta, #{}),
            Pid = maps:get(pid, Meta, undefined),

            case NowMs - StartedMs >= TimeoutMs of
                true ->
                    kill_if_alive(Pid),
                    Id = maps:get(id, Job, <<>>),
                    Author = maps:get(author, Job, <<>>),
                    NpubKey = maps:get(npub_key, Job, <<>>),
                    Receipt = #{
                        id => Id,
                        author => Author,
                        npub_key => NpubKey,
                        amount => 0,
                        event_total => maps:get(Id, Totals0, 0),
                        npub_spent => maps:get(NpubKey, Spent0, 0),
                        receipt => {error, timeout},
                        tx_hash => <<>>
                    },
                    emit_progress(
                        Config,
                        progress_line(failed, DoneAcc + 1, Total, Receipt)
                    ),
                    {
                        PendingAcc,
                        [Receipt | ReceiptsAcc0],
                        [{zap_failed, Id, NpubKey, timeout} | ErrorsAcc0],
                        DoneAcc + 1
                    };
                false ->
                    {
                        maps:put(Ref, Meta, PendingAcc),
                        ReceiptsAcc0,
                        ErrorsAcc0,
                        DoneAcc
                    }
            end
        end,
        {#{}, ReceiptsAcc, ErrorsAcc, Done0},
        Pending0
    ).

log_pending_jobs(Pending) ->
    NowMs = erlang:monotonic_time(millisecond),
    maps:fold(
        fun(Ref, Meta, ok) ->
            Job = maps:get(job, Meta, #{}),
            StartedMs = maps:get(started_ms, Meta, NowMs),
            TimeoutMs = maps:get(timeout_ms, Meta, ?DEFAULT_ZAP_JOB_TIMEOUT_MS),
            AgeMs = NowMs - StartedMs,
            ?LOG_WARNING(
                "pending zap ref=~p pid=~p event=~p npub=~p amount=~p age_ms=~p timeout_ms=~p",
                [
                    Ref,
                    maps:get(pid, Meta, undefined),
                    maps:get(id, Job, <<>>),
                    maps:get(npub_key, Job, <<>>),
                    maps:get(amount, Job, 0),
                    AgeMs,
                    TimeoutMs
                ]
            ),
            ok
        end,
        ok,
        Pending
    ).

emit_pending_preview(Config, Pending) ->
    Preview =
        lists:sublist(
            [
                damage_utils:strf(
                    "~s:~pms",
                    [
                        to_list(maps:get(id, maps:get(job, Meta, #{}), <<>>)),
                        erlang:monotonic_time(millisecond) - maps:get(started_ms, Meta, 0)
                    ]
                )
             || {_Ref, Meta} <- maps:to_list(Pending)
            ],
            5
        ),
    emit_progress(
        Config,
        damage_utils:strf("pending preview ~p", [Preview])
    ).

remove_stale_monitor_ref(Pending0, MRef) ->
    maps:filter(
        fun(_Ref, Meta) ->
            maps:get(mref, Meta, undefined) =/= MRef
        end,
        Pending0
    ).

kill_if_alive(undefined) ->
    ok;
kill_if_alive(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true ->
            exit(Pid, kill),
            ok;
        false ->
            ok
    end;
kill_if_alive(_) ->
    ok.

zap_job(NsecKey, #{id := Id, author := Author, amount := Amount} = Job, TimeoutMs) ->
    StartMs = erlang:monotonic_time(millisecond),
    ?LOG_WARNING(
        "zap_job start event=~p npub=~p amount=~p timeout_ms=~p author_present=~p",
        [
            Id,
            maps:get(npub_key, Job, <<>>),
            Amount,
            TimeoutMs,
            Author =/= <<>>
        ]
    ),
    try
        Res =
            poolboy:transaction(
                ?ZAP_POOL,
                fun(_Worker) ->
                    PoolEnterMs = erlang:monotonic_time(millisecond),
                    ?LOG_INFO(
                        "zap_job pool_acquired event=~p waited_ms=~p",
                        [Id, PoolEnterMs - StartMs]
                    ),
                    CallStartMs = erlang:monotonic_time(millisecond),
                    CallRes =
                        case Author of
                            <<>> -> {ok, damage_nostr:zap_note(NsecKey, Id, Amount)};
                            _ -> {ok, damage_nostr:zap_note(NsecKey, Id, Author, Amount)}
                        end,
                    CallEndMs = erlang:monotonic_time(millisecond),
                    ?LOG_WARNING(
                        "zap_job zap_note_done event=~p call_ms=~p result=~p",
                        [Id, CallEndMs - CallStartMs, summarize_result(CallRes)]
                    ),
                    CallRes
                end,
                TimeoutMs
            ),
        EndMs1 = erlang:monotonic_time(millisecond),
        ?LOG_WARNING(
            "zap_job end event=~p total_ms=~p result=~p",
            [Id, EndMs1 - StartMs, summarize_result(Res)]
        ),
        Res
    catch
        exit:{timeout, _} ->
            EndMs2 = erlang:monotonic_time(millisecond),
            ?LOG_ERROR(
                "zap_job timeout event=~p total_ms=~p timeout_ms=~p",
                [Id, EndMs2 - StartMs, TimeoutMs]
            ),
            {error, timeout};
        exit:timeout ->
            EndMs3 = erlang:monotonic_time(millisecond),
            ?LOG_ERROR(
                "zap_job timeout event=~p total_ms=~p timeout_ms=~p",
                [Id, EndMs3 - StartMs, TimeoutMs]
            ),
            {error, timeout};
        C:R:S ->
            EndMs4 = erlang:monotonic_time(millisecond),
            ?LOG_ERROR(
                "zap_job crash event=~p total_ms=~p class=~p reason=~p stack=~p",
                [Id, EndMs4 - StartMs, C, R, S]
            ),
            {error, {C, R}}
    end.

summarize_result({ok, _}) -> ok;
summarize_result({error, Why}) -> {error, Why};
summarize_result(Other) -> Other.

ensure_zap_pool() ->
    case whereis(?ZAP_POOL) of
        undefined ->
            Size = application:get_env(damage, nostr_zap_pool_size, ?DEFAULT_ZAP_POOL_SIZE),
            Overflow = application:get_env(
                damage, nostr_zap_pool_overflow, ?DEFAULT_ZAP_POOL_OVERFLOW
            ),
            PoolArgs = [
                {name, {local, ?ZAP_POOL}},
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

emit_progress(Config, Msg) ->
    ?LOG_INFO("~s", [Msg]),
    catch formatter:format(
        Config,
        print,
        {<<"Then">>, 0, ["nostr payout"], to_bin(Msg), #{}, success}
    ),
    ok.

progress_line(ok, Index, Total, R) ->
    damage_utils:strf(
        "zap ok ~p/~p event=~s sats=~p event_total=~p npub_spent=~p",
        [
            Index,
            Total,
            to_list(maps:get(id, R, <<>>)),
            maps:get(amount, R, 0),
            maps:get(event_total, R, 0),
            maps:get(npub_spent, R, 0)
        ]
    );
progress_line(onchain_ok, Index, Total, R) ->
    damage_utils:strf(
        "onchain ok ~p/~p event=~s tx=~s event_total=~p npub_spent=~p",
        [
            Index,
            Total,
            to_list(maps:get(id, R, <<>>)),
            to_list(maps:get(tx_hash, R, <<>>)),
            maps:get(event_total, R, 0),
            maps:get(npub_spent, R, 0)
        ]
    );
progress_line(onchain_failed, Index, Total, R) ->
    damage_utils:strf(
        "onchain failed ~p/~p event=~s err=~s event_total=~p npub_spent=~p",
        [
            Index,
            Total,
            to_list(maps:get(id, R, <<>>)),
            to_list(maps:get(onchain_error, R, <<"unknown">>)),
            maps:get(event_total, R, 0),
            maps:get(npub_spent, R, 0)
        ]
    );
progress_line(failed, Index, Total, R) ->
    damage_utils:strf(
        "zap failed ~p/~p event=~s err=~p event_total=~p npub_spent=~p",
        [
            Index,
            Total,
            to_list(maps:get(id, R, <<>>)),
            maps:get(receipt, R, {error, unknown}),
            maps:get(event_total, R, 0),
            maps:get(npub_spent, R, 0)
        ]
    );
progress_line(skipped, Index, Total, R) ->
    damage_utils:strf(
        "zap skipped ~p/~p event=~s reason=~s event_total=~p npub_spent=~p",
        [
            Index,
            Total,
            to_list(maps:get(id, R, <<>>)),
            to_list(maps:get(onchain_error, R, <<"invalid_zap_result">>)),
            maps:get(event_total, R, 0),
            maps:get(npub_spent, R, 0)
        ]
    ).

valid_receipt_for_onchain(#{id := Id, npub_key := NpubKey, amount := Amount}) when
    is_binary(Id),
    Id =/= <<>>,
    is_binary(NpubKey),
    NpubKey =/= <<>>,
    is_integer(Amount),
    Amount > 0
->
    true;
valid_receipt_for_onchain(_) ->
    false.

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

normalize_npub(Npub0) ->
    Npub = to_bin(Npub0),
    case Npub of
        <<"npub1", _/binary>> -> to_bin(damage_nostr:decode_npub(Npub));
        _ -> Npub
    end.

to_lower_hex64(Bin) when is_binary(Bin) ->
    case Bin of
        <<_:64/binary>> -> lower_hex(Bin);
        _ -> lower_hex(binary:encode_hex(Bin))
    end.

lower_hex(B) ->
    <<<<(to_lower(C))>> || <<C>> <= B>>.

to_lower(C) when C >= $A, C =< $F -> C + 32;
to_lower(C) -> C.

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

map_get(<<>>, _K, Default) ->
    Default;
map_get(M, K, Default) when is_map(M) ->
    maps:get(K, M, Default);
map_get(_, _K, Default) ->
    Default.

map_get_atom_or_bin(<<>>, _, DefaultAtom) ->
    DefaultAtom;
map_get_atom_or_bin(M, K, DefaultAtom) when is_map(M) ->
    case maps:get(K, M, DefaultAtom) of
        A when is_atom(A) -> A;
        B when is_binary(B) -> binary_to_atom(B, utf8);
        L when is_list(L) -> list_to_atom(L);
        _ -> DefaultAtom
    end;
map_get_atom_or_bin(_, _, DefaultAtom) ->
    DefaultAtom.

map_get_bool(<<>>, _K, Default) ->
    Default;
map_get_bool(M, K, Default) when is_map(M) ->
    case maps:get(K, M, Default) of
        true -> true;
        false -> false;
        <<"true">> -> true;
        <<"false">> -> false;
        "true" -> true;
        "false" -> false;
        _ -> Default
    end;
map_get_bool(_, _K, Default) ->
    Default.

count_zap_successes(Receipts) ->
    length([R || R <- Receipts, maps:get(amount, R, 0) > 0]).

count_onchain_successes(Receipts) ->
    length([R || R <- Receipts, maps:get(tx_hash, R, <<>>) =/= <<>>]).

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

maybe_contract_record_zap(_Context, NpubKey, EventId, Sats) when
    NpubKey =:= <<>> orelse EventId =:= <<>> orelse Sats =< 0
->
    {error, empty_transaction};
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

npub_to_key(Npub0) ->
    NpubB = to_bin(Npub0),
    case NpubB of
        <<"npub1", _/binary>> ->
            to_lower_hex64(to_bin(damage_nostr:decode_npub(NpubB)));
        _ ->
            to_lower_hex64(NpubB)
    end.

parse_int_result(I) when is_integer(I) -> {ok, I};
parse_int_result(#{"result" := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{result := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{"value" := I}) when is_integer(I) -> {ok, I};
parse_int_result(#{value := I}) when is_integer(I) -> {ok, I};
parse_int_result(Other) -> {error, {unexpected_int_result, Other}}.

test() ->
    ok.

deploy_contract(AeAccount) when is_list(AeAccount) ->
    deploy_contract(to_bin(AeAccount));
deploy_contract(AeAccount) ->
    #{public_key := AeAccount, private_key := PrivateKey} =
        identity_server:get_account(AeAccount),
    Keypair = #{public_key => AeAccount, private_key => PrivateKey},
    case account_registry:get_contract(Keypair, "nostr_zap_registry") of
        {ok, ContractId} ->
            ContractId;
        _ ->
            #{"contract_id" := ContractId} = damage_ae:contract_deploy(
                contract_path(damage, "contracts/nostr_zap_registry.aes"), [AeAccount]
            ),
            ?LOG_DEBUG("nostr_zap_registry ~p ~p", [Keypair, ContractId]),
            account_registry:register_contract(Keypair, "nostr_zap_registry", ContractId)
    end.
