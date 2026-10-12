%%%-------------------------------------------------------------------
%%% Background AEMDW/IPFS reconciler for analytics.
%%%
%%% The indexer is deliberately not on the request path. It incrementally scans
%%% the configured DAMAGE token transactions, hydrates immutable run.meta once,
%%% and writes canonical runs into damage_analytics_store. Cached analytics stay
%%% readable during middleware/IPFS outages.
%%%-------------------------------------------------------------------
-module(damage_analytics_indexer).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([start_link/0, refresh_async/0, track_account/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_INTERVAL_MS, 30000).
-define(DEFAULT_START_DELAY_MS, 1500).
-define(DEFAULT_PAGE_LIMIT, 100).
-define(DEFAULT_MAX_PAGES, 6).
-define(DEFAULT_BACKFILL_PAGES, 2).
-define(DEFAULT_REQUEST_TIMEOUT, 10000).
-define(DEFAULT_META_RETRY_LIMIT, 24).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

refresh_async() ->
    case whereis(?SERVER) of undefined -> ok; _ -> gen_server:cast(?SERVER, refresh) end.

%% Register an authenticated account as a bounded historical source. This is
%% deliberately cheap: it only updates indexer state and kicks the background
%% reconciler. The dashboard request never waits for middleware/IPFS history.
track_account(Account0) ->
    Account = account_id(Account0),
    case {whereis(?SERVER), Account} of
        {undefined, _} -> {error, not_started};
        {_, <<>>} -> {error, invalid_account};
        _ ->
            try gen_server:call(?SERVER, {track_account, Account}, 1000)
            catch _:_ -> {error, unavailable} end
    end.

status() ->
    case whereis(?SERVER) of
        undefined -> #{status => unavailable, syncing => false};
        _ ->
            try gen_server:call(?SERVER, status, 1000)
            catch _:_ -> #{status => unavailable, syncing => false} end
    end.

init([]) ->
    Timer = erlang:send_after(start_delay_ms(), self(), sync),
    {ok, #{syncing => false, worker => undefined, timer => Timer,
           last_result => undefined, last_started_ms => 0,
           tracked_accounts => #{}, resync_requested => false}}.

handle_call(status, _From, State) ->
    Tracked = maps:keys(maps:get(tracked_accounts, State, #{})),
    {reply, #{
        status => ok,
        syncing => maps:get(syncing, State, false),
        last_started_ms => maps:get(last_started_ms, State, 0),
        last_result => maps:get(last_result, State, undefined),
        interval_ms => interval_ms(),
        tracked_account_count => length(Tracked)
    }, State};
handle_call({track_account, Account}, _From, State0) ->
    Tracked0 = maps:get(tracked_accounts, State0, #{}),
    IsNew = not maps:is_key(Account, Tracked0),
    State1 = State0#{tracked_accounts => Tracked0#{Account => true}},
    %% A newly viewed account should not wait for the normal interval. If a sync
    %% is already in flight, queue exactly one immediate follow-up so the new
    %% account source is not delayed or allowed to start parallel scans.
    State = case {IsNew, maps:get(syncing, State1, false)} of
        {true, true} -> State1#{resync_requested => true};
        {true, false} -> maybe_start_sync(State1);
        _ -> State1
    end,
    {reply, #{status => ok, tracked => true, new_source => IsNew}, State};
handle_call(_Other, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(refresh, #{syncing := true} = State) ->
    {noreply, State#{resync_requested => true}};
handle_cast(refresh, State) ->
    {noreply, maybe_start_sync(State)};
handle_cast(_Other, State) -> {noreply, State}.

handle_info(sync, State0) ->
    {noreply, maybe_start_sync(State0)};
handle_info({analytics_sync_done, Pid, Result}, #{worker := Pid} = State0) ->
    State1 = State0#{syncing => false, worker => undefined, worker_ref => undefined,
                     last_result => public_result(Result)},
    case maps:get(resync_requested, State1, false) of
        true ->
            {noreply, maybe_start_sync(State1#{resync_requested => false, timer => undefined})};
        false ->
            Timer = erlang:send_after(interval_ms(), self(), sync),
            {noreply, State1#{timer => Timer}}
    end;
handle_info({'DOWN', Ref, process, Pid, Reason}, #{worker := Pid, worker_ref := Ref} = State0) ->
    case maps:get(syncing, State0, false) of
        true ->
            ?LOG_WARNING("analytics sync worker exited reason=~p", [Reason]),
            Checkpoint0 = damage_analytics_store:checkpoint(),
            Checkpoint = Checkpoint0#{last_error => safe_reason(Reason), last_attempt_ms => now_ms()},
            _ = damage_analytics_store:set_checkpoint(Checkpoint),
            Timer = erlang:send_after(backoff_ms(), self(), sync),
            {noreply, State0#{syncing => false, worker => undefined, timer => Timer,
                              last_result => #{status => error, reason => safe_reason(Reason)}}};
        false -> {noreply, State0}
    end;
handle_info(_Other, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(worker, State, undefined) of P when is_pid(P) -> exit(P, kill); _ -> ok end,
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

maybe_start_sync(#{syncing := true} = State) -> State;
maybe_start_sync(State0) ->
    cancel_timer(maps:get(timer, State0, undefined)),
    Parent = self(),
    Accounts = maps:keys(maps:get(tracked_accounts, State0, #{})),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = try sync_once(Accounts) catch Class:Reason:Stack -> {error, {Class, Reason, Stack}} end,
        Parent ! {analytics_sync_done, self(), Result}
    end),
    State0#{syncing => true, worker => Pid, worker_ref => Ref, last_started_ms => now_ms()}.

sync_once(TrackedAccounts) ->
    Started = now_ms(),
    Checkpoint0 = damage_analytics_store:checkpoint(),
    Token = token_contract(),
    SourceHeads0 = maps:get(source_heads, Checkpoint0, #{}),
    SourceBackfill0 = maps:get(source_backfill, Checkpoint0, #{}),
    Sources = analytics_sources(Token, TrackedAccounts),
    case fetch_sources(Sources, SourceHeads0, SourceBackfill0) of
        {ok, TaggedRows0, SourceMeta, SourceHeads, SourceBackfill} ->
            TaggedRows = dedupe_tagged_rows(TaggedRows0),
            Stats0 = #{scanned => length(TaggedRows), decoded => 0, hydrated => 0, errors => 0},
            Stats = lists:foldl(fun({Row, Trusted}, Acc) -> process_row(Row, Token, Trusted, Acc) end,
                                Stats0, TaggedRows),
            RetryStats = retry_missing_meta(meta_retry_limit()),
            Height = fetch_top_height(),
            Checkpoint = #{
                source_heads => SourceHeads,
                source_backfill => SourceBackfill,
                head_tx_hash => maps:get(contract, SourceHeads, maps:get(head_tx_hash, Checkpoint0, <<>>)),
                source_height => Height,
                last_success_ms => now_ms(),
                last_attempt_ms => Started,
                scanned_transactions => maps:get(scanned, Stats, 0),
                decoded_runs => maps:get(decoded, Stats, 0),
                hydrated_runs => maps:get(hydrated, Stats, 0),
                sources => SourceMeta,
                meta_retries => RetryStats,
                last_error => null
            },
            ok = damage_analytics_store:set_checkpoint(Checkpoint),
            {ok, Checkpoint};
        {error, Reason} ->
            ?LOG_WARNING("analytics middleware sync failed reason=~p", [Reason]),
            Checkpoint = Checkpoint0#{
                last_attempt_ms => Started,
                last_error => safe_reason(Reason)
            },
            ok = damage_analytics_store:set_checkpoint(Checkpoint),
            {error, Reason}
    end.

fetch_sources(Sources, Heads0, Backfill0) ->
    fetch_sources(Sources, Heads0, Backfill0, [], #{}, Heads0, Backfill0, []).

fetch_sources([{Name, Path, Trusted} | Rest], Heads0, Backfill0,
              RowsAcc, MetaAcc, HeadsAcc, BackfillAcc, Errors) ->
    StopHash = maps:get(Name, Heads0, <<>>),
    ExistingBackfill = maps:get(Name, Backfill0, undefined),
    case fetch_transaction_pages(Path, StopHash, max_pages()) of
        {ok, IncrementalRows, IncrementalMeta} ->
            Head = first_tx_hash(IncrementalRows, StopHash),
            {BackfillRows, BackfillMeta, NextBackfill} =
                fetch_source_backfill(Name, StopHash, ExistingBackfill, IncrementalMeta),
            Rows = IncrementalRows ++ BackfillRows,
            Tagged = [{Row, Trusted} || Row <- Rows],
            Meta = IncrementalMeta#{
                rows => length(Rows),
                incremental_rows => length(IncrementalRows),
                backfill_rows => length(BackfillRows),
                backfill => BackfillMeta
            },
            NextBackfillAcc = put_backfill(Name, NextBackfill, BackfillAcc),
            fetch_sources(Rest, Heads0, Backfill0, RowsAcc ++ Tagged,
                          MetaAcc#{Name => Meta}, HeadsAcc#{Name => Head},
                          NextBackfillAcc, Errors);
        {error, Why} ->
            fetch_sources(Rest, Heads0, Backfill0, RowsAcc,
                          MetaAcc#{Name => #{error => safe_reason(Why)}},
                          HeadsAcc, BackfillAcc, [{Name, Why} | Errors])
    end;
fetch_sources([], _Heads0, _Backfill0, Rows, Meta, Heads, Backfill, Errors) ->
    case {Rows, Errors} of
        {[], [_ | _]} -> {error, {all_sources_failed, [{N, safe_reason(E)} || {N, E} <- Errors]}};
        _ -> {ok, Rows, Meta, Heads, Backfill}
    end.

fetch_source_backfill(_Name, <<>>, _ExistingBackfill, IncrementalMeta) ->
    %% First successful scan becomes the head and its continuation becomes the
    %% durable historical cursor. Later syncs advance this cursor without
    %% re-reading already materialized historical pages.
    Next = maps:get(next_path, IncrementalMeta, undefined),
    {[], #{status => initialized}, Next};
fetch_source_backfill(_Name, _StopHash, undefined, IncrementalMeta) ->
    %% Upgrade path from the earlier head-only checkpoint format. Re-read the
    %% page containing the checkpoint so rows older than that transaction on the
    %% same page are not skipped. Duplicate rows are safely coalesced by report
    %% CID in the materialized store.
    Next = maps:get(checkpoint_page, IncrementalMeta,
                    maps:get(next_path, IncrementalMeta, undefined)),
    {[], #{status => initialized_from_checkpoint}, Next};
fetch_source_backfill(_Name, _StopHash, done, _IncrementalMeta) ->
    {[], #{status => complete}, done};
fetch_source_backfill(_Name, _StopHash, null, _IncrementalMeta) ->
    {[], #{status => complete}, done};
fetch_source_backfill(_Name, _StopHash, <<>>, _IncrementalMeta) ->
    {[], #{status => complete}, done};
fetch_source_backfill(Name, _StopHash, BackfillPath, _IncrementalMeta) ->
    case fetch_transaction_pages(BackfillPath, <<>>, backfill_pages(Name)) of
        {ok, Rows, Meta} ->
            {Rows, Meta#{status => running}, maps:get(next_path, Meta, undefined)};
        {error, Why} ->
            %% Backfill failure must not invalidate a successful incremental
            %% refresh. Keep the cursor and retry it next cycle.
            {[], #{status => degraded, error => safe_reason(Why)}, BackfillPath}
    end.

put_backfill(Name, undefined, Acc) -> Acc#{Name => done};
put_backfill(Name, null, Acc) -> Acc#{Name => done};
put_backfill(Name, <<>>, Acc) -> Acc#{Name => done};
put_backfill(Name, done, Acc) -> Acc#{Name => done};
put_backfill(Name, Path, Acc) -> Acc#{Name => Path}.

analytics_sources(Token, TrackedAccounts0) ->
    %% Account-scoped activity is intentionally first. The global token index is
    %% useful for reconciliation, but it may contain lots of unrelated AEX9
    %% traffic. An account dashboard should discover its own historical calls
    %% quickly, while the local payer feed catches hosted PayingForTx runs whose
    %% outer transaction is owned by the DamageBDD node.
    TrackedAccounts = lists:usort([
        A || A0 <- TrackedAccounts0,
             A <- [account_id(A0)], A =/= <<>>
    ]),
    AccountSources = [
        {account_source_name(Account), account_activity_path(Account, false), false}
     || Account <- TrackedAccounts
    ],
    Contract = {contract, transaction_path(Token), true},
    NodeSources = case local_node_id() of
        <<"ak_", _/binary>> = Node ->
            [{local_node, account_activity_path(Node, true), false}];
        _ -> []
    end,
    AccountSources ++ [Contract] ++ NodeSources.

account_source_name(Account) -> <<"account:", Account/binary>>.

account_activity_path(Account, OwnedOnly) ->
    Owned = case OwnedOnly of true -> <<"true">>; false -> <<"false">> end,
    <<"/v3/accounts/", Account/binary,
      "/activities?owned_only=", Owned/binary,
      "&type=transactions&direction=backward&limit=",
      (integer_to_binary(page_limit()))/binary>>.

dedupe_tagged_rows(Rows) ->
    {_Seen, OutRev} = lists:foldl(fun({Row, Trusted}, {Seen, Acc}) ->
        Key = case damage_analytics_model:tx_hash(Row) of
            <<>> -> {shape, erlang:phash2(Row)};
            Hash -> {tx, Hash}
        end,
        case maps:is_key(Key, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Key => true}, [{Row, Trusted} | Acc]}
        end
    end, {#{}, []}, Rows),
    lists:reverse(OutRev).


process_row(Row, Token, Trusted, Stats0) ->
    case damage_analytics_model:normalize_chain_spend(Row, Token, Trusted) of
        {ok, Run0} -> store_chain_run(Run0, Stats0);
        not_run ->
            case maybe_hydrate_transaction(Row, Token, Trusted) of
                {ok, Run1} -> store_chain_run(Run1, Stats0);
                not_run -> Stats0;
                {error, _} -> inc_stat(Stats0, errors)
            end
    end.

maybe_hydrate_transaction(Row, Token, Trusted) ->
    case damage_analytics_model:plausible_run_transaction(Row, Token) of
        false -> not_run;
        true ->
            case damage_analytics_model:tx_hash(Row) of
                <<>> -> not_run;
                Hash ->
                    case mdw_get_json(<<"/v3/transactions/", Hash/binary>>) of
                        {ok, Full} ->
                            case damage_analytics_model:normalize_chain_spend(Full, Token, Trusted) of
                                {ok, _} = Ok -> Ok;
                                not_run -> damage_analytics_model:normalize_chain_spend(
                                    maps:merge(Full, #{<<"activity_row">> => Row}), Token, Trusted)
                            end;
                        {error, Why} -> {error, Why}
                    end
            end
    end.

store_chain_run(Run0, Stats0) ->
    {Run, Hydrated} = enrich_report_meta(Run0),
    case damage_analytics_store:upsert_chain_run(Run) of
        {ok, _} ->
            Stats1 = inc_stat(Stats0, decoded),
            case Hydrated of true -> inc_stat(Stats1, hydrated); false -> Stats1 end;
        {error, _} -> inc_stat(Stats0, errors)
    end.

enrich_report_meta(Run) ->
    ReportCid = maps:get(report_cid, Run, <<>>),
    case read_run_meta(ReportCid) of
        {ok, Meta} ->
            Enriched0 = damage_analytics_model:enrich_meta(Run, Meta),
            {Enriched0#{meta_attempts => 0, meta_last_error => null,
                        meta_last_attempt_ms => now_ms(), meta_retry_after_ms => 0}, true};
        {error, MetaWhy} ->
            %% Reports published before run.meta existed still contain immutable
            %% formatter output. Recover a conservative pass/fail signal from
            %% *.plain.txt and a title from the feature CID when possible. This
            %% is deliberately a fallback: run.meta remains authoritative.
            case read_legacy_report_evidence(Run) of
                {ok, Legacy} ->
                    Enriched1 = damage_analytics_model:merge_run(Run, Legacy),
                    {Enriched1#{meta_attempts => 0, meta_last_error => null,
                                meta_last_attempt_ms => now_ms(), meta_retry_after_ms => 0}, true};
                {error, LegacyWhy} ->
                    {mark_meta_failure(Run, {MetaWhy, LegacyWhy}), false}
            end
    end.

mark_meta_failure(Run, Why) ->
    Attempts = integer_value(maps:get(meta_attempts, Run, 0)) + 1,
    Exponent = erlang:min(7, erlang:max(0, Attempts - 1)),
    Delay = erlang:min(3600000, 30000 * (1 bsl Exponent)),
    Now = now_ms(),
    Run#{meta_attempts => Attempts,
         meta_last_error => safe_reason(Why),
         meta_last_attempt_ms => Now,
         meta_retry_after_ms => Now + Delay}.

retry_missing_meta(Limit) ->
    Missing = damage_analytics_store:pending_meta(Limit),
    lists:foldl(fun(Run, Acc) ->
        case enrich_report_meta(Run) of
            {Enriched, true} ->
                _ = damage_analytics_store:upsert_chain_run(Enriched),
                Acc + 1;
            {Marked, false} ->
                _ = damage_analytics_store:upsert_chain_run(Marked),
                Acc
        end
    end, 0, Missing).

read_run_meta(<<>>) -> {error, missing_report};
read_run_meta(ReportCid) ->
    try
        Path = filename:join([binary_to_list(ReportCid), "run.meta"]),
        case damage_ipfs:cat(Path) of
            {ok, Data} when is_binary(Data), byte_size(Data) =< 131072 ->
                try {ok, jsx:decode(Data, [return_maps])}
                catch _:_ -> {error, invalid_meta} end;
            _ -> {error, not_found}
        end
    catch _:_ -> {error, unavailable} end.


read_legacy_report_evidence(Run) ->
    ReportCid = maps:get(report_cid, Run, <<>>),
    FeatureCid = maps:get(feature_cid, Run, <<>>),
    case read_legacy_plain_report(ReportCid) of
        {ok, Plain} ->
            Status = legacy_report_status(Plain),
            Title = read_feature_title(FeatureCid),
            {ok, #{
                status => Status,
                feature_title => Title,
                evidence => #{legacy_report => true}
            }};
        {error, _} = Error -> Error
    end.

read_legacy_plain_report(<<>>) -> {error, missing_report};
read_legacy_plain_report(ReportCid) ->
    try
        ReportsPath = filename:join([ReportCid, <<"reports">>]),
        case damage_ipfs:ls(ReportsPath) of
            {ok, Objects} ->
                case legacy_plain_name(Objects) of
                    <<>> -> {error, legacy_plain_not_found};
                    Name ->
                        Path = filename:join([ReportCid, <<"reports">>, Name]),
                        case damage_ipfs:cat(Path) of
                            {ok, Data} when is_binary(Data), byte_size(Data) =< 2097152 -> {ok, Data};
                            _ -> {error, legacy_plain_unavailable}
                        end
                end;
            _ -> {error, legacy_report_listing_unavailable}
        end
    catch _:_ -> {error, legacy_report_unavailable} end.

legacy_plain_name(Objects) when is_list(Objects) ->
    Links = lists:append([
        maps:get(<<"Links">>, Obj, [])
     || Container <- Objects,
        is_map(Container),
        Obj <- maps:get(<<"Objects">>, Container, []),
        is_map(Obj)
    ]),
    Names = [text(maps:get(<<"Name">>, Link, <<>>)) || Link <- Links, is_map(Link)],
    case [Name || Name <- Names,
                  re:run(Name, <<"^[A-Za-z0-9_.-]+\\.plain\\.txt$">>, [{capture, none}]) =:= match] of
        [Name | _] -> Name;
        [] -> <<>>
    end;
legacy_plain_name(_) -> <<>>.

legacy_report_status(Body) when is_binary(Body) ->
    Failed = <<"(?:\\b(?:Given|When|Then|And|But)\\b[^\\r\\n]*(?:fail|failed|error)\\s*$|^\\s*(?:Run result|Run status)\\s*:\\s*(?:fail|failed|error)|^\\s*Failure\\s*:)">>,
    Passed = <<"(?:^\\s*(?:Run result|Run status)\\s*:\\s*(?:success|passed)|\\b(?:Given|When|Then|And|But)\\b[^\\r\\n]*\\bsuccess\\s*$)">>,
    case re:run(Body, Failed, [caseless, multiline, {capture, none}]) of
        match -> failed;
        nomatch ->
            case re:run(Body, Passed, [caseless, multiline, {capture, none}]) of
                match -> passed;
                nomatch -> unknown
            end
    end;
legacy_report_status(_) -> unknown.

read_feature_title(<<>>) -> <<>>;
read_feature_title(FeatureCid) ->
    try
        case damage_ipfs:cat(FeatureCid) of
            {ok, Data} when is_binary(Data), byte_size(Data) =< 1048576 -> feature_title(Data);
            _ -> <<>>
        end
    catch _:_ -> <<>> end.

feature_title(Data) ->
    Lines = binary:split(Data, <<"\n">>, [global]),
    case [Title || Line <- Lines,
                   {match, [Title]} <- [re:run(Line, <<"^\\s*Feature\\s*:\\s*(.+?)\\s*$">>,
                                              [caseless, {capture, [1], binary}])]] of
        [Title | _] -> Title;
        [] -> <<>>
    end.

%% ===================================================================
%% Incremental middleware scan
%% ===================================================================

fetch_transaction_pages(Path, StopHash, MaxPages) ->
    fetch_transaction_pages(Path, StopHash, MaxPages, 0, [], #{}).

fetch_transaction_pages(Path, _StopHash, MaxPages, Page, Acc, Meta) when Page >= MaxPages ->
    {ok, Acc, Meta#{pages => Page, stopped_at_checkpoint => false, next_path => Path}};
fetch_transaction_pages(undefined, _StopHash, _MaxPages, Page, Acc, Meta) ->
    {ok, Acc, Meta#{pages => Page, stopped_at_checkpoint => false, next_path => undefined}};
fetch_transaction_pages(Path, StopHash, MaxPages, Page, Acc, Meta) ->
    case mdw_get_json(Path) of
        {ok, Json} ->
            Rows = data_rows(Json),
            case split_at_checkpoint(Rows, StopHash) of
                {Before, true} ->
                    {ok, Acc ++ Before, Meta#{pages => Page + 1, stopped_at_checkpoint => true,
                                              checkpoint_page => Path,
                                              next_path => next_path(Json)}};
                {Before, false} ->
                    Next = next_path(Json),
                    fetch_transaction_pages(Next, StopHash, MaxPages, Page + 1,
                                            Acc ++ Before, Meta)
            end;
        {error, Why} -> {error, Why}
    end.

split_at_checkpoint(Rows, <<>>) -> {Rows, false};
split_at_checkpoint(Rows, StopHash) -> split_at_checkpoint(Rows, StopHash, []).
split_at_checkpoint([Row | Rest], StopHash, Acc) ->
    case damage_analytics_model:tx_hash(Row) of
        StopHash -> {lists:reverse(Acc), true};
        _ -> split_at_checkpoint(Rest, StopHash, [Row | Acc])
    end;
split_at_checkpoint([], _StopHash, Acc) -> {lists:reverse(Acc), false}.

first_tx_hash([Row | Rest], Default) ->
    case damage_analytics_model:tx_hash(Row) of <<>> -> first_tx_hash(Rest, Default); Hash -> Hash end;
first_tx_hash([], Default) -> Default.

data_rows(Json) when is_map(Json) ->
    case maps:get(<<"data">>, Json, maps:get(data, Json, [])) of
        Rows when is_list(Rows) -> Rows;
        _ -> []
    end;
data_rows(_) -> [].

next_path(Json) when is_map(Json) ->
    case maps:get(<<"next">>, Json, maps:get(next, Json, undefined)) of
        undefined -> undefined;
        null -> undefined;
        <<>> -> undefined;
        Value -> normalize_next_path(text(Value))
    end;
next_path(_) -> undefined.

normalize_next_path(<<"http", _/binary>> = Url) ->
    try
        Parsed = uri_string:parse(Url),
        Path = text(maps:get(path, Parsed, <<>>)),
        Query = text(maps:get(query, Parsed, <<>>)),
        case Query of <<>> -> Path; _ -> <<Path/binary, "?", Query/binary>> end
    catch _:_ -> undefined end;
normalize_next_path(Path) -> Path.

transaction_path(Token) ->
    <<"/v3/transactions?contract=", Token/binary,
      "&type=contract_call&type=paying_for&direction=backward&limit=",
      (integer_to_binary(page_limit()))/binary>>.

mdw_get_json(Path0) ->
    Path = text(Path0),
    Source = try damage_ae:get_ae_mdw_node() catch _:_ -> {error, middleware_unavailable} end,
    case Source of
        {ok, ConnPid, Prefix0} ->
            try
                Prefix = string:trim(binary_to_list(text(Prefix0)), trailing, "/") ++ "/",
                RequestPath = join_mdw_path(Prefix, Path),
                case gun:await_up(ConnPid, request_timeout()) of
                    {ok, _Protocol} ->
                        Stream = gun:get(ConnPid, RequestPath, [{<<"accept">>, <<"application/json">>}]),
                        case gun:await(ConnPid, Stream, request_timeout()) of
                            {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
                                case gun:await_body(ConnPid, Stream, request_timeout()) of
                                    {ok, Body} when byte_size(Body) =< 4000000 ->
                                        try {ok, jsx:decode(Body, [return_maps])}
                                        catch _:_ -> {error, invalid_json} end;
                                    Other -> {error, {body, Other}}
                                end;
                            {response, fin, Status, _Headers} when Status >= 200, Status < 300 -> {ok, #{<<"data">> => []}};
                            {response, _Fin, Status, _Headers} -> {error, {http_status, Status}};
                            Other -> {error, {response, Other}}
                        end;
                    Other -> {error, {await_up, Other}}
                end
            catch
                Class:Reason -> {error, {Class, Reason}}
            after
                _ = try gun:close(ConnPid) catch _:_ -> ok end
            end;
        Other -> {error, Other}
    end.

join_mdw_path(Prefix, Path0) ->
    Path1 = binary_to_list(Path0),
    Path = case Path1 of
        "/mdw/v3/" ++ Rest -> "/v3/" ++ Rest;
        _ -> Path1
    end,
    Prefix ++ string:trim(Path, leading, "/").

fetch_top_height() ->
    case mdw_get_json(<<"/v3/status">>) of
        {ok, Json} -> integer_value(first_defined([
            maps:get(<<"top_block_height">>, Json, undefined),
            maps:get(<<"top_height">>, Json, undefined),
            maps:get(top_block_height, Json, undefined),
            maps:get(top_height, Json, undefined)
        ]));
        _ -> null
    end.

%% ===================================================================
%% Config/helpers
%% ===================================================================

local_node_id() ->
    case application:get_env(damage, run_history_node_account, undefined) of
        Account when is_binary(Account), Account =/= <<>> -> Account;
        Account when is_list(Account), Account =/= [] -> list_to_binary(Account);
        _ ->
            try secrets:node_keypair() of
                #{public_key := PublicKey} -> text(PublicKey);
                _ -> <<>>
            catch _:_ -> <<>> end
    end.

token_contract() ->
    case application:get_env(damage, analytics_token_contract) of
        {ok, B} when is_binary(B) -> B;
        {ok, L} when is_list(L) -> list_to_binary(L);
        _ -> list_to_binary(?DAMAGE_TOKEN_CONTRACT)
    end.

interval_ms() -> positive_int(application:get_env(damage, analytics_sync_interval_ms, ?DEFAULT_INTERVAL_MS), ?DEFAULT_INTERVAL_MS).
start_delay_ms() -> positive_int(application:get_env(damage, analytics_start_delay_ms, ?DEFAULT_START_DELAY_MS), ?DEFAULT_START_DELAY_MS).
backoff_ms() -> positive_int(application:get_env(damage, analytics_retry_ms, interval_ms()), interval_ms()).
page_limit() -> clamp(positive_int(application:get_env(damage, analytics_page_limit, ?DEFAULT_PAGE_LIMIT), ?DEFAULT_PAGE_LIMIT), 10, 100).
max_pages() -> clamp(positive_int(application:get_env(damage, analytics_max_pages, ?DEFAULT_MAX_PAGES), ?DEFAULT_MAX_PAGES), 1, 20).
backfill_pages(Name) ->
    Default = case is_account_source(Name) of
        true -> 6;
        false -> ?DEFAULT_BACKFILL_PAGES
    end,
    Key = case is_account_source(Name) of
        true -> analytics_account_backfill_pages_per_sync;
        false -> analytics_backfill_pages_per_sync
    end,
    clamp(positive_int(application:get_env(damage, Key, Default), Default), 1, 20).

is_account_source(<<"account:", _/binary>>) -> true;
is_account_source(_) -> false.
request_timeout() -> positive_int(application:get_env(damage, analytics_request_timeout_ms, ?DEFAULT_REQUEST_TIMEOUT), ?DEFAULT_REQUEST_TIMEOUT).
meta_retry_limit() -> clamp(positive_int(application:get_env(damage, analytics_meta_retry_limit, ?DEFAULT_META_RETRY_LIMIT), ?DEFAULT_META_RETRY_LIMIT), 1, 100).


account_id(B) when is_binary(B) ->
    case re:run(B, <<"^ak_[1-9A-HJ-NP-Za-km-z]{20,70}$">>, [{capture, none}]) of
        match -> B;
        nomatch -> <<>>
    end;
account_id(L) when is_list(L) -> account_id(unicode:characters_to_binary(L));
account_id(_) -> <<>>.

positive_int(V, _Default) when is_integer(V), V > 0 -> V;
positive_int(_, Default) -> Default.
clamp(V, Min, _Max) when V < Min -> Min;
clamp(V, _Min, Max) when V > Max -> Max;
clamp(V, _Min, _Max) -> V.

inc_stat(Map, Key) -> maps:put(Key, maps:get(Key, Map, 0) + 1, Map).

public_result({ok, Map}) when is_map(Map) -> Map#{status => ok};
public_result({error, Why}) -> #{status => error, reason => safe_reason(Why)};
public_result(Other) -> #{status => unknown, result => safe_reason(Other)}.

safe_reason(B) when is_binary(B) -> bounded(B, 400);
safe_reason(A) when is_atom(A) -> atom_to_binary(A, utf8);
safe_reason(V) -> bounded(iolist_to_binary(io_lib:format("~p", [V])), 400).
bounded(B, Max) when byte_size(B) =< Max -> B;
bounded(B, Max) -> binary:part(B, 0, Max).

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([null | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> 0.

integer_value(I) when is_integer(I) -> I;
integer_value(B) when is_binary(B) -> try binary_to_integer(B) catch _:_ -> 0 end;
integer_value(_) -> 0.

text(B) when is_binary(B) -> B;
text(L) when is_list(L) -> unicode:characters_to_binary(L);
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(I) when is_integer(I) -> integer_to_binary(I);
text(V) -> iolist_to_binary(io_lib:format("~p", [V])).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) -> ok.

now_ms() -> erlang:system_time(millisecond).
