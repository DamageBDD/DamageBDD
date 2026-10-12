%%%-------------------------------------------------------------------
%%% Durable materialized analytics read model.
%%%
%%% Raw AEMDW/IPFS evidence is normalised once and retained locally. Dashboard
%%% reads aggregate ETS buckets instead of re-scanning chain history. DETS keeps
%%% canonical run facts and the chain checkpoint across restarts.
%%%-------------------------------------------------------------------
-module(damage_analytics_store).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    observe_run/1,
    settle_run/3,
    upsert_chain_run/1,
    summary/2,
    status/1,
    checkpoint/0,
    set_checkpoint/1,
    all_runs/0,
    pending_meta/1,
    set_ecai_projection/3,
    reproject_ecai/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(RUNS_TAB, damage_analytics_runs).
-define(DAYS_TAB, damage_analytics_days).
-define(RECENT_TAB, damage_analytics_recent).
-define(META_RETRY_TAB, damage_analytics_meta_retry).
-define(DETS, damage_analytics_dets).
-define(SCHEMA, 1).
-define(DEFAULT_RECENT, 12).
-define(MAX_RECENT, 50).
-define(DURATION_BOUNDS, [100,250,500,1000,2000,5000,10000,30000,60000,120000,300000]).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

observe_run(Run) when is_map(Run) ->
    cast_if_started({observe_run, Run});
observe_run(_) -> ok.

settle_run(Run, TxHash, Settlement) when is_map(Run) ->
    cast_if_started({settle_run, Run, TxHash, Settlement});
settle_run(_, _, _) -> ok.

upsert_chain_run(Run) when is_map(Run) ->
    call_if_started({upsert_chain_run, Run}, {error, not_started});
upsert_chain_run(_) -> {error, invalid_run}.

summary(Account, Days) ->
    call_if_started({summary, Account, Days}, empty_summary(Account, normalize_days(Days))).

status(Account) ->
    call_if_started({status, Account}, #{status => unavailable}).

checkpoint() ->
    call_if_started(checkpoint, #{}).

set_checkpoint(Checkpoint) when is_map(Checkpoint) ->
    call_if_started({set_checkpoint, Checkpoint}, ok);
set_checkpoint(_) -> ok.

all_runs() ->
    call_if_started(all_runs, []).

pending_meta(Limit) when is_integer(Limit), Limit > 0 ->
    call_if_started({pending_meta, erlang:min(100, Limit)}, []);
pending_meta(_) -> [].

set_ecai_projection(ReportCid, ProjectionHash, Projection)
    when is_binary(ReportCid), is_binary(ProjectionHash), is_map(Projection) ->
    cast_if_started({ecai_projection, ReportCid, ProjectionHash, Projection});
set_ecai_projection(_, _, _) -> ok.

reproject_ecai() ->
    cast_if_started(reproject_ecai).

cast_if_started(Message) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:cast(?SERVER, Message)
    end.

call_if_started(Message, Default) ->
    case whereis(?SERVER) of
        undefined -> Default;
        _ ->
            try gen_server:call(?SERVER, Message, 15000)
            catch _:_ -> Default end
    end.

init([]) ->
    create_tables(),
    {Dets, Checkpoint} = open_and_load(),
    {ok, #{
        dets => Dets,
        checkpoint => Checkpoint,
        version => 1,
        last_updated_ms => now_ms()
    }}.

handle_call({upsert_chain_run, Run0}, _From, State0) ->
    case normalize_chain_input(Run0) of
        {ok, Run} ->
            {State, Stored} = upsert(Run, State0),
            {reply, {ok, Stored}, State};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({summary, Account0, Days0}, _From, State) ->
    Account = account_bin(Account0),
    Days = normalize_days(Days0),
    {reply, build_summary(Account, Days, State), State};
handle_call({status, Account0}, _From, State) ->
    Account = account_bin(Account0),
    Runs = account_run_count(Account),
    {reply, #{
        status => ok,
        account => Account,
        cached_runs => Runs,
        total_cached_runs => ets:info(?RUNS_TAB, size),
        unscoped_runs => unscoped_run_count(),
        version => maps:get(version, State),
        checkpoint => maps:get(checkpoint, State, #{}),
        persistent => maps:get(dets, State, undefined) =/= undefined,
        last_updated_ms => maps:get(last_updated_ms, State, 0),
        ecai => damage_analytics_ecai:availability()
    }, State};
handle_call(checkpoint, _From, State) ->
    {reply, maps:get(checkpoint, State, #{}), State};
handle_call({set_checkpoint, Checkpoint}, _From, State0) ->
    maybe_dets_insert(maps:get(dets, State0, undefined), {checkpoint, Checkpoint}),
    State = bump(State0#{checkpoint => Checkpoint}),
    {reply, ok, State};
handle_call(all_runs, _From, State) ->
    {reply, [Run || {_Cid, Run} <- ets:tab2list(?RUNS_TAB)], State};
handle_call({pending_meta, Limit}, _From, State) ->
    {reply, pending_meta_runs(Limit, now_ms()), State};
handle_call(_Other, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({observe_run, Run0}, State0) ->
    case damage_analytics_model:normalize_local_run(Run0) of
        {ok, Run} ->
            {State, _} = upsert(Run, State0),
            {noreply, State};
        {error, Why} ->
            ?LOG_DEBUG("analytics ignored local run reason=~p", [Why]),
            {noreply, State0}
    end;
handle_cast({settle_run, Run0, TxHash0, Settlement0}, State0) ->
    case damage_analytics_model:normalize_local_run(Run0) of
        {ok, Run1} ->
            TxHash = text(TxHash0),
            Settlement = normalize_settlement(Settlement0),
            Evidence0 = maps:get(evidence, Run1, #{}),
            Confirmed = Settlement =:= chain_confirmed,
            Run = Run1#{
                tx_hash => TxHash,
                settlement_status => Settlement,
                evidence => maps:merge(Evidence0, #{chain_confirmed => Confirmed})
            },
            {State, _} = upsert(Run, State0),
            {noreply, State};
        _ -> {noreply, State0}
    end;
handle_cast({ecai_projection, ReportCid, ProjectionHash, Projection}, State0) ->
    case ets:lookup(?RUNS_TAB, ReportCid) of
        [{ReportCid, Current}] ->
            case maps:get(ecai_projection_hash, Current, undefined) =:= ProjectionHash of
                true ->
                    Run = Current#{ecai => Projection},
                    {State, _} = upsert(Run, State0, false),
                    {noreply, State};
                false ->
                    %% A newer run version is already queued/projected.
                    {noreply, State0}
            end;
        [] -> {noreply, State0}
    end;
handle_cast(reproject_ecai, State) ->
    %% Queue only; projection is isolated in damage_analytics_ecai_worker so the
    %% read model remains available even when ECAI is slow or unavailable.
    lists:foreach(fun({ReportCid, Run}) ->
        Hash = ecai_projection_hash(Run),
        damage_analytics_ecai_worker:project(ReportCid, Run, Hash)
    end, ets:tab2list(?RUNS_TAB)),
    {noreply, State};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(dets, State, undefined) of
        undefined -> ok;
        Dets ->
            _ = try dets:sync(Dets) catch _:_ -> ok end,
            _ = try dets:close(Dets) catch _:_ -> ok end,
            ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ===================================================================
%% Persistence + canonical upsert
%% ===================================================================

create_tables() ->
    ensure_table(?RUNS_TAB, [named_table, protected, set, {read_concurrency, true}]),
    ensure_table(?DAYS_TAB, [named_table, protected, set, {read_concurrency, true}]),
    ensure_table(?RECENT_TAB, [named_table, protected, ordered_set, {read_concurrency, true}]),
    ensure_table(?META_RETRY_TAB, [named_table, protected, ordered_set, {read_concurrency, true}]),
    ok.

ensure_table(Name, Opts) ->
    case ets:info(Name) of
        undefined -> ets:new(Name, Opts);
        _ -> Name
    end.

open_and_load() ->
    Path = store_path(),
    case filelib:ensure_dir(Path) of
        ok ->
            case dets:open_file(?DETS, [{file, Path}, {type, set}, {auto_save, 30000}]) of
                {ok, Dets} ->
                    load_dets(Dets),
                    {Dets, load_checkpoint(Dets)};
                {error, Reason} ->
                    ?LOG_WARNING("analytics DETS unavailable path=~p reason=~p; using ETS only", [Path, Reason]),
                    {undefined, #{}}
            end;
        {error, Reason} ->
            ?LOG_WARNING("analytics data directory unavailable path=~p reason=~p; using ETS only", [Path, Reason]),
            {undefined, #{}}
    end.

store_path() ->
    case application:get_env(damage, analytics_store_path) of
        {ok, P} when is_binary(P) -> binary_to_list(P);
        {ok, P} when is_list(P) -> P;
        _ ->
            Root0 = application:get_env(damage, runtime_data_dir, "/var/lib/damage"),
            Root = case Root0 of B when is_binary(B) -> binary_to_list(B); L -> L end,
            filename:join([Root, "analytics", "analytics.dets"])
    end.

load_dets(Dets) ->
    _ = dets:foldl(fun
        ({{run, ReportCid}, Run}, Acc) when is_binary(ReportCid), is_map(Run) ->
            put_derived(undefined, Run),
            Acc;
        (_, Acc) -> Acc
    end, ok, Dets),
    ok.

load_checkpoint(Dets) ->
    case dets:lookup(Dets, checkpoint) of
        [{checkpoint, C}] when is_map(C) -> C;
        _ -> #{}
    end.

normalize_chain_input(Run) ->
    case maps:get(report_cid, Run, <<>>) of
        Cid when is_binary(Cid), Cid =/= <<>> -> {ok, Run};
        _ -> {error, missing_report_cid}
    end.

upsert(Run, State) -> upsert(Run, State, true).

upsert(Run0, State0, ProjectEcai) ->
    ReportCid = maps:get(report_cid, Run0),
    Old = case ets:lookup(?RUNS_TAB, ReportCid) of
        [{ReportCid, Existing}] -> Existing;
        [] -> #{}
    end,
    Merged0 = damage_analytics_model:merge_run(Old, Run0),
    ProjectionHash = ecai_projection_hash(Merged0),
    OldProjectionHash = maps:get(ecai_projection_hash, Old, undefined),
    NeedsProjection = ProjectEcai andalso ProjectionHash =/= OldProjectionHash,
    Ecai0 = maps:get(ecai, Merged0, maps:get(ecai, Old, #{})),
    Ecai = case {NeedsProjection, map_size(Ecai0)} of
        {true, 0} -> #{status => pending, search_indexed => false, relation_count => 0,
                       curve_feature_count => 0, geometry_status => unavailable};
        _ -> Ecai0
    end,
    Merged = Merged0#{ecai => Ecai, ecai_projection_hash => ProjectionHash,
                      analytics_schema => ?SCHEMA},
    remove_derived(Old),
    put_derived(Old, Merged),
    maybe_dets_insert(maps:get(dets, State0, undefined), {{run, ReportCid}, Merged}),
    case NeedsProjection of
        true -> damage_analytics_ecai_worker:project(ReportCid, Merged0, ProjectionHash);
        false -> ok
    end,
    {bump(State0), Merged}.


ecai_projection_hash(Run) ->
    Fields = [report_cid, feature_cid, account, node, tx_hash, status,
              feature_title, result_summary, failure_signature],
    crypto:hash(sha256, term_to_binary(maps:with(Fields, Run), [deterministic])).

maybe_dets_insert(undefined, _Object) -> ok;
maybe_dets_insert(Dets, Object) ->
    case dets:insert(Dets, Object) of
        ok -> ok;
        {error, Why} -> ?LOG_WARNING("analytics DETS insert failed reason=~p", [Why]), ok
    end.

bump(State) -> State#{version => maps:get(version, State, 0) + 1, last_updated_ms => now_ms()}.

%% ===================================================================
%% Derived ETS projections
%% ===================================================================

put_derived(_Old, Run) ->
    ReportCid = maps:get(report_cid, Run, <<>>),
    true = ets:insert(?RUNS_TAB, {ReportCid, Run}),
    case day_key(Run) of
        undefined -> ok;
        {Account, _Day} = Key ->
            Bucket0 = day_bucket(Key),
            Bucket = bucket_add(Bucket0, Run),
            true = ets:insert(?DAYS_TAB, {Key, Bucket}),
            RecentKey = recent_key(Account, Run),
            true = ets:insert(?RECENT_TAB, {RecentKey, ReportCid})
    end,
    put_meta_retry(Run),
    ok.

remove_derived(Old) when map_size(Old) =:= 0 -> ok;
remove_derived(Old) ->
    ReportCid = maps:get(report_cid, Old, <<>>),
    case day_key(Old) of
        undefined -> ok;
        {Account, _Day} = Key ->
            Bucket0 = day_bucket(Key),
            Bucket = bucket_remove(Bucket0, Old),
            case maps:get(total, Bucket, 0) =< 0 of
                true -> ets:delete(?DAYS_TAB, Key);
                false -> true = ets:insert(?DAYS_TAB, {Key, Bucket})
            end,
            ets:delete(?RECENT_TAB, recent_key(Account, Old))
    end,
    remove_meta_retry(Old),
    case ReportCid of <<>> -> ok; _ -> ets:delete(?RUNS_TAB, ReportCid) end,
    ok.

recent_key(Account, Run) ->
    Created = case maps:get(created_ms, Run, 0) of 0 -> maps:get(completed_ms, Run, 0); V -> V end,
    {Account, -Created, maps:get(report_cid, Run, <<>>)}.

put_meta_retry(Run) ->
    Evidence = maps:get(evidence, Run, #{}),
    ReportCid = maps:get(report_cid, Run, <<>>),
    ReportLoaded = maps:get(report_meta, Evidence, false) orelse maps:get(legacy_report, Evidence, false),
    case {ReportLoaded, ReportCid} of
        {true, _} -> ok;
        {_, <<>>} -> ok;
        _ ->
            RetryAfter = integer_value(maps:get(meta_retry_after_ms, Run, 0)),
            true = ets:insert(?META_RETRY_TAB, {{RetryAfter, ReportCid}, ReportCid}),
            ok
    end.

remove_meta_retry(Run) ->
    ReportCid = maps:get(report_cid, Run, <<>>),
    case ReportCid of
        <<>> -> ok;
        _ ->
            RetryAfter = integer_value(maps:get(meta_retry_after_ms, Run, 0)),
            ets:delete(?META_RETRY_TAB, {RetryAfter, ReportCid}),
            ok
    end.

pending_meta_runs(Limit, Now) ->
    pending_meta_runs(ets:first(?META_RETRY_TAB), Limit, Now, []).

pending_meta_runs('$end_of_table', _Limit, _Now, Acc) -> lists:reverse(Acc);
pending_meta_runs(_Key, 0, _Now, Acc) -> lists:reverse(Acc);
pending_meta_runs({RetryAfter, _ReportCid}, _Limit, Now, Acc) when RetryAfter > Now ->
    lists:reverse(Acc);
pending_meta_runs({RetryAfter, ReportCid} = Key, Limit, Now, Acc) ->
    Next = ets:next(?META_RETRY_TAB, Key),
    case ets:lookup(?RUNS_TAB, ReportCid) of
        [{ReportCid, Run}] -> pending_meta_runs(Next, Limit - 1, Now, [Run | Acc]);
        [] ->
            ets:delete(?META_RETRY_TAB, {RetryAfter, ReportCid}),
            pending_meta_runs(Next, Limit, Now, Acc)
    end.

day_key(Run) ->
    Account = maps:get(account, Run, <<>>),
    Ms = case maps:get(created_ms, Run, 0) of 0 -> maps:get(completed_ms, Run, 0); V -> V end,
    case {Account, day_bin(Ms)} of
        {<<>>, _} -> undefined;
        {_, <<>>} -> undefined;
        {A, D} -> {A, D}
    end.

day_bucket(Key) ->
    case ets:lookup(?DAYS_TAB, Key) of
        [{Key, B}] -> B;
        [] -> empty_bucket()
    end.

empty_bucket() -> #{
    total => 0, passed => 0, failed => 0, unknown => 0,
    duration_count => 0, duration_sum_ms => 0, duration_hist => empty_hist(), max_duration_ms => 0,
    features => #{}, nodes => #{}, failure_signatures => #{},
    chain_confirmed => 0, evidence_loaded => 0,
    ecai_indexed => 0, ecai_relations => 0, ecai_curve_features => 0
}.

empty_hist() -> lists:duplicate(length(?DURATION_BOUNDS) + 1, 0).

bucket_add(B0, Run) -> bucket_delta(B0, Run, 1).
bucket_remove(B0, Run) -> bucket_delta(B0, Run, -1).

bucket_delta(B0, Run, Delta) ->
    Status = maps:get(status, Run, unknown),
    Duration = maps:get(duration_ms, Run, 0),
    Feature = maps:get(feature_cid, Run, <<>>),
    Node = maps:get(node, Run, <<>>),
    FailureSig = maps:get(failure_signature, Run, <<>>),
    Evidence = maps:get(evidence, Run, #{}),
    Ecai = maps:get(ecai, Run, #{}),
    B1 = inc(B0, total, Delta),
    B2 = inc(B1, Status, Delta),
    B3 = case Duration > 0 of
        true ->
            Hist = hist_delta(maps:get(duration_hist, B2), Duration, Delta),
            B2#{
                duration_count => nonneg(maps:get(duration_count, B2) + Delta),
                duration_sum_ms => nonneg(maps:get(duration_sum_ms, B2) + Delta * Duration),
                duration_hist => Hist,
                max_duration_ms => case Delta > 0 of true -> erlang:max(maps:get(max_duration_ms, B2), Duration); false -> maps:get(max_duration_ms, B2) end
            };
        false -> B2
    end,
    B4 = B3#{
        features => count_map_delta(maps:get(features, B3), Feature, Delta),
        nodes => count_map_delta(maps:get(nodes, B3), Node, Delta),
        failure_signatures => count_map_delta(maps:get(failure_signatures, B3), FailureSig, Delta)
    },
    B5 = inc(B4, chain_confirmed, bool_delta(maps:get(chain_confirmed, Evidence, false), Delta)),
    ReportLoaded = maps:get(report_meta, Evidence, false) orelse maps:get(legacy_report, Evidence, false),
    B6 = inc(B5, evidence_loaded, bool_delta(ReportLoaded, Delta)),
    B7 = inc(B6, ecai_indexed, bool_delta(maps:get(search_indexed, Ecai, false), Delta)),
    B8 = inc(B7, ecai_relations, Delta * integer_value(maps:get(relation_count, Ecai, 0))),
    inc(B8, ecai_curve_features, Delta * integer_value(maps:get(curve_feature_count, Ecai, 0))).

inc(Map, Key, Delta) -> maps:put(Key, nonneg(maps:get(Key, Map, 0) + Delta), Map).
nonneg(N) when N < 0 -> 0;
nonneg(N) -> N.
bool_delta(true, Delta) -> Delta;
bool_delta(_, _Delta) -> 0.

count_map_delta(Map, <<>>, _Delta) -> Map;
count_map_delta(Map, Key, Delta) ->
    New = maps:get(Key, Map, 0) + Delta,
    case New =< 0 of true -> maps:remove(Key, Map); false -> maps:put(Key, New, Map) end.

hist_delta(Hist, Duration, Delta) ->
    Index = hist_index(Duration, ?DURATION_BOUNDS, 1),
    update_nth(Hist, Index, Delta).

hist_index(_Duration, [], Index) -> Index;
hist_index(Duration, [Bound | _], Index) when Duration =< Bound -> Index;
hist_index(Duration, [_ | Rest], Index) -> hist_index(Duration, Rest, Index + 1).

update_nth(List, N, Delta) ->
    {Left, [Value | Right]} = lists:split(N - 1, List),
    Left ++ [nonneg(Value + Delta) | Right].

%% ===================================================================
%% Summary/read projection
%% ===================================================================

build_summary(Account, Days, State) ->
    CurrentDays = day_axis(Days, 0),
    PreviousDays = day_axis(Days, Days),
    Buckets = [{Day, lookup_bucket(Account, Day)} || Day <- CurrentDays],
    Current = merge_buckets([B || {_D, B} <- Buckets]),
    Previous = merge_buckets([lookup_bucket(Account, D) || D <- PreviousDays]),
    Total = maps:get(total, Current),
    Known = maps:get(passed, Current) + maps:get(failed, Current),
    PassRate = ratio(maps:get(passed, Current), Known),
    PrevKnown = maps:get(passed, Previous) + maps:get(failed, Previous),
    PrevPassRate = ratio(maps:get(passed, Previous), PrevKnown),
    Hist = maps:get(duration_hist, Current),
    DurationCount = maps:get(duration_count, Current),
    ActiveDays = length([ok || {_D, B} <- Buckets, maps:get(total, B, 0) > 0]),
    Recent = recent_runs(Account, ?DEFAULT_RECENT, window_cutoff_ms(Days)),
    Ecai = ecai_summary(Current, Total),
    EvidenceCoverage = ratio(maps:get(evidence_loaded, Current), Total),
    ConfirmedCoverage = ratio(maps:get(chain_confirmed, Current), Total),
    Series = [#{
        day => Day,
        total => maps:get(total, B),
        passed => maps:get(passed, B),
        failed => maps:get(failed, B),
        unknown => maps:get(unknown, B)
    } || {Day, B} <- Buckets],
    Signals = signals(Current, Previous, Days),
    #{
        status => ok,
        account => Account,
        window_days => Days,
        version => maps:get(version, State, 0),
        totals => #{
            runs => Total,
            passed => maps:get(passed, Current),
            failed => maps:get(failed, Current),
            unknown => maps:get(unknown, Current),
            known => Known,
            pass_rate => PassRate,
            active_days => ActiveDays,
            unique_features => map_size(maps:get(features, Current)),
            unique_nodes => map_size(maps:get(nodes, Current))
        },
        durations => #{
            samples => DurationCount,
            average_ms => average(maps:get(duration_sum_ms, Current), DurationCount),
            median_ms => percentile(Hist, DurationCount, 0.50, maps:get(max_duration_ms, Current)),
            p95_ms => percentile(Hist, DurationCount, 0.95, maps:get(max_duration_ms, Current)),
            approximate => true
        },
        evidence => #{
            report_meta => maps:get(evidence_loaded, Current),
            chain_confirmed => maps:get(chain_confirmed, Current),
            report_coverage => EvidenceCoverage,
            chain_coverage => ConfirmedCoverage
        },
        trend => #{
            previous_runs => maps:get(total, Previous),
            runs_delta => Total - maps:get(total, Previous),
            pass_rate => PassRate,
            previous_pass_rate => PrevPassRate,
            pass_rate_delta => rate_delta(PassRate, PrevPassRate)
        },
        series => Series,
        signals => Signals,
        ecai => Ecai,
        recent => Recent,
        freshness => freshness(State)
    }.


empty_summary(Account, Days) ->
    #{status => unavailable, account => account_bin(Account), window_days => Days,
      totals => #{runs => 0, passed => 0, failed => 0, unknown => 0, known => 0,
                  pass_rate => null, active_days => 0, unique_features => 0, unique_nodes => 0},
      durations => #{samples => 0, average_ms => null, median_ms => null, p95_ms => null, approximate => true},
      evidence => #{report_meta => 0, chain_confirmed => 0, report_coverage => null, chain_coverage => null},
      trend => #{previous_runs => 0, runs_delta => 0, pass_rate => null,
                 previous_pass_rate => null, pass_rate_delta => null},
      series => [], signals => [], recent => [],
      ecai => #{status => unavailable, indexed_runs => 0, relation_count => 0,
                curve_feature_count => 0, geometry_status => unavailable,
                geometry_backend => unavailable},
      freshness => #{stale => true, syncing => false}}.

lookup_bucket(Account, Day) ->
    Key = {Account, Day},
    case ets:lookup(?DAYS_TAB, Key) of [{Key, B}] -> B; [] -> empty_bucket() end.

merge_buckets(Buckets) -> lists:foldl(fun merge_bucket/2, empty_bucket(), Buckets).

merge_bucket(B, Acc0) ->
    Numeric = [total, passed, failed, unknown, duration_count, duration_sum_ms,
               chain_confirmed, evidence_loaded, ecai_indexed, ecai_relations, ecai_curve_features],
    Acc1 = lists:foldl(fun(K, A) -> maps:put(K, maps:get(K, A, 0) + maps:get(K, B, 0), A) end, Acc0, Numeric),
    Acc1#{
        duration_hist => merge_hist(maps:get(duration_hist, Acc1), maps:get(duration_hist, B)),
        max_duration_ms => erlang:max(maps:get(max_duration_ms, Acc1), maps:get(max_duration_ms, B)),
        features => merge_count_maps(maps:get(features, Acc1), maps:get(features, B)),
        nodes => merge_count_maps(maps:get(nodes, Acc1), maps:get(nodes, B)),
        failure_signatures => merge_count_maps(maps:get(failure_signatures, Acc1), maps:get(failure_signatures, B))
    }.

merge_hist(A, B) -> lists:zipwith(fun(X, Y) -> X + Y end, A, B).
merge_count_maps(A, B) -> maps:fold(fun(K, V, Acc) -> maps:put(K, maps:get(K, Acc, 0) + V, Acc) end, A, B).

recent_runs(Account, Limit0, CutoffMs) ->
    Limit = erlang:min(?MAX_RECENT, erlang:max(1, Limit0)),
    Match = [{{{Account, '$1', '$2'}, '$3'}, [], [{{'$1', '$3'}}]}],
    Rows = case ets:select(?RECENT_TAB, Match, Limit * 3) of
        '$end_of_table' -> [];
        {Values, _Continuation} -> Values
    end,
    Runs = lists:filtermap(fun({NegTs, ReportCid}) ->
        Ts = -NegTs,
        case Ts >= CutoffMs of
            false -> false;
            true ->
                case ets:lookup(?RUNS_TAB, ReportCid) of
                    [] -> false;
                    [{ReportCid, Run}] -> {true, damage_analytics_model:public_run(Run)}
                end
        end
    end, Rows),
    lists:sublist(Runs, Limit).

signals(Current, Previous, Days) ->
    CurrFailed = maps:get(failed, Current),
    PrevFailed = maps:get(failed, Previous),
    FailureSignals = top_failure_signatures(maps:get(failure_signatures, Current), 4),
    Base = case {CurrFailed, PrevFailed} of
        {0, _} -> [];
        {C, 0} when C > 0 -> [#{kind => new_failures, severity => warning, count => C,
                                message => <<"Failures appeared in the selected window after a zero-failure baseline.">>}];
        _ -> []
    end,
    Repeats = [#{kind => repeated_failure_signature, severity => warning,
                 signature => Sig, count => Count,
                 message => <<"Repeated deterministic failure signature.">>}
               || {Sig, Count} <- FailureSignals, Count >= 2],
    case Base ++ Repeats of
        [] -> [#{kind => stable, severity => info, count => maps:get(total, Current),
                 message => iolist_to_binary(io_lib:format("No deterministic regression signal in ~p-day window.", [Days]))}];
        List -> List
    end.

top_failure_signatures(Map, Limit) ->
    Sorted = lists:sort(fun({K1,V1}, {K2,V2}) ->
        case V1 =:= V2 of true -> K1 =< K2; false -> V1 > V2 end
    end, maps:to_list(Map)),
    lists:sublist(Sorted, Limit).

ecai_summary(Current, Total) ->
    Indexed = maps:get(ecai_indexed, Current),
    Relations = maps:get(ecai_relations, Current),
    Curves = maps:get(ecai_curve_features, Current),
    Availability = damage_analytics_ecai:availability(),
    Status = case {maps:get(enabled, Availability, true),
                   maps:get(relations, Availability, false),
                   maps:get(search, Availability, false)} of
        {false, _, _} -> unavailable;
        {true, true, true} -> active;
        {true, true, false} -> degraded;
        {true, false, true} -> degraded;
        _ -> unavailable
    end,
    #{
        status => Status,
        indexed_runs => Indexed,
        index_coverage => ratio(Indexed, Total),
        relation_count => Relations,
        curve_feature_count => Curves,
        geometry_status => case maps:get(geometry, Availability, false) of true -> experimental; false -> unavailable end,
        geometry_backend => maps:get(geometry_backend, Availability, unavailable),
        projection => damage_analytics_ecai_worker:status(),
        availability => Availability
    }.

freshness(State) ->
    C = maps:get(checkpoint, State, #{}),
    LastSync = maps:get(last_success_ms, C, 0),
    Age = case LastSync of 0 -> null; _ -> erlang:max(0, (now_ms() - LastSync) div 1000) end,
    DegradedSources = degraded_sources(maps:get(sources, C, #{})),
    LastError = maps:get(last_error, C, null),
    #{
        source => <<"materialized_analytics_cache">>,
        persistent => maps:get(dets, State, undefined) =/= undefined,
        last_updated_ms => maps:get(last_updated_ms, State, 0),
        last_sync_ms => LastSync,
        age_seconds => Age,
        source_height => maps:get(source_height, C, null),
        scanned_transactions => maps:get(scanned_transactions, C, 0),
        decoded_runs => maps:get(decoded_runs, C, 0),
        hydrated_runs => maps:get(hydrated_runs, C, 0),
        backfill => backfill_status(maps:get(source_backfill, C, #{})),
        degraded_sources => DegradedSources,
        last_error => LastError,
        stale => LastError =/= null orelse DegradedSources =/= [],
        syncing => analytics_syncing()
    }.

backfill_status(Backfill) when is_map(Backfill) ->
    Entries = maps:to_list(Backfill),
    Pending = [source_name(Name) || {Name, Cursor} <- Entries, not backfill_done(Cursor)],
    AccountPending = [Name || Name <- Pending, is_binary(Name), binary:match(Name, <<"account:">>) =:= {0, 8}],
    #{
        complete => Entries =/= [] andalso Pending =:= [],
        source_count => length(Entries),
        pending_sources => Pending,
        pending_account_sources => AccountPending
    };
backfill_status(_) -> #{complete => false, source_count => 0, pending_sources => [], pending_account_sources => []}.

backfill_done(done) -> true;
backfill_done(null) -> true;
backfill_done(undefined) -> true;
backfill_done(<<>>) -> true;
backfill_done(_) -> false.

degraded_sources(Sources) when is_map(Sources) ->
    [source_name(Name) || {Name, Meta} <- maps:to_list(Sources),
                          is_map(Meta), source_degraded(Meta)];
degraded_sources(_) -> [].

source_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
source_name(Name) when is_binary(Name) -> Name;
source_name(Name) -> iolist_to_binary(io_lib:format("~p", [Name])).

source_degraded(Meta) ->
    Backfill = maps:get(backfill, Meta, #{}),
    maps:is_key(error, Meta) orelse
        (is_map(Backfill) andalso maps:is_key(error, Backfill)).

analytics_syncing() ->
    try damage_analytics_indexer:status() of
        #{syncing := Syncing} -> Syncing;
        _ -> false
    catch _:_ -> false end.

account_run_count(Account) ->
    length([ok || {_Cid, Run} <- ets:tab2list(?RUNS_TAB), maps:get(account, Run, <<>>) =:= Account]).

unscoped_run_count() ->
    length([ok || {_Cid, Run} <- ets:tab2list(?RUNS_TAB), maps:get(account, Run, <<>>) =:= <<>>]).

percentile(_Hist, 0, _Q, _Max) -> null;
percentile(Hist, Total, Q, Max) ->
    Target = erlang:max(1, trunc(math:ceil(Total * Q))),
    percentile0(Hist, ?DURATION_BOUNDS ++ [Max], Target, 0).

percentile0([Count | _], [Bound | _], Target, Seen) when Seen + Count >= Target -> Bound;
percentile0([Count | Rest], [_ | Bounds], Target, Seen) -> percentile0(Rest, Bounds, Target, Seen + Count);
percentile0(_, _, _Target, _Seen) -> null.

ratio(_N, 0) -> null;
ratio(N, D) -> N / D.
rate_delta(null, _B) -> null;
rate_delta(_A, null) -> null;
rate_delta(A, B) -> A - B.
average(_N, 0) -> null;
average(N, D) -> N / D.

normalize_days(7) -> 7;
normalize_days(30) -> 30;
normalize_days(90) -> 90;
normalize_days(B) when is_binary(B) ->
    try normalize_days(binary_to_integer(B)) catch _:_ -> 30 end;
normalize_days(L) when is_list(L) ->
    try normalize_days(list_to_integer(L)) catch _:_ -> 30 end;
normalize_days(_) -> 30.

day_axis(Days, Offset) ->
    Today = calendar:date_to_gregorian_days(element(1, calendar:universal_time())),
    Start = Today - Offset - Days + 1,
    [date_bin(calendar:gregorian_days_to_date(Start + I)) || I <- lists:seq(0, Days - 1)].

window_cutoff_ms(Days) -> now_ms() - Days * 24 * 60 * 60 * 1000.

day_bin(Ms) when is_integer(Ms), Ms > 0 ->
    try
        {{Y,M,D}, _} = calendar:system_time_to_universal_time(Ms, millisecond),
        date_bin({Y,M,D})
    catch _:_ -> <<>> end;
day_bin(_) -> <<>>.

date_bin({Y,M,D}) ->
    list_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y,M,D])).

normalize_settlement(chain_confirmed) -> chain_confirmed;
normalize_settlement(confirmed) -> chain_confirmed;
normalize_settlement(pending_chain) -> pending_chain;
normalize_settlement(pending) -> pending_chain;
normalize_settlement(_) -> pending_chain.

account_bin(B) when is_binary(B) -> B;
account_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
account_bin(_) -> <<>>.

integer_value(I) when is_integer(I) -> I;
integer_value(F) when is_float(F) -> trunc(F);
integer_value(_) -> 0.

text(B) when is_binary(B) -> B;
text(L) when is_list(L) -> unicode:characters_to_binary(L);
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(V) -> iolist_to_binary(io_lib:format("~p", [V])).

now_ms() -> erlang:system_time(millisecond).
