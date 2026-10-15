%%% Durable Coinstore observation cache + bounded, resumable REST backfill.
%%% Cache reads never issue HTTP. Historical candles never become live books.
%%% Network work runs outside the server, one live request and one candle
%%% request at a time. DETS progress is acknowledged AFTER the data is synced.
-module(ecai_mm_price_cache).
-behaviour(gen_server).
-export([start_link/0, start_link/1, fetch/0, status/0, history/2, candles/3,
         backfill/0, backfill/1, fields/0, validate_settings/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, ecai_mm_price_cache_store).
-define(MAX_WAITERS, 64).
-define(WORKER_TIMEOUT, 18000).

start_link() ->
    Base = application:get_env(damage, ecai_mm_price_cache, #{}),
    case is_map(Base) of
        true ->
            Dir = maps:get(state_dir, Base,
                filename:join(damage_config:state_dir(), "ecai-mm-price-cache")),
            start_link(Base#{state_dir => Dir});
        false -> {error, invalid_price_cache_config}
    end.
start_link(Options) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).
fetch() -> gen_server:call(?MODULE, fetch, 20000).
status() ->
    try gen_server:call(?MODULE, status, 3000)
    catch exit:_ -> #{available => false, error => <<"price_cache_unavailable">>} end.
history(Period, Limit) -> gen_server:call(?MODULE, {history, Period, Limit}, 5000).
candles(Symbol, Period, Limit) -> gen_server:call(?MODULE, {candles, Symbol, Period, Limit}, 5000).
backfill() -> backfill(#{}).
backfill(Request) -> gen_server:call(?MODULE, {backfill, Request}, 5000).

fields() -> [
    #{key => market_maker_price_cache_ttl_ms, label => <<"Live feed cache TTL (ms)">>,
      type => integer, min => 0, max => 2000, default => 1000, apply => hot,
      help => <<"Reuse only a recent successful live request. Zero disables reuse; original timestamps are never refreshed by reading the cache.">>},
    #{key => market_maker_history_auto_backfill, label => <<"Automatically populate price history">>,
      type => boolean, default => true, apply => hot,
      help => <<"Fetch recent hourly and daily Coinstore candles while the paper engine is enabled. History cannot create quotes, fills or paper returns.">>},
    #{key => market_maker_history_bars, label => <<"Historical bars per request">>,
      type => integer, min => 1, max => 2000, default => 720, apply => hot,
      help => <<"Recent bars requested for each symbol and period; exchange availability may be shorter. REST backfill has no time cursor.">>},
    #{key => market_maker_history_refresh_ms, label => <<"Historical refresh interval (ms)">>,
      type => integer, min => 60000, max => 86400000, default => 300000, apply => hot,
      help => <<"Refresh overlapping recent windows and retain earlier cached bars. Applies to subsequent automatic requests.">>}
].

control_keys() ->
    [{market_maker_price_cache_ttl_ms, live_ttl_ms},
     {market_maker_history_auto_backfill, history_auto_backfill},
     {market_maker_history_bars, history_bars},
     {market_maker_history_refresh_ms, history_refresh_ms}].
defaults() ->
    #{live_ttl_ms => 1000, history_auto_backfill => true, history_bars => 720,
      history_refresh_ms => 300000, history_periods => [<<"60min">>, <<"1day">>],
      retention_bars => 10000}.

validate_settings(Ecai) when is_map(Ecai) ->
    case [maps:get(key, F) || F <- fields(),
          {ok, V} <- [maps:find(maps:get(key, F), Ecai)], not field_valid(F, V)] of
        [] -> ok;
        [Key | _] -> {error, {invalid_price_cache_setting, Key}}
    end;
validate_settings(_) -> {error, invalid_price_cache_settings}.
field_valid(#{type := boolean}, V) -> is_boolean(V);
field_valid(#{min := Min, max := Max}, V) -> is_integer(V) andalso V >= Min andalso V =< Max.

options(S) ->
    Base = maps:get(options, S),
    Ecai = maps:from_list([{K, V} || {K, _} <- control_keys(),
                                  {ok, V} <- [application:get_env(ecai, K)]]),
    case validate_settings(Ecai) of
        ok -> {ok, maps:merge(Base, maps:from_list([{Core, V} || {K, Core} <- control_keys(),
                                                      {ok, V} <- [maps:find(K, Ecai)]]))};
        Error -> Error
    end.

init(Options) when is_map(Options) ->
    O = maps:merge(defaults(), Options),
    case valid_options(O) of
        false -> {stop, invalid_price_cache_config};
        true -> open_store(O)
    end;
init(_) -> {stop, invalid_price_cache_config}.

valid_options(O) ->
    Settings = maps:from_list([{K, maps:get(Core, O)} || {K, Core} <- control_keys()]),
    Ps = maps:get(history_periods, O), N = maps:get(retention_bars, O),
    validate_settings(Settings) =:= ok andalso is_list(Ps) andalso
    length(Ps) > 0 andalso length(Ps) =< 9 andalso
    lists:all(fun(P) -> lists:member(P, ecai_mm_candles:periods()) end, Ps) andalso
    is_integer(N) andalso N >= 2000 andalso N =< 10000 andalso
    (is_list(maps:get(state_dir, O, undefined)) orelse is_binary(maps:get(state_dir, O, undefined))).

open_store(O) ->
    File = filename:join(maps:get(state_dir, O), "prices.dets"),
    case filelib:ensure_dir(File) of
        ok ->
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {repair, true}]) of
                {ok, Tab} ->
                    try
                        Version = lookup(Tab, version, 1),
                        1 = Version,
                        Jobs = lookup(Tab, jobs, []),
                        true = is_list(Jobs) andalso length(Jobs) =< 18,
                        true = lists:all(fun valid_job/1, Jobs),
                        Series = dets:foldl(fun
                            ({{series, Sym, P}, V}, Acc) when is_map(V) -> Acc#{{Sym, P} => V};
                            (_, Acc) -> Acc
                        end, #{}, Tab),
                        ok = write(Tab, {version, 1}),
                        Timer = erlang:send_after(0, self(), tick),
                        {ok, #{tab => Tab, options => O, series => Series, jobs => Jobs,
                               %% Restored live data is DISPLAY ONLY. Reuse requires a new
                               %% successful network request in this process incarnation.
                               last_live => lookup(Tab, live, undefined), live => undefined,
                               live_mono => 0, live_retry_mono => 0, live_error => null,
                               live_pending => undefined, history_pending => undefined,
                               last_history_request_ms => lookup(Tab, last_history_request_ms, 0),
                               hits => 0, misses => 0, coalesced => 0, tick_timer => Timer}}
                    catch Class:Why ->
                        dets:close(Tab), {stop, {price_cache_restore_failed, Class, Why}}
                    end;
                {error, Why} -> {stop, {price_cache_open_failed, Why}}
            end;
        {error, Why} -> {stop, {price_cache_directory_failed, Why}}
    end.

handle_call(status, _From, S) -> {reply, public_status(S), S};
handle_call(fetch, From, S) ->
    case options(S) of
        {ok, O} -> live_call(From, O, S);
        Error -> {reply, Error, S}
    end;
handle_call({history, Period, Limit}, _From, S) ->
    case valid_query(<<"DAMAGEUSDT">>, Period, Limit) of
        false -> {reply, {error, invalid_history_request}, S};
        true ->
            D = bars(<<"DAMAGEUSDT">>, Period, S), B = bars(<<"BTCUSDT">>, Period, S),
            Rows = ecai_mm_candles:paired(D, B, Limit),
            {reply, {ok, #{kind => historical_prices, source => <<"coinstore">>,
                period => Period, period_ms => ecai_mm_candles:period_ms(Period),
                timestamp_unit => <<"milliseconds">>, execution_eligible => false,
                coverage => <<"retained_recent_windows">>, rows => Rows,
                missing_intervals => missing_intervals(Rows, Period)}}, S}
    end;
handle_call({candles, Symbol, Period, Limit}, _From, S) ->
    case valid_query(Symbol, Period, Limit) of
        false -> {reply, {error, invalid_history_request}, S};
        true ->
            Rows = bars(Symbol, Period, S),
            Result = series_info(Symbol, Period, series(Symbol, Period, S)),
            {reply, {ok, Result#{kind => historical_candles, execution_eligible => false,
                bars => lists:nthtail(max(0, length(Rows) - Limit), Rows)}}, S}
    end;
handle_call({backfill, Request}, _From, S) ->
    case options(S) of
        {ok, O} ->
            case request_jobs(Request, O) of
                {ok, Jobs} ->
                    New = enqueue(Jobs, S),
                    {reply, {ok, #{queued => length(maps:get(jobs, New))}}, dispatch(New)};
                Error -> {reply, Error, S}
            end;
        Error -> {reply, Error, S}
    end;
handle_call(_, _From, S) -> {reply, {error, bad_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    New = dispatch(auto_jobs(S)),
    Ref = erlang:send_after(1000, self(), tick),
    {noreply, New#{tick_timer => Ref}};
handle_info({cache_result, Kind, Id, Result}, S) ->
    {noreply, complete(Kind, Id, Result, S)};
handle_info({cache_timeout, Kind, Id}, S) ->
    {noreply, complete(Kind, Id, {error, price_request_timeout}, S)};
handle_info({'DOWN', Ref, process, _Pid, Reason}, S) ->
    case pending_by_monitor(Ref, S) of
        {Kind, Id} -> {noreply, complete(Kind, Id, {error, {price_request_exit, Reason}}, S)};
        none -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.

terminate(_, S) ->
    _ = erlang:cancel_timer(maps:get(tick_timer, S)),
    [stop_task(maps:get(K, S)) || K <- [live_pending, history_pending]],
    dets:sync(maps:get(tab, S)), dets:close(maps:get(tab, S)), ok.
code_change(_, S, _) -> {ok, S}.

live_call(From, _O, #{live_pending := Pending} = S) when is_map(Pending) ->
    Waiters = maps:get(waiters, Pending),
    case length(Waiters) < ?MAX_WAITERS of
        true -> {noreply, S#{live_pending => Pending#{waiters => [From | Waiters]},
                            coalesced => maps:get(coalesced, S) + 1}};
        false -> {reply, {error, price_cache_busy}, S}
    end;
live_call(From, O, S) ->
    Mono = erlang:monotonic_time(millisecond), Now = erlang:system_time(millisecond),
    Live = maps:get(live, S),
    Recent = is_map(Live) andalso maps:get(live_error, S) =:= null andalso
        maps:get(live_ttl_ms, O) > 0 andalso
        Mono - maps:get(live_mono, S) < maps:get(live_ttl_ms, O) andalso
        Now >= maps:get(fetched_ms, Live) andalso
        Now - maps:get(fetched_ms, Live) =< 2000,
    case {Recent, Mono < maps:get(live_retry_mono, S), maps:get(live_error, S)} of
        {true, _, _} ->
            {reply, {ok, Live#{cache_hit => true}}, S#{hits => maps:get(hits, S) + 1}};
        {false, true, Error} when Error =/= null -> {reply, {error, Error}, S};
        _ ->
            Task = start_task(live, fun() -> fetch_live(O) end),
            {noreply, S#{live_pending => Task#{waiters => [From]},
                         misses => maps:get(misses, S) + 1}}
    end.

fetch_live(O) ->
    case maps:get(get_fun, O, undefined) of
        Get when is_function(Get, 1) -> ecai_mm_feed:fetch(Get);
        _ -> ecai_mm_feed:fetch_live()
    end.
fetch_history(Job, O) ->
    Sym = maps:get(symbol, Job), P = maps:get(period, Job), N = maps:get(size, Job),
    case maps:get(get_fun, O, undefined) of
        Get when is_function(Get, 1) -> ecai_mm_feed:fetch_candles(Sym, P, N, Get);
        _ -> ecai_mm_feed:fetch_candles(Sym, P, N)
    end.

start_task(Kind, Fun) ->
    Owner = self(), Id = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = try Fun() catch C:R -> {error, {price_request_exception, C, R}} end,
        Owner ! {cache_result, Kind, Id, Result}
    end),
    Timer = erlang:send_after(?WORKER_TIMEOUT, Owner, {cache_timeout, Kind, Id}),
    #{id => Id, pid => Pid, monitor => Ref, timer => Timer}.
stop_task(undefined) -> ok;
stop_task(Task) ->
    erlang:cancel_timer(maps:get(timer, Task)),
    erlang:demonitor(maps:get(monitor, Task), [flush]),
    exit(maps:get(pid, Task), kill), ok.
pending_key(live) -> live_pending;
pending_key(history) -> history_pending.
pending_by_monitor(Ref, S) ->
    case [{Kind, maps:get(id, T)} || Kind <- [live, history],
          T <- [maps:get(pending_key(Kind), S)], is_map(T), maps:get(monitor, T) =:= Ref] of
        [Found] -> Found;
        [] -> none
    end.
complete(Kind, Id, Result, S) when Kind =:= live; Kind =:= history ->
    Key = pending_key(Kind),
    case maps:get(Key, S) of
        #{id := Id} = Task ->
            stop_task(Task),
            case Kind of
                live -> finish_live(Result, Task, S#{Key => undefined});
                history -> finish_history(Result, Task, S#{Key => undefined})
            end;
        _ -> S
    end;
complete(_, _, _, S) -> S.

finish_live({ok, Book}, Task, S) when is_map(Book) ->
    case valid_live_book(Book) of
        true ->
            Clean = maps:with([kind, source, bid, ask, btc_usdt, damage_last_usdt,
                              fetched_ms, price_feed_reference], Book),
            ok = write(maps:get(tab, S), {live, Clean}),
            [gen_server:reply(F, {ok, Clean#{cache_hit => false}}) || F <- maps:get(waiters, Task)],
            S#{last_live => Clean, live => Clean, live_mono => erlang:monotonic_time(millisecond),
               live_error => null, live_retry_mono => 0};
        false -> finish_live({error, invalid_live_cache_result}, Task, S)
    end;
finish_live({error, Why}, Task, S) ->
    [gen_server:reply(F, {error, Why}) || F <- maps:get(waiters, Task)],
    %% A failure is NEVER converted into success by returning an old book.
    S#{live => undefined, live_error => Why,
       live_retry_mono => erlang:monotonic_time(millisecond) + 5000};
finish_live(_, Task, S) -> finish_live({error, invalid_live_cache_result}, Task, S).

valid_live_book(#{kind := live_order_book, source := <<"coinstore">>,
                  bid := Bid, ask := Ask, btc_usdt := BTC, fetched_ms := Ts}) ->
    Now = erlang:system_time(millisecond),
    is_number(Bid) andalso is_number(Ask) andalso is_number(BTC) andalso
    Bid > 0 andalso Ask > Bid andalso BTC > 0 andalso
    is_integer(Ts) andalso Ts > 0 andalso Ts =< Now andalso Now - Ts =< 300000;
valid_live_book(_) -> false.

request_jobs(Req, O) when is_map(Req) ->
    try
        [] = maps:keys(maps:without([symbol, period, size], Req)),
        Ps = case maps:find(period, Req) of {ok, FoundPeriod} -> [FoundPeriod]; error -> maps:get(history_periods, O) end,
        Syms = case maps:find(symbol, Req) of {ok, FoundSymbol} -> [FoundSymbol]; error -> ecai_mm_candles:symbols() end,
        N = maps:get(size, Req, maps:get(history_bars, O)),
        Jobs = [job(Sym, P, N, false) || P <- Ps, Sym <- Syms],
        true = lists:all(fun valid_job/1, Jobs),
        {ok, Jobs}
    catch _:_ -> {error, invalid_history_request} end;
request_jobs(_, _) -> {error, invalid_history_request}.
job(Sym, P, N, Auto) ->
    #{symbol => Sym, period => P, size => N, automatic => Auto, attempts => 0, not_before_ms => 0}.
valid_job(#{symbol := Sym, period := P, size := N, automatic := Auto,
            attempts := A, not_before_ms := T}) ->
    valid_query(Sym, P, N) andalso is_boolean(Auto) andalso is_integer(A) andalso
    A >= 0 andalso A =< 5 andalso is_integer(T) andalso T >= 0;
valid_job(_) -> false.
valid_query(Sym, P, N) ->
    lists:member(Sym, ecai_mm_candles:symbols()) andalso
    lists:member(P, ecai_mm_candles:periods()) andalso is_integer(N) andalso N >= 1 andalso N =< 2000.
job_key(J) -> {maps:get(symbol, J), maps:get(period, J)}.

enqueue(NewJobs, S) ->
    Old = maps:get(jobs, S),
    Jobs = lists:foldl(fun(J, Acc) ->
        case [X || X <- Acc, job_key(X) =:= job_key(J)] of
            [OldJob] ->
                %% A manual request promotes automatic work and a larger size
                %% cannot be silently lost. An in-flight smaller request may
                %% finish, but the upgraded job remains queued for another pass.
                Upgraded = OldJob#{size => max(maps:get(size, OldJob), maps:get(size, J)),
                    automatic => maps:get(automatic, OldJob) andalso maps:get(automatic, J)},
                [case X =:= OldJob of true -> Upgraded; false -> X end || X <- Acc];
            [] -> Acc ++ [J]
        end
    end, Old, NewJobs),
    save_jobs(Jobs, S).
save_jobs(Jobs, S) ->
    case Jobs =:= maps:get(jobs, S) of
        true -> S;
        false -> ok = write(maps:get(tab, S), {jobs, Jobs}), S#{jobs => Jobs}
    end.

auto_jobs(S) ->
    case options(S) of
        {ok, O} ->
            case maps:get(history_auto_backfill, O) andalso
                    application:get_env(ecai, market_maker_enabled, false) =:= true of
                false -> cancel_automatic(S);
                true ->
                    Now = erlang:system_time(millisecond),
                    Jobs = [job(Sym, P, maps:get(history_bars, O), true)
                        || P <- lists:usort(maps:get(history_periods, O)),
                           Sym <- ecai_mm_candles:symbols(),
                           Now - maps:get(last_attempt_ms, series(Sym, P, S), 0) >=
                               maps:get(history_refresh_ms, O)],
                    enqueue(Jobs, S)
            end;
        _ -> cancel_automatic(S)
    end.
cancel_automatic(S) ->
    New = case maps:get(history_pending, S) of
        #{job := #{automatic := true}} = Task ->
            stop_task(Task), S#{history_pending => undefined};
        _ -> S
    end,
    save_jobs([J || J <- maps:get(jobs, New), maps:get(automatic, J) =:= false], New).

dispatch(#{history_pending := Task} = S) when is_map(Task) -> S;
dispatch(S) ->
    Now = erlang:system_time(millisecond), Jobs = maps:get(jobs, S),
    Due = [J || J <- Jobs, maps:get(not_before_ms, J) =< Now],
    case {Due, Now - maps:get(last_history_request_ms, S) >= 1000, options(S)} of
        {[J | _], true, {ok, O}} ->
            %% Keep the in-flight job in DETS until its candle batch is durable.
            %% A crash simply retries the same idempotent window after restart.
            Next = J#{attempts => min(5, maps:get(attempts, J) + 1)},
            Prepared = save_jobs([Next | lists:delete(J, Jobs)], S),
            Sym = maps:get(symbol, J), P = maps:get(period, J),
            V = series(Sym, P, Prepared),
            Updated = save_series(Sym, P, V#{last_attempt_ms => Now}, Prepared),
            ok = write(maps:get(tab, S), {last_history_request_ms, Now}),
            Pending = start_task(history, fun() -> fetch_history(Next, O) end),
            Updated#{history_pending => Pending#{job => Next}, last_history_request_ms => Now};
        _ -> S
    end.

finish_history({ok, Rows}, Task, S) when is_list(Rows) ->
    J = maps:get(job, Task), Sym = maps:get(symbol, J), P = maps:get(period, J),
    V = series(Sym, P, S), Keep = maps:get(retention_bars, maps:get(options, S)),
    Updated = V#{bars => ecai_mm_candles:merge(maps:get(bars, V), Rows, Keep),
                 last_success_ms => erlang:system_time(millisecond), last_error => null,
                 last_batch_count => length(Rows), last_requested_size => maps:get(size, J)},
    Durable = save_series(Sym, P, Updated, S),
    %% Ordering is intentional: a crash between these syncs may repeat a fetch,
    %% but cannot acknowledge a completed job whose candles were not persisted.
    save_jobs(lists:delete(J, maps:get(jobs, Durable)), Durable);
finish_history({error, Why}, Task, S) ->
    J = maps:get(job, Task), Sym = maps:get(symbol, J), P = maps:get(period, J),
    V = series(Sym, P, S),
    New = save_series(Sym, P, V#{last_error => error_text(Why)}, S),
    Others = lists:delete(J, maps:get(jobs, S)),
    Jobs = case {lists:member(J, maps:get(jobs, S)), maps:get(attempts, J) < 5} of
        {true, true} ->
            Delay = min(300000, 5000 * (1 bsl (maps:get(attempts, J) - 1))),
            Others ++ [J#{not_before_ms => erlang:system_time(millisecond) + Delay}];
        _ -> Others %% Do not duplicate or overwrite a promoted/larger pending job.
    end,
    save_jobs(Jobs, New);
finish_history(_, Task, S) -> finish_history({error, invalid_history_result}, Task, S).

series(Sym, P, S) -> maps:get({Sym, P}, maps:get(series, S), #{bars => []}).
bars(Sym, P, S) -> maps:get(bars, series(Sym, P, S)).
save_series(Sym, P, V, S) ->
    ok = write(maps:get(tab, S), {{series, Sym, P}, V}),
    Series = maps:get(series, S), S#{series => Series#{{Sym, P} => V}}.
lookup(Tab, Key, Default) ->
    case dets:lookup(Tab, Key) of [{Key, V}] -> V; [] -> Default end.
write(Tab, Record) ->
    ok = dets:insert(Tab, Record), ok = dets:sync(Tab), ok.

series_info(Sym, P, V) ->
    Rows = maps:get(bars, V),
    {First, Last} = case Rows of
        [] -> {null, null};
        [H | _] -> {maps:get(ts_ms, H), maps:get(ts_ms, lists:last(Rows))}
    end,
    (maps:without([bars], V))#{source => <<"coinstore">>, symbol => Sym, period => P,
      count => length(Rows), oldest_ms => First, newest_ms => Last,
      coverage => <<"retained_recent_windows">>}.
public_status(S) ->
    #{available => true, persistent => true, schema_version => 1,
      hits => maps:get(hits, S), misses => maps:get(misses, S), coalesced => maps:get(coalesced, S),
      live_inflight => is_map(maps:get(live_pending, S)),
      history_inflight => is_map(maps:get(history_pending, S)),
      live_error => error_text(maps:get(live_error, S)),
      latest => public_latest(maps:get(last_live, S)),
      queued => length(maps:get(jobs, S)), jobs => maps:get(jobs, S),
      series => [series_info(Sym, P, V) || {{Sym, P}, V} <- lists:sort(maps:to_list(maps:get(series, S)))]}.
public_latest(undefined) -> null;
public_latest(B) ->
    Ts = maps:get(fetched_ms, B),
    #{kind => cached_prices, source => <<"coinstore">>, execution_eligible => false,
      fetched_ms => Ts, age_ms => erlang:system_time(millisecond) - Ts,
      damage_usdt => maps:get(damage_last_usdt, B, (maps:get(bid, B) + maps:get(ask, B)) / 2),
      btc_usdt => maps:get(btc_usdt, B)}.
error_text(null) -> null;
error_text(B) when is_binary(B) -> binary:part(B, 0, min(byte_size(B), 2048));
error_text(R) ->
    B = iolist_to_binary(io_lib:format("~0P", [R, 12])),
    error_text(B).
missing_intervals([], _) -> 0;
missing_intervals([_], _) -> 0;
missing_intervals([A, B | Rest], P) ->
    Step = ecai_mm_candles:period_ms(P),
    max(0, (maps:get(ts_ms, B) - maps:get(ts_ms, A)) div Step - 1) +
        missing_intervals([B | Rest], P).
