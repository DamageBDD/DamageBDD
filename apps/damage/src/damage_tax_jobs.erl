%%% Asynchronous, admin-triggered CLN history backfill and draft FY reporting.
%%% Performs all network IO outside the gen_server and never signs/mints.
-module(damage_tax_jobs).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, backfill/1, status/0, execute/1, years/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
backfill(Scope) -> gen_server:call(?MODULE, {backfill, Scope}, 5000).
status() -> gen_server:call(?MODULE, status, 5000).

init([]) ->
    case application:get_env(damage, tax_backfill_on_start, false) of
        true -> erlang:send_after(1000, self(), initial_backfill);
        _ -> ok
    end,
    {ok, #{job => #{status => <<"idle">>}, worker => undefined, monitor => undefined}}.

handle_call(status, _From, State) ->
    {reply, maps:get(job, State), State};
handle_call({backfill, Scope}, _From, State) ->
    case valid_scope(Scope) of
        false -> {reply, {error, invalid_tax_year}, State};
        true ->
            case start_job(Scope, State) of
                {ok, Next} -> {reply, {ok, started}, Next};
                {error, Why} -> {reply, {error, Why}, State}
            end
    end;
handle_call(_Other, _From, State) -> {reply, {error, unsupported}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(initial_backfill, State) ->
    case start_job(all, State) of
        {ok, Next} -> {noreply, Next};
        {error, Reason} ->
            ?LOG_WARNING("Initial tax backfill not started: ~p", [Reason]),
            {noreply, State}
    end;
handle_info({tax_backfill_result, Pid, Result}, #{worker := Pid} = State) ->
    Ref = maps:get(monitor, State),
    erlang:demonitor(Ref, [flush]),
    Job0 = maps:get(job, State),
    Job = case Result of
        {ok, Summary} -> maps:merge(Job0, Summary#{status => <<"completed">>});
        {error, Reason} -> Job0#{status => <<"failed">>, error => safe_reason(Reason)}
    end,
    {noreply, State#{job => Job#{finished_at => erlang:system_time(second)},
                     worker => undefined, monitor => undefined}};
handle_info({'DOWN', Ref, process, Pid, Reason},
            #{worker := Pid, monitor := Ref} = State) when Reason =/= normal ->
    Job0 = maps:get(job, State),
    Job = Job0#{status => <<"failed">>,
                 error => <<"worker_terminated_before_completion">>,
                 finished_at => erlang:system_time(second)},
    ?LOG_ERROR("Tax backfill worker exited: ~p", [Reason]),
    {noreply, State#{job => Job, worker => undefined, monitor => undefined}};
handle_info({'DOWN', _Ref, process, _Pid, normal}, State) ->
    {noreply, State};
handle_info(_, State) -> {noreply, State}.

terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

start_job(_Scope, #{worker := Pid}) when is_pid(Pid) -> {error, backfill_running};
start_job(Scope, State) ->
    case application:get_env(damage, tax_cln_owner, undefined) of
        Tenant when is_binary(Tenant), byte_size(Tenant) > 0 ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(fun() ->
                Result = try execute(Scope) of
                    R -> R
                catch
                    Class:Reason:Stack ->
                        ?LOG_ERROR("Tax backfill failed ~p:~p at ~p", [Class, Reason, Stack]),
                        {error, {job_crashed, Class}}
                end,
                Parent ! {tax_backfill_result, self(), Result}
            end),
            Job = #{status => <<"running">>, scope => scope_binary(Scope),
                    started_at => erlang:system_time(second),
                    owner_hash => damage_tax_canonical:sha256_hex(Tenant)},
            {ok, State#{worker => Pid, monitor => Ref, job => Job}};
        _ -> {error, tax_cln_owner_not_configured}
    end.

%% execute/1 is exported for operator-driven CLI and test invocations.
execute(Scope) ->
    Tenant = application:get_env(damage, tax_cln_owner, undefined),
    Ingest = case Scope of
        {existing, _YearScope} -> {ok, 0};
        _ -> damage_tax:ingest_cln(Tenant)
    end,
    case Ingest of
        {ok, NewlyImported} ->
            case damage_tax:records(Tenant) of
                {ok, []} -> {error, no_settled_cln_transactions};
                {ok, Events} ->
                    Offset = standard_offset(),
                    AllYears = years(Events, Offset),
                    Selected = case unwrap_scope(Scope) of
                        all -> AllYears;
                        Year when is_integer(Year) -> [Year]
                    end,
                    Budget = limit(tax_max_prices_per_backfill, 200, 1, 500),
                    Result = lists:foldl(fun(Year, Acc) ->
                        prepare_year(Tenant, Year, Offset, Events, Acc)
                    end, #{remaining_budget => Budget, reports => [],
                           quote_failures => [], price_requests => 0}, Selected),
                    {ok, #{imported_new_events => NewlyImported,
                           source_events => length(Events),
                           reports => lists:reverse(maps:get(reports, Result)),
                           quote_failures => lists:reverse(maps:get(quote_failures, Result)),
                           price_requests => maps:get(price_requests, Result),
                           prices_remaining_budget => maps:get(remaining_budget, Result)}};
                Error -> Error
            end;
        Error -> Error
    end.

prepare_year(Tenant, Year, Offset, Events, Acc0) ->
    {Start, End} = damage_tax_report:fy_bounds(Year, Offset),
    Selected = [E || E <- Events,
                 maps:get(<<"occurred_at">>, E) >= Start,
                 maps:get(<<"occurred_at">>, E) < End],
    case Selected of
        [] -> Acc0;
        _ ->
            Keys = damage_tax_report:required_prices(Selected, Year, Offset),
            {Quotes, Acc1} = lists:foldl(fun(Key, {QAcc, A}) ->
                quote_for(Key, QAcc, A)
            end, {#{}, Acc0}, Keys),
            %% Never silently infer income, expenses, CGT, GST or tax advice.
            case damage_tax_report:build(Year, Offset, Selected, Quotes, #{}) of
                {ok, Report} ->
                    case damage_tax_catalog:save_report(Tenant, Report) of
                        {ok, Meta} ->
                            Acc1#{reports => [Meta | maps:get(reports, Acc1)]};
                        {error, Why} ->
                            add_failure(Acc1, {report_save, Year, Why})
                    end;
                {error, Why} -> add_failure(Acc1, {report_build, Year, Why})
            end
    end.

quote_for(Key, Quotes, Acc) ->
    case damage_tax_catalog:load_quote(Key) of
        {ok, Quote} -> {maps:put(Key, Quote, Quotes), Acc};
        not_found -> fetch_if_budget(Key, Quotes, Acc);
        {error, Why} -> {Quotes, add_failure(Acc, {bad_quote_cache, Key, Why})}
    end.

fetch_if_budget(Key, Quotes, #{remaining_budget := 0} = Acc) ->
    {Quotes, add_failure(Acc, {price_budget_exhausted, Key})};
fetch_if_budget({Asset, Hour} = Key, Quotes, Acc) ->
    A1 = Acc#{remaining_budget => maps:get(remaining_budget, Acc) - 1,
              price_requests => maps:get(price_requests, Acc) + 1},
    Reply = damage_tax:fetch_and_archive_quote(cryptocompare, Asset, Hour),
    case Reply of
        {ok, Quote} ->
            case damage_tax_catalog:save_quote(Key, Quote) of
                ok ->
                    %% Pause between public API requests to avoid hammering providers.
                    timer:sleep(limit(tax_price_pause_ms, 250, 0, 5000)),
                    {maps:put(Key, Quote, Quotes), A1};
                Error -> {Quotes, add_failure(A1, {cache_quote, Key, Error})}
            end;
        {error, Reason} ->
            {Quotes, add_failure(A1, {fetch_quote, Key, Reason})}
    end.

-spec years([map()], integer()) -> [integer()].
years(Events, OffsetMinutes) ->
    lists:usort([fiscal_year(maps:get(<<"occurred_at">>, E), OffsetMinutes)
                 || E <- Events]).

fiscal_year(Ts, OffsetMinutes) ->
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    {{Year, Month, _Day}, _} = calendar:gregorian_seconds_to_datetime(
        Epoch + Ts + OffsetMinutes * 60),
    case Month >= 7 of true -> Year + 1; false -> Year end.

standard_offset() ->
    limit(tax_standard_utc_offset_minutes, 600, 0, 840).
limit(Key, Default, Min, Max) ->
    V = application:get_env(damage, Key, Default),
    case is_integer(V) andalso V >= Min andalso V =< Max of
        true -> V;
        false -> Default
    end.
valid_scope({existing, Scope}) -> valid_scope(Scope);
valid_scope(all) -> true;
valid_scope(Y) when is_integer(Y) -> Y >= 2009 andalso Y =< 2200;
valid_scope(_) -> false.
unwrap_scope({existing, Scope}) -> Scope;
unwrap_scope(Scope) -> Scope.
scope_binary({existing, Scope}) -> <<"journal:", (scope_binary(Scope))/binary>>;
scope_binary(all) -> <<"all">>;
scope_binary(Y) -> integer_to_binary(Y).
add_failure(Acc, Reason) ->
    Failures = maps:get(quote_failures, Acc),
    case length(Failures) >= 100 of
        true -> Acc;
        false -> Acc#{quote_failures => [safe_reason(Reason) | Failures]}
    end.
safe_reason(Why) ->
    B = iolist_to_binary(io_lib:format("~p", [Why])),
    binary:part(B, 0, erlang:min(byte_size(B), 500)).
