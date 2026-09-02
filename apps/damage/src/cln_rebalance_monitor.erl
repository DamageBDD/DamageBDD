-module(cln_rebalance_monitor).

-behaviour(gen_server).

%% Public API
-export([
    start_link/0,
    start_link/1,
    stop/0,
    tick/0,
    snapshot/0,
    advice/0,
    classify_reason/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_INTERVAL_MS, 60000).
-define(DEFAULT_OLLAMA_MODEL, "qwen2.5-coder:14b").
-define(DEFAULT_MAX_PPM, 500).
-define(DEFAULT_MAX_FAILURES, 50).
-define(OLLAMA_TIMEOUT_MS, 60000).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL_MS :: non_neg_integer(),
    ollama_model = ?DEFAULT_OLLAMA_MODEL :: string(),
    max_ppm = ?DEFAULT_MAX_PPM :: non_neg_integer(),
    max_failures = ?DEFAULT_MAX_FAILURES :: pos_integer(),
    timer_ref = undefined,
    last_snapshot = #{},
    last_advice = not_run,
    auto_apply = false
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:call(?MODULE, stop).

tick() ->
    gen_server:cast(?MODULE, tick).

snapshot() ->
    gen_server:call(?MODULE, snapshot, 30000).

advice() ->
    gen_server:call(?MODULE, advice, 30000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    State0 = #state{
        interval_ms = maps:get(interval_ms, Opts, ?DEFAULT_INTERVAL_MS),
        ollama_model = maps:get(ollama_model, Opts, ?DEFAULT_OLLAMA_MODEL),
        max_ppm = maps:get(max_ppm, Opts, ?DEFAULT_MAX_PPM),
        max_failures = maps:get(max_failures, Opts, ?DEFAULT_MAX_FAILURES),
        auto_apply = maps:get(auto_apply, Opts, false)
    },
    {ok, schedule_tick(State0, 1000)}.

handle_call(stop, _From, State) ->
    cancel_timer(State#state.timer_ref),
    {stop, normal, ok, State};
handle_call(snapshot, _From, State) ->
    {reply, State#state.last_snapshot, State};
handle_call(advice, _From, State) ->
    {reply, State#state.last_advice, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(tick, State) ->
    {noreply, run_cycle(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, run_cycle(State)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.timer_ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Main loop
%%====================================================================

run_cycle(State0) ->
    cancel_timer(State0#state.timer_ref),
    Snapshot = collect_snapshot(State0),
    Advice = ask_for_advice(State0, Snapshot),
    ?LOG_INFO("cln rebalance monitor advice=~p", [Advice]),
    State1 = State0#state{last_snapshot = Snapshot, last_advice = Advice},
    schedule_tick(State1, State1#state.interval_ms).

schedule_tick(State, DelayMs) ->
    Ref = erlang:send_after(DelayMs, self(), tick),
    State#state{timer_ref = Ref}.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

%%====================================================================
%% Snapshot collection
%%====================================================================

collect_snapshot(State) ->
    Funds = safe_cln(fun damage_cln:list_funds/0),
    Peers = safe_cln(fun damage_cln:list_channels/0),
    Pays = safe_cln(fun damage_cln:list_pays/0),
    SendPays = safe_cln(fun damage_cln:list_sendpays/0),
    Balance = safe_cln(fun damage_cln:get_node_balance/0),
    Failures = recent_failures(Pays, SendPays, State#state.max_failures),
    #{
        node_balance => Balance,
        funds_summary => summarize_funds(Funds),
        channel_summary => summarize_channels(Peers),
        failure_summary => summarize_failures(Failures),
        recent_failures => Failures,
        policy => #{
            max_ppm => State#state.max_ppm,
            auto_apply => State#state.auto_apply
        }
    }.

safe_cln(Fun) ->
    try Fun() of
        Result -> Result
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING("cln call failed ~p:~p ~p", [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

summarize_funds(#{channels := Channels, outputs := Outputs}) ->
    #{channels => length(Channels), outputs => length(Outputs)};
summarize_funds({error, _} = Error) ->
    Error;
summarize_funds(_) ->
    unknown.

summarize_channels(Channels) when is_list(Channels) ->
    lists:foldl(fun summarize_channel/2, #{count => 0, low_local => 0, high_local => 0}, Channels);
summarize_channels({error, _} = Error) ->
    Error;
summarize_channels(_) ->
    unknown.

summarize_channel(Chan, Acc0) when is_map(Chan) ->
    Acc1 = maps:update_with(count, fun(N) -> N + 1 end, 1, Acc0),
    Our = get_msat([our_amount_msat, <<"our_amount_msat">>], Chan, undefined),
    Total = get_msat(
        [amount_msat, <<"amount_msat">>, total_msat, <<"total_msat">>], Chan, undefined
    ),
    case {Our, Total} of
        {O, T} when is_integer(O), is_integer(T), T > 0 ->
            Ratio = O / T,
            Acc2 =
                case Ratio < 0.15 of
                    true -> maps:update_with(low_local, fun(N) -> N + 1 end, 1, Acc1);
                    false -> Acc1
                end,
            case Ratio > 0.85 of
                true -> maps:update_with(high_local, fun(N) -> N + 1 end, 1, Acc2);
                false -> Acc2
            end;
        _ ->
            Acc1
    end;
summarize_channel(_Other, Acc) ->
    Acc.

get_msat(Keys, Map, Default) ->
    case first_value(Keys, Map, Default) of
        I when is_integer(I) -> I;
        B when is_binary(B) -> parse_msat(B, Default);
        L when is_list(L) -> parse_msat(list_to_binary(L), Default);
        _ -> Default
    end.

first_value([], _Map, Default) ->
    Default;
first_value([K | Rest], Map, Default) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> first_value(Rest, Map, Default)
    end.

parse_msat(Bin0, Default) ->
    Bin = binary:replace(Bin0, <<"msat">>, <<>>, [global]),
    try
        binary_to_integer(Bin)
    catch
        _:_ -> Default
    end.

recent_failures(Pays0, SendPays0, Limit) ->
    Pays = normalize_pay_list(Pays0, pays),
    SendPays = normalize_pay_list(SendPays0, sendpays),
    Failed = [F || F <- Pays ++ SendPays, maps:get(status, F, undefined) =:= failed],
    Sorted = lists:sort(fun newer_failure/2, Failed),
    lists:sublist(Sorted, Limit).

normalize_pay_list(#{pays := Pays}, Source) when is_list(Pays) ->
    [normalize_payment(P, Source) || P <- Pays];
normalize_pay_list(#{payments := Pays}, Source) when is_list(Pays) ->
    [normalize_payment(P, Source) || P <- Pays];
normalize_pay_list(List, Source) when is_list(List) ->
    [normalize_payment(P, Source) || P <- List];
normalize_pay_list(_, _Source) ->
    [].

normalize_payment(P, Source) when is_map(P) ->
    Status = normalize_status(first_value([status, <<"status">>], P, undefined)),
    Reason = failure_reason(P),
    #{
        source => Source,
        status => Status,
        created_at => first_value([created_at, <<"created_at">>], P, 0),
        amount_msat => get_msat([amount_msat, <<"amount_msat">>], P, 0),
        amount_sent_msat => get_msat([amount_sent_msat, <<"amount_sent_msat">>], P, 0),
        payment_hash => first_value([payment_hash, <<"payment_hash">>], P, <<>>),
        reason => Reason,
        class => classify_reason(Reason)
    };
normalize_payment(Other, Source) ->
    #{source => Source, status => unknown, reason => term_to_binary(Other), class => unknown}.

normalize_status(failed) -> failed;
normalize_status(<<"failed">>) -> failed;
normalize_status("failed") -> failed;
normalize_status(complete) -> complete;
normalize_status(<<"complete">>) -> complete;
normalize_status("complete") -> complete;
normalize_status(pending) -> pending;
normalize_status(<<"pending">>) -> pending;
normalize_status("pending") -> pending;
normalize_status(Other) -> Other.

failure_reason(P) ->
    first_value(
        [
            error,
            <<"error">>,
            failreason,
            <<"failreason">>,
            message,
            <<"message">>,
            erroronion,
            <<"erroronion">>
        ],
        P,
        <<>>
    ).

newer_failure(A, B) ->
    maps:get(created_at, A, 0) >= maps:get(created_at, B, 0).

summarize_failures(Failures) ->
    lists:foldl(
        fun(F, Acc) ->
            Class = maps:get(class, F, unknown),
            maps:update_with(Class, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{total => length(Failures)},
        Failures
    ).

classify_reason(Reason0) ->
    Reason = string:lowercase(binary_to_list(to_bin(Reason0))),
    classify_reason_text(Reason).

classify_reason_text("") ->
    unknown;
classify_reason_text(Reason) ->
    Tests = [
        {"low fee", low_fee_percentage},
        {"insufficient capacity", insufficient_capacity},
        {"temporary channel failure", temporary_channel_failure},
        {"unknown next peer", bad_route},
        {"incorrect_or_unknown_payment_details", bad_invoice},
        {"timeout", timeout},
        {"route", no_route},
        {"capacity", insufficient_capacity},
        {"fee", fee_too_low}
    ],
    classify_reason_text(Reason, Tests).

classify_reason_text(_Reason, []) ->
    unknown;
classify_reason_text(Reason, [{Needle, Class} | Rest]) ->
    case string:find(Reason, Needle) of
        nomatch -> classify_reason_text(Reason, Rest);
        _ -> Class
    end.

%%====================================================================
%% Ollama advice
%%====================================================================

ask_for_advice(State, Snapshot) ->
    Prompt = build_prompt(State, Snapshot),
    case ollama_run(State#state.ollama_model, Prompt, ?OLLAMA_TIMEOUT_MS) of
        {ok, Raw} ->
            #{ok => true, raw => Raw, guarded => guard_advice(Raw, State)};
        {error, Reason} ->
            #{ok => false, error => Reason, fallback => fallback_advice(Snapshot, State)}
    end.

build_prompt(State, Snapshot) ->
    iolist_to_binary(
        io_lib:format(
            "You are advising a Core Lightning node operator.\n"
            "Return compact JSON only. Do not output shell commands.\n"
            "Allowed actions: wait, retry_rebalance, raise_max_fee, lower_own_fee, open_channel, do_nothing.\n"
            "Hard limits: max_ppm=~p, auto_apply=false unless explicitly set.\n"
            "Classify low-fee, capacity, no-route, and timeout failures.\n"
            "Recommend safe retry ppm bands and whether to wait for organic flow.\n"
            "Snapshot:~n~p~n",
            [State#state.max_ppm, Snapshot]
        )
    ).

ollama_run(Model, Prompt, TimeoutMs) ->
    case os:find_executable("ollama") of
        false ->
            {error, ollama_not_found};
        _Exe ->
            File = temp_prompt_file(),
            ok = file:write_file(File, Prompt),
            Cmd = ["ollama run ", sh_quote(Model), " < ", sh_quote(File), " 2>&1"],
            Port = open_port(
                {spawn, lists:flatten(Cmd)},
                [binary, exit_status, use_stdio, stderr_to_stdout]
            ),
            Res = collect_port(Port, TimeoutMs, []),
            _ = file:delete(File),
            Res
    end.

temp_prompt_file() ->
    filename:join(
        "/tmp",
        "cln_rebalance_monitor_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".prompt"
    ).

sh_quote(S0) ->
    S = binary_to_list(to_bin(S0)),
    "'" ++ string:replace(S, "'", "'\\''", all) ++ "'".

collect_port(Port, TimeoutMs, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, TimeoutMs, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, {ollama_exit, Status, iolist_to_binary(lists:reverse(Acc))}}
    after TimeoutMs ->
        catch port_close(Port),
        {error, ollama_timeout}
    end.

guard_advice(Raw, State) ->
    %% This module deliberately treats model output as advice, not authority.
    %% Any future command executor must parse JSON and enforce these limits first.
    #{
        max_ppm => State#state.max_ppm,
        auto_apply => State#state.auto_apply,
        model_output_bytes => byte_size(to_bin(Raw)),
        executable => false
    }.

fallback_advice(Snapshot, State) ->
    FailureSummary = maps:get(failure_summary, Snapshot, #{}),
    LowFee =
        maps:get(low_fee_percentage, FailureSummary, 0) + maps:get(fee_too_low, FailureSummary, 0),
    case LowFee > 0 of
        true ->
            #{
                action => retry_rebalance,
                max_ppm_suggestion => erlang:min(State#state.max_ppm, 250),
                reason => low_fee_failures_seen,
                risk => low,
                executable => false
            };
        false ->
            #{action => wait, reason => no_low_fee_pattern, risk => low, executable => false}
    end.

%%====================================================================
%% Utilities
%%====================================================================

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).
