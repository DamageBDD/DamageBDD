%% ECAI market making observer/paper engine for DAMAGEUSDT and BTCUSDT.
%% Never sends an order to Coinstore. Start as an opt-in OTP child.
-module(ecai_mm).
-behaviour(gen_server).
-export([start_link/0, start_link/1, status/0, quotes/0, history/1,
         ingest/1, poll/0, pause/0, resume/0, paper_fill/2, verify_audit/0,
         config/0, configure/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(ZERO, <<0:256>>).

start_link() ->
    Cfg = case application:get_env(damage, ecai_market_maker) of
        {ok, V} when is_map(V) -> V;
        _ -> #{}
    end,
    start_link(Cfg).
start_link(#{mode := Mode}) when Mode =/= paper ->
    {error, live_execution_not_implemented};
start_link(Cfg) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Cfg, []).
status() -> gen_server:call(?MODULE, status).
quotes() -> gen_server:call(?MODULE, quotes).
history(N) -> gen_server:call(?MODULE, {history, N}, 15000).
ingest(Book) -> gen_server:call(?MODULE, {ingest, Book}, 15000).
poll() -> gen_server:cast(?MODULE, poll).
pause() -> gen_server:call(?MODULE, pause).
resume() -> gen_server:call(?MODULE, resume).
paper_fill(Id, Qty) -> gen_server:call(?MODULE, {paper_fill, Id, Qty}, 15000).
verify_audit() -> gen_server:call(?MODULE, verify_audit, 30000).
config() -> gen_server:call(?MODULE, config).
configure(Patch, ExpectedRevision) ->
    gen_server:call(?MODULE, {configure, Patch, ExpectedRevision}, 30000).

init(Cfg) when is_map(Cfg) ->
    %% Deliberate hard safety boundary. A separate, audited exchange execution
    %% adapter is necessary before any live orders may be enabled.
    case maps:get(mode, Cfg, paper) of
        paper -> init_paper(Cfg);
        _ -> {stop, live_execution_not_implemented}
    end.

init_paper(Cfg) ->
    {ok, _} = application:ensure_all_started(crypto),
    Dir = maps:get(state_dir, Cfg, "/var/lib/damage/ecai-mm"),
    File = filename:join(Dir, "ecai_mm.dets"),
    ok = filelib:ensure_dir(File),
    case dets:open_file(ecai_mm_store, [{file, File}, {type, set}, {repair, true}]) of
        {ok, Tab} ->
            StarterBalances = maps:merge(#{damage => 0.0, usdt => 0.0},
                                         maps:get(paper_balances, Cfg, #{})),
            Base = #{seq => 0, ledger => ecai_mm_ledger:new(StarterBalances),
                     prev_hash => ?ZERO, audit_anchor => #{seq => 0, hash => ?ZERO},
                     price => undefined,
                     volatility_bps => 0.0, paused => false,
                     halt_reason => none, feed_error => none,
                     failures => 0, last_good_ms => 0,
                     audit => #{digest_hex => <<>>, state_point_hex => <<>>}},
            Restored = case dets:lookup(Tab, snapshot) of
                [{snapshot, Persisted}] when is_map(Persisted) ->
                    maps:merge(Base, Persisted);
                _ -> Base
            end,
            %% Only the strictly bounded operator-tunable subset can survive a
            %% restart. Corrupt persisted configuration must fail closed.
            EffectiveCfg = case dets:lookup(Tab, runtime_config) of
                [{runtime_config, Values}] when is_map(Values) ->
                    case ecai_mm_config:validate(Values, Cfg) of
                        {ok, Safe} -> maps:merge(Cfg, Safe);
                        _ -> Cfg
                    end;
                _ -> Cfg
            end,
            %% Restart invalidates paper quotes; a newly verified feed poll is
            %% required before any quote IDs can accept fills.
            RestoredLedger = maps:get(ledger, Restored),
            Snapshot = Restored#{
                ledger => ecai_mm_ledger:replace_quotes(RestoredLedger, []),
                feed_error => awaiting_fresh_market},
            PollMs = max(2000, maps:get(poll_interval_ms, EffectiveCfg, 10000)),
            State = #{tab => Tab, config => EffectiveCfg, poll_ms => PollMs,
                      poll_timer => undefined, snapshot => Snapshot},
            {ok, schedule_poll(State, 1000)};
        {error, E} -> {stop, {dets_open_failed, E}}
    end.

handle_call(status, _, State) ->
    {reply, public_snapshot(State), State};
handle_call(config, _, State) ->
    {reply, public_config(State), State};
handle_call({configure, Patch, ExpectedRevision}, _, State) ->
    S = maps:get(snapshot, State),
    Revision = maps:get(config_revision, S, 0),
    case ExpectedRevision =:= Revision of
        false -> {reply, {error, stale_config_revision}, State};
        true ->
            case ecai_mm_config:validate(Patch, maps:get(config, State)) of
                {error, Why} -> {reply, {error, Why}, State};
                {ok, Allowed} ->
                    Cfg = maps:merge(maps:get(config, State), Allowed),
                    Tab = maps:get(tab, State),
                    %% Store config before an audit event; on failure the worker
                    %% crashes rather than acknowledging an unpersisted write.
                    ok = dets:insert(Tab, {runtime_config,
                                           ecai_mm_config:public(Cfg)}),
                    ok = dets:sync(Tab),
                    L = maps:get(ledger, S),
                    S0 = S#{config_revision => Revision + 1,
                            feed_error => awaiting_fresh_market,
                            ledger => ecai_mm_ledger:replace_quotes(L, [])},
                    S1 = State#{config => Cfg,
                                poll_ms => maps:get(poll_interval_ms, Cfg, 10000)},
                    Updated = save_event(S1, S0, config_change,
                                         #{ts_ms => erlang:system_time(millisecond),
                                           revision => Revision + 1,
                                           changes => Allowed}),
                    %% Cancel/re-arm exactly one polling timer: do not spawn a
                    %% second periodic loop when refreshing from the dashboard.
                    NewState = schedule_poll(Updated, 0),
                    {reply, {ok, public_config(NewState)}, NewState}
            end
    end;
handle_call(verify_audit, _, State) ->
    {reply, verify_chain(State), State};
handle_call(quotes, _, State) ->
    S = maps:get(snapshot, State),
    {reply, maps:get(quotes, maps:get(ledger, S), []), State};
handle_call({history, Count}, _, State) when is_integer(Count), Count > 0 ->
    {reply, read_history(State, min(2000, Count)), State};
handle_call({history, _}, _, State) ->
    {reply, {error, invalid_count}, State};
handle_call({ingest, Book}, _, State) when is_map(Book) ->
    {Result, Updated} = ingest_book(Book, State),
    {reply, Result, Updated};
handle_call({paper_fill, Id, Qty}, _, State) ->
    S = maps:get(snapshot, State),
    case {maps:get(paused, S), fresh_for_fills(S, maps:get(config, State))} of
        {true, _} -> {reply, {error, paused}, State};
        {false, false} -> {reply, {error, stale_feed}, State};
        {false, true} ->
            case ecai_mm_ledger:paper_fill(maps:get(ledger, S), Id, Qty) of
                {ok, Ledger0, Fill} ->
                    P = maps:get(price, S),
                    Ledger = ecai_mm_ledger:mark(Ledger0, maps:get(mid, P),
                                                 maps:get(btc_usdt, P)),
                    S0 = S#{ledger => Ledger},
                    NewState = save_event(State, S0, fill, Fill),
                    {reply, {ok, Fill}, NewState};
                {error, Reason} -> {reply, {error, Reason}, State}
            end
    end;
handle_call(pause, _, State) ->
    S = maps:get(snapshot, State),
    L = maps:get(ledger, S),
    S0 = S#{paused => true, halt_reason => manual,
            ledger => ecai_mm_ledger:replace_quotes(L, [])},
    Updated = save_event(State, S0, pause,
                         #{ts_ms => erlang:system_time(millisecond)}),
    {reply, ok, Updated};
handle_call(resume, _, State) ->
    S = maps:get(snapshot, State),
    Max = maps:get(max_drawdown_pct, maps:get(config, State), 10.0),
    Current = maps:get(max_drawdown_pct, maps:get(ledger, S)),
    case Current >= Max of
        true -> {reply, {error, drawdown_limit_exceeded}, State};
        false ->
            S0 = S#{paused => false, halt_reason => none},
            Updated = save_event(State, S0, resume,
                                 #{ts_ms => erlang:system_time(millisecond)}),
            {reply, ok, Updated}
    end;
handle_call(_, _, State) -> {reply, {error, unknown_request}, State}.

handle_cast(poll, State) -> {noreply, run_feed(State)};
handle_cast(_, State) -> {noreply, State}.

handle_info(poll, State) ->
    Updated = run_feed(State#{poll_timer => undefined}),
    {noreply, schedule_poll(Updated, maps:get(poll_ms, Updated))};
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    cancel_poll(State),
    case maps:find(tab, State) of
        {ok, Tab} -> dets:sync(Tab), dets:close(Tab);
        error -> ok
    end.
code_change(_, State, _) -> {ok, State}.

run_feed(State) ->
    case ecai_mm_feed:fetch() of
        {ok, Book} ->
            {_Result, Updated} = ingest_book(Book, State),
            Updated;
        {error, Error} ->
            S = maps:get(snapshot, State),
            Ledger = ecai_mm_ledger:replace_quotes(maps:get(ledger, S), []),
            persist(State#{snapshot => S#{ledger => Ledger,
                                         feed_error => Error,
                                         failures => maps:get(failures, S) + 1}})
    end.

ingest_book(Book0, State) ->
    Book = Book0#{fetched_ms => maps:get(fetched_ms, Book0, erlang:system_time(millisecond))},
    S = maps:get(snapshot, State),
    C = maps:get(config, State),
    Now = erlang:system_time(millisecond),
    %% Freshness is receipt age, not proof of Coinstore's exchange timestamp.
    T = maps:get(fetched_ms, Book, Now),
    Age = Now - T,
    MaxAge = maps:get(max_feed_age_ms, C, 20000),
    case Age >= 0 andalso Age =< MaxAge of
        false ->
            S0 = S#{feed_error => stale_or_future_feed,
                    ledger => ecai_mm_ledger:replace_quotes(maps:get(ledger, S), [])},
            {{error, stale_or_future_feed}, persist(State#{snapshot => S0})};
        true ->
            case ecai_mm_curve:quotes(Book,
                   maps:get(balances, maps:get(ledger, S)), C) of
                {error, Reason} ->
                    S0 = S#{feed_error => Reason,
                            ledger => ecai_mm_ledger:replace_quotes(maps:get(ledger, S), [])},
                    {{error, Reason}, persist(State#{snapshot => S0})};
                {ok, Preview} -> accept_book(Book, Preview, State)
            end
    end.

accept_book(Book, Preview, State) ->
    S = maps:get(snapshot, State),
    C = maps:get(config, State),
    Mid = maps:get(mid, Preview),
    BtcPx = maps:get(btc_usdt, Book),
    OldPrice = maps:get(price, S),
    PrevMid = case OldPrice of undefined -> Mid; X -> maps:get(mid, X) end,
    JumpPct = 100.0 * abs(Mid / PrevMid - 1.0),
    V0 = maps:get(volatility_bps, S),
    Alpha = maps:get(vol_ewma_alpha, C, 0.15),
    VolBps = Alpha * abs(math:log(Mid / PrevMid)) * 10000.0 +
             (1.0 - Alpha) * V0,
    Cfg = C,
    Ledger0 = maps:get(ledger, S),
    Ledger1 = ecai_mm_ledger:mark(Ledger0, Mid, BtcPx),
    Drawdown = maps:get(max_drawdown_pct, Ledger1),
    FailJump = JumpPct > maps:get(max_price_jump_pct, Cfg, 25.0),
    FailDrawdown = Drawdown >= maps:get(max_drawdown_pct, Cfg, 10.0),
    Reference = maps:get(price_feed_reference, Book, null),
    RefBps = case Reference of
        R when is_number(R), R > 0 -> 10000.0 * abs(Mid / R - 1.0);
        _ -> null
    end,
    RefLimit = maps:get(max_reference_deviation_bps, Cfg, infinity),
    FailRef = is_number(RefLimit) andalso is_number(RefBps) andalso RefBps > RefLimit,
    Halt = case {FailJump, FailDrawdown, FailRef} of
        {true, _, _} -> price_jump;
        {_, true, _} -> drawdown;
        {_, _, true} -> reference_divergence;
        _ -> none
    end,
    WasPaused = maps:get(paused, S),
    Paused = WasPaused orelse Halt =/= none,
    HaltReason = case WasPaused of
        true -> maps:get(halt_reason, S);
        false -> Halt
    end,
    %% Recompute with current EWMA; previous call served as book validation.
    Input = Book#{volatility_bps => VolBps},
    {ok, Computed} = ecai_mm_curve:quotes(Input, maps:get(balances, Ledger1), C),
    RawQuotes = maps:get(quotes, Computed),
    Ts = maps:get(fetched_ms, Book),
    FeeBps = maps:get(maker_fee_bps, maps:merge(ecai_mm_curve:defaults(), C)),
    Quotes = case Paused of
        true -> [];
        false -> [decorate_quote(Q, Ts, FeeBps) || Q <- RawQuotes]
    end,
    Ledger2 = ecai_mm_ledger:replace_quotes(Ledger1, Quotes),
    Price = Book#{mid => Mid, volatility_bps => VolBps,
                  reference_deviation_bps => RefBps},
    S0 = S#{ledger => Ledger2, price => Price,
            volatility_bps => VolBps, paused => Paused,
            halt_reason => HaltReason, feed_error => none,
            last_good_ms => Ts},
    Sample = sample(S0),
    New = save_event(State, S0, tick, Sample),
    {ok, New}.

decorate_quote(Q, Ts, FeeBps) ->
    Hash = crypto:hash(sha256, term_to_binary({Ts, Q}, [deterministic])),
    ID = <<"ecai-", (binary:part(ecai_mm_curve:hex(Hash), 0, 26))/binary>>,
    Q#{client_id => ID, remaining_qty => maps:get(qty, Q),
       fee_bps => FeeBps}.

sample(S) ->
    Price = maps:get(price, S),
    Ledger = maps:get(ledger, S),
    B = maps:get(balances, Ledger),
    Damage = maps:get(mid, Price),
    BTC = maps:get(btc_usdt, Price),
    #{ts_ms => maps:get(fetched_ms, Price),
      damage_usdt => Damage, btc_usdt => BTC,
      damage_index => 100.0 * Damage / maps:get(opening_damage, Ledger),
      btc_index => 100.0 * BTC / maps:get(opening_btc, Ledger),
      usdt => maps:get(usdt, B), inventory_damage => maps:get(damage, B),
      equity_usdt => maps:get(last_equity, Ledger),
      pnl_usdt => maps:get(pnl_usdt, Ledger),
      pnl_pct => maps:get(pnl_pct, Ledger),
      btc_benchmark_pnl_usdt => maps:get(btc_benchmark_pnl_usdt, Ledger),
      max_drawdown_pct => maps:get(max_drawdown_pct, Ledger),
      quote_count => length(maps:get(quotes, Ledger))}.

save_event(State, S, Kind, Payload) ->
    Seq = maps:get(seq, S) + 1,
    %% Hash chain protects against unnoticed accidental edits when its tip is
    %% independently retained; no claim of secure time or external finality.
    Event = #{kind => Kind, seq => Seq, payload => Payload},
    Commitment = ecai_mm_curve:chain_event(maps:get(prev_hash, S), Event),
    Digest = maps:get(digest, Commitment),
    PublicCommit = maps:without([digest], Commitment),
    S1 = S#{seq => Seq, prev_hash => Digest, audit => PublicCommit},
    Tab = maps:get(tab, State),
    %% Also store fills in timeline so restart never loses execution events.
    Record = case Kind of
        tick -> Payload#{audit_hash => maps:get(digest_hex, Commitment),
                          audit_point => maps:get(state_point_hex, Commitment)};
        _ -> Payload#{type => Kind, audit_hash => maps:get(digest_hex, Commitment),
                      audit_point => maps:get(state_point_hex, Commitment)}
    end,
    ok = dets:insert(Tab, {{event, Seq}, Record}),
    Keep = max(10, maps:get(max_events, maps:get(config, State), 5000)),
    Anchored = case Seq > Keep of
        true ->
            OldSeq = Seq - Keep,
            case dets:lookup(Tab, {event, OldSeq}) of
                [{{event, OldSeq}, E}] ->
                    OldDigest = from_hex(maps:get(audit_hash, E)),
                    ok = dets:delete(Tab, {event, OldSeq}),
                    S1#{audit_anchor => #{seq => OldSeq, hash => OldDigest}};
                _ -> S1
            end;
        false -> S1
    end,
    persist(State#{snapshot => Anchored}).

persist(State) ->
    Tab = maps:get(tab, State),
    ok = dets:insert(Tab, {snapshot, maps:get(snapshot, State)}),
    ok = dets:sync(Tab),
    State.

read_history(State, N) ->
    Tab = maps:get(tab, State),
    Seq = maps:get(seq, maps:get(snapshot, State)),
    Start = max(1, Seq - N + 1),
    lists:flatmap(fun(I) ->
        case dets:lookup(Tab, {event, I}) of
            [{{event, I}, E}] -> [E];
            _ -> []
        end
    end, lists:seq(Start, Seq)).

public_config(State) ->
    S = maps:get(snapshot, State),
    #{revision => maps:get(config_revision, S, 0),
      mode => paper, execution_enabled => false,
      values => ecai_mm_config:public(maps:get(config, State))}.

schedule_poll(State, Delay) ->
    cancel_poll(State),
    case maps:get(auto_poll, maps:get(config, State), true) of
        true -> State#{poll_timer => erlang:send_after(Delay, self(), poll)};
        false -> State#{poll_timer => undefined}
    end.

cancel_poll(State) ->
    case maps:get(poll_timer, State, undefined) of
        Ref when is_reference(Ref) -> erlang:cancel_timer(Ref);
        _ -> ok
    end.

public_snapshot(State) ->
    S = maps:get(snapshot, State),
    L = maps:get(ledger, S),
    Last = maps:get(last_good_ms, S),
    Age = case Last > 0 of
        true -> erlang:system_time(millisecond) - Last;
        false -> null
    end,
    #{mode => paper, source => <<"coinstore + DamageBDD price_feed reference">>,
      symbol => <<"DAMAGEUSDT">>, hedge_reference => <<"BTCUSDT">>,
      paused => maps:get(paused, S), halt_reason => maps:get(halt_reason, S),
      feed_error => display_error(maps:get(feed_error, S)),
      failures => maps:get(failures, S),
      feed_age_ms => Age, fresh => is_number(Age) andalso
          Age =< maps:get(max_feed_age_ms, maps:get(config, State), 20000) andalso
          maps:get(feed_error, S) =:= none,
      price => case maps:get(price, S) of undefined -> null; P -> P end,
      quotes => maps:get(quotes, L),
      performance => ecai_mm_ledger:public(L),
      audit => maps:get(audit, S), events => maps:get(seq, S),
      poll_interval_ms => maps:get(poll_ms, State),
      config_revision => maps:get(config_revision, S, 0)}.

%% Verify the retained audit segment against its anchored predecessor and
%% the persisted latest tip. Export/share the tip externally to detect wholesale
%% replacement of the local DETS file.
verify_chain(State) ->
    S = maps:get(snapshot, State),
    Anchor = maps:get(audit_anchor, S),
    Tab = maps:get(tab, State),
    VerifyFrom = maps:get(seq, Anchor) + 1,
    verify_events(Tab, VerifyFrom, maps:get(seq, S),
                  maps:get(hash, Anchor), maps:get(prev_hash, S)).

verify_events(_Tab, I, Last, Hash, Expected) when I > Last ->
    case Hash =:= Expected of true -> ok; false -> {error, tip_mismatch} end;
verify_events(Tab, I, Last, Prev, Expected) ->
    case dets:lookup(Tab, {event, I}) of
        [{{event, I}, Rec}] ->
            Kind = maps:get(type, Rec, tick),
            Payload = maps:without([type, audit_hash, audit_point], Rec),
            Event = #{kind => Kind, seq => I, payload => Payload},
            C = ecai_mm_curve:chain_event(Prev, Event),
            case {maps:get(digest_hex, C) =:= maps:get(audit_hash, Rec),
                  maps:get(state_point_hex, C) =:= maps:get(audit_point, Rec)} of
                {true, true} ->
                    verify_events(Tab, I + 1, Last, maps:get(digest, C), Expected);
                _ -> {error, {invalid_commitment, I}}
            end;
        _ -> {error, {missing_event, I}}
    end.

from_hex(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    list_to_binary([list_to_integer([Hi, Lo], 16) || <<Hi, Lo>> <= Bin]).


display_error(none) -> null;
display_error(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).


fresh_for_fills(S, Config) ->
    Ts = maps:get(last_good_ms, S),
    Age = erlang:system_time(millisecond) - Ts,
    maps:get(feed_error, S) =:= none andalso Ts > 0 andalso
    Age >= 0 andalso Age =< maps:get(max_feed_age_ms, Config, 20000).
