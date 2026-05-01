%%%-------------------------------------------------------------------
%%% damage_balance_cache.erl
%%% Fast dashboard balances using Aeternity Middleware + SWR cache.
%%%
%%% Dashboard rule:
%%%   - return cached balance immediately when possible
%%%   - refresh in background when stale
%%%   - never mine a contract tx just to read a token balance
%%%-------------------------------------------------------------------
-module(damage_balance_cache).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([
    snapshot/1,
    snapshot/2,
    damage_balance/1,
    refresh/1,
    refresh_async/1,
    warm/1,
    invalidate/1,
    mark_dirty/1,
    debit_damage/2,
    credit_damage/2
]).

-define(TAB, ?MODULE).

-define(DEFAULT_FRESH_MS, 5000).
-define(DEFAULT_STALE_MS, 60000).
-define(DEFAULT_HARD_MS, 300000).
-define(DEFAULT_REQUEST_TIMEOUT_MS, 1500).
-define(DEFAULT_REFRESH_DELAY_MS, 2500).

%%====================================================================
%% Public API
%%====================================================================

snapshot(AeAccount) ->
    snapshot(AeAccount, []).

snapshot(AeAccount0, _Opts) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    Now = now_ms(),

    case ets:lookup(?TAB, {snapshot, AeAccount}) of
        [{{snapshot, AeAccount}, Snap0, FetchedAt, FreshUntil, _StaleUntil}] when
            Now =< FreshUntil
        ->
            annotate(Snap0, false, FetchedAt);
        [{{snapshot, AeAccount}, Snap0, FetchedAt, _FreshUntil, StaleUntil}] when
            Now =< StaleUntil
        ->
            refresh_async(AeAccount),
            annotate(Snap0, true, FetchedAt);
        Old ->
            case fetch_with_timeout(AeAccount, request_timeout_ms()) of
                {ok, Snap} ->
                    store_snapshot(AeAccount, Snap),
                    annotate(Snap, false, Now);
                {error, Reason} ->
                    case Old of
                        [{{snapshot, AeAccount}, Snap0, FetchedAt, _FreshUntil, _StaleUntil}] ->
                            ?LOG_WARNING("balance cache stale fallback account=~p reason=~p", [
                                AeAccount, Reason
                            ]),
                            annotate(
                                maps:put(error, format_error(Reason), Snap0),
                                true,
                                FetchedAt
                            );
                        _ ->
                            ?LOG_WARNING("balance cache miss account=~p reason=~p", [
                                AeAccount, Reason
                            ]),
                            default_snapshot(AeAccount, Reason)
                    end
            end
    end.

damage_balance(AeAccount) ->
    Snap = snapshot(AeAccount),
    maps:get(damage, Snap, maps:get(amount, Snap, 0)).

refresh(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    case fetch_with_timeout(AeAccount, request_timeout_ms()) of
        {ok, Snap} ->
            store_snapshot(AeAccount, Snap),
            {ok, Snap};
        Error ->
            Error
    end.

refresh_async(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    Now = now_ms(),
    case ets:insert_new(?TAB, {{refreshing, AeAccount}, self(), Now}) of
        true ->
            spawn(fun() ->
                try
                    case fetch_snapshot(AeAccount) of
                        {ok, Snap} ->
                            store_snapshot(AeAccount, Snap);
                        {error, Reason} ->
                            ?LOG_WARNING("balance async refresh failed account=~p reason=~p", [
                                AeAccount, Reason
                            ])
                    end
                catch
                    Class:Reason:Stack ->
                        ?LOG_ERROR("balance async refresh crashed ~p", [
                            #{
                                account => AeAccount,
                                class => Class,
                                reason => Reason,
                                stack => Stack
                            }
                        ])
                after
                    ets:delete(?TAB, {refreshing, AeAccount})
                end
            end),
            ok;
        false ->
            ok
    end.

warm(<<"ak_", _/binary>> = Account) ->
    refresh_async(Account);
warm([$a, $k, $_ | _] = Account) ->
    refresh_async(Account);
warm(Accounts) when is_list(Accounts) ->
    lists:foreach(fun refresh_async/1, Accounts),
    ok;
warm(Account) ->
    refresh_async(Account).

invalidate(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    ets:delete(?TAB, {snapshot, AeAccount}),
    ets:delete(?TAB, {refreshing, AeAccount}),
    ok.

%% Keep old value visible, force next read to return stale and refresh.
mark_dirty(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    Now = now_ms(),
    case ets:lookup(?TAB, {snapshot, AeAccount}) of
        [{{snapshot, AeAccount}, Snap, FetchedAt, _FreshUntil, StaleUntil}] ->
            ets:insert(?TAB, {
                {snapshot, AeAccount},
                maps:merge(Snap, #{stale => true, source => <<"dirty-cache">>}),
                FetchedAt,
                0,
                erlang:max(StaleUntil, Now + hard_ms())
            });
        _ ->
            ok
    end,
    delayed_refresh(AeAccount, refresh_delay_ms()).

debit_damage(AeAccount0, Amount0) ->
    AeAccount = normalize_account(AeAccount0),
    Amount = to_integer(Amount0),
    optimistic_damage_delta(AeAccount, -Amount),
    delayed_refresh(AeAccount, refresh_delay_ms()).

credit_damage(AeAccount0, Amount0) ->
    AeAccount = normalize_account(AeAccount0),
    Amount = to_integer(Amount0),
    optimistic_damage_delta(AeAccount, Amount),
    delayed_refresh(AeAccount, refresh_delay_ms()).

%%====================================================================
%% Fetching
%%====================================================================

fetch_with_timeout(AeAccount, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Pid =
        spawn(fun() ->
            Parent ! {Ref, catch fetch_snapshot(AeAccount)}
        end),
    receive
        {Ref, {ok, Snap}} ->
            {ok, Snap};
        {Ref, {error, Reason}} ->
            {error, Reason};
        {Ref, {'EXIT', Reason}} ->
            {error, Reason};
        {Ref, Other} ->
            {error, {bad_fetch_result, Other}}
    after TimeoutMs ->
        exit(Pid, kill),
        {error, timeout}
    end.

fetch_snapshot(AeAccount) ->
    Damage = fetch_damage_balance_mdw(AeAccount),
    Ae = fetch_ae_balance_fast(AeAccount),
    Ledger = fetch_sats_ledger(AeAccount),
    Msats = maps:get(balance_msat, Ledger, 0),
    Sats = Msats div 1000,

    {ok, #{
        status => <<"ok">>,
        id => AeAccount,
        address => AeAccount,

        %% Backwards-compatible field for older balance.js.
        amount => Damage,

        %% Raw smallest-unit values.
        damage => Damage,
        ae => Ae,
        balance_msat => Msats,
        sats => Sats,

        %% UI-friendly display values.
        damage_display => units(Damage, ?DAMAGE_DECIMALS),
        ae_display => units(Ae, ?AE_DECIMALS),

        source => <<"aemdw-cache">>,
        updated_at_ms => now_ms()
    }}.

fetch_damage_balance_mdw(AeAccount) ->
    case
        mdw_get_json(fun(PathPrefix) ->
            PathPrefix ++
                "v3/aex9/" ++ token_contract() ++
                "/balances/" ++ binary_to_list(AeAccount) ++
                mdw_top_query()
        end)
    of
        {ok, Json} ->
            extract_damage_amount(Json);
        {error, Reason} ->
            ?LOG_WARNING("mdw direct aex9 balance failed account=~p reason=~p", [
                AeAccount, Reason
            ]),
            fetch_damage_balance_from_account_list(AeAccount)
    end.

fetch_damage_balance_from_account_list(AeAccount) ->
    case
        mdw_get_json(fun(PathPrefix) ->
            PathPrefix ++
                "v3/accounts/" ++ binary_to_list(AeAccount) ++
                "/aex9/balances"
        end)
    of
        {ok, Json} ->
            extract_damage_amount(Json);
        {error, Reason} ->
            ?LOG_WARNING("mdw account aex9 balances failed account=~p reason=~p", [
                AeAccount, Reason
            ]),
            0
    end.

fetch_ae_balance_fast(AeAccount) ->
    case catch damage_ae:get_ae_balance(AeAccount) of
        #{balance := Balance} ->
            to_integer(Balance);
        #{<<"balance">> := Balance} ->
            to_integer(Balance);
        #{amount := Balance} ->
            to_integer(Balance);
        #{<<"amount">> := Balance} ->
            to_integer(Balance);
        Error ->
            ?LOG_DEBUG("ae balance fallback account=~p error=~p", [AeAccount, Error]),
            0
    end.

fetch_sats_ledger(AeAccount) ->
    case catch damage_nwc:ledger_balance_for_account_cached(AeAccount) of
        Ledger when is_map(Ledger) ->
            Ledger;
        _ ->
            #{balance_msat => 0}
    end.

%%====================================================================
%% Middleware HTTP
%%====================================================================

mdw_get_json(PathFun) ->
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            try
                Path = PathFun(PathPrefix),
                Headers = [{<<"accept">>, <<"application/json">>}],
                StreamRef = gun:get(ConnPid, Path, Headers),
                await_json(ConnPid, StreamRef, request_timeout_ms())
            after
                catch gun:close(ConnPid)
            end;
        Error ->
            {error, Error}
    end.

await_json(ConnPid, StreamRef, TimeoutMs) ->
    case gun:await(ConnPid, StreamRef, TimeoutMs) of
        {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
            case gun:await_body(ConnPid, StreamRef, TimeoutMs) of
                {ok, Body} ->
                    decode_json(Body);
                Error ->
                    {error, Error}
            end;
        {response, fin, Status, _Headers} when Status >= 200, Status < 300 ->
            {ok, #{}};
        {response, nofin, 404, _Headers} ->
            _ = gun:await_body(ConnPid, StreamRef, TimeoutMs),
            {ok, #{amount => 0}};
        {response, fin, 404, _Headers} ->
            {ok, #{amount => 0}};
        {response, nofin, Status, _Headers} ->
            Body =
                case gun:await_body(ConnPid, StreamRef, TimeoutMs) of
                    {ok, B} -> B;
                    _ -> <<>>
                end,
            {error, {http_status, Status, Body}};
        Other ->
            {error, Other}
    end.

decode_json(Body) ->
    case catch jsx:decode(Body, [return_maps, {labels, atom}]) of
        {'EXIT', Reason} ->
            {error, {json_decode_failed, Reason, Body}};
        Json ->
            {ok, Json}
    end.

%%====================================================================
%% Cache internals
%%====================================================================

stale_ms() ->
    env_int(balance_cache_stale_ms, ?DEFAULT_STALE_MS).
store_snapshot(AeAccount, Snap) ->
    ensure_table(),
    Now = now_ms(),
    ets:insert(?TAB, {
    {snapshot, AeAccount},
    Snap,
    Now,
    Now + fresh_ms(),
    Now + stale_ms()
}),
    ok.

optimistic_damage_delta(AeAccount0, Delta0) ->
    AeAccount = normalize_account(AeAccount0),
    Delta = to_integer(Delta0),
    ensure_table(),
    Now = now_ms(),
    case ets:lookup(?TAB, {snapshot, AeAccount}) of
        [{{snapshot, AeAccount}, Snap0, FetchedAt, _FreshUntil, StaleUntil}] ->
            Current = maps:get(damage, Snap0, maps:get(amount, Snap0, 0)),
            NewDamage = erlang:max(0, Current + Delta),
            Snap =
                maps:merge(Snap0, #{
                    amount => NewDamage,
                    damage => NewDamage,
                    damage_display => units(NewDamage, ?DAMAGE_DECIMALS),
                    stale => true,
                    source => <<"optimistic-cache">>,
                    updated_at_ms => Now
                }),
            ets:insert(?TAB, {
                {snapshot, AeAccount},
                Snap,
                FetchedAt,
                0,
                erlang:max(StaleUntil, Now + hard_ms())
            }),
            ok;
        _ ->
            refresh_async(AeAccount)
    end.

delayed_refresh(AeAccount, DelayMs) ->
    spawn(fun() ->
        timer:sleep(DelayMs),
        refresh_async(AeAccount)
    end),
    ok.

annotate(Snap, Stale, FetchedAt) ->
    maps:merge(Snap, #{
        stale => Stale,
        cached_at_ms => FetchedAt,
        age_ms => now_ms() - FetchedAt
    }).

default_snapshot(AeAccount, Reason) ->
    #{
        status => <<"error">>,
        id => AeAccount,
        address => AeAccount,
        amount => 0,
        damage => 0,
        ae => 0,
        sats => 0,
        balance_msat => 0,
        damage_display => 0.0,
        ae_display => 0.0,
        stale => true,
        source => <<"empty-cache">>,
        error => format_error(Reason),
        cached_at_ms => 0,
        age_ms => 0,
        updated_at_ms => now_ms()
    }.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            try
                ets:new(?TAB, [
                    named_table,
                    public,
                    set,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ]),
                ok
            catch
                error:badarg ->
                    ok
            end;
        _ ->
            ok
    end.

%%====================================================================
%% JSON shape handling
%%====================================================================

extract_damage_amount(#{amount := null}) ->
    0;
extract_damage_amount(#{amount := Amount}) ->
    to_integer(Amount);
extract_damage_amount(#{balance := Amount}) ->
    to_integer(Amount);
extract_damage_amount(#{<<"amount">> := Amount}) ->
    to_integer(Amount);
extract_damage_amount(#{<<"balance">> := Amount}) ->
    to_integer(Amount);
extract_damage_amount(#{data := Data}) when is_list(Data) ->
    extract_damage_amount_from_list(Data);
extract_damage_amount(#{<<"data">> := Data}) when is_list(Data) ->
    extract_damage_amount_from_list(Data);
extract_damage_amount(_) ->
    0.

extract_damage_amount_from_list([]) ->
    0;
extract_damage_amount_from_list([#{contract_id := Contract, amount := Amount} | Rest]) ->
    case to_list(Contract) =:= token_contract() of
        true -> to_integer(Amount);
        false -> extract_damage_amount_from_list(Rest)
    end;
extract_damage_amount_from_list([#{<<"contract_id">> := Contract, <<"amount">> := Amount} | Rest]) ->
    case to_list(Contract) =:= token_contract() of
        true -> to_integer(Amount);
        false -> extract_damage_amount_from_list(Rest)
    end;
extract_damage_amount_from_list([_ | Rest]) ->
    extract_damage_amount_from_list(Rest).

%%====================================================================
%% Config/helpers
%%====================================================================

mdw_top_query() ->
    %% Dashboard default should be MDW cache. Set true only for admin/debug.
    case env_bool(balance_cache_mdw_top, false) of
        true -> "?top=true";
        false -> ""
    end.

fresh_ms() ->
    env_int(balance_cache_fresh_ms, ?DEFAULT_FRESH_MS).

hard_ms() ->
    env_int(balance_cache_hard_ms, ?DEFAULT_HARD_MS).

request_timeout_ms() ->
    env_int(balance_cache_request_timeout_ms, ?DEFAULT_REQUEST_TIMEOUT_MS).

refresh_delay_ms() ->
    env_int(balance_cache_refresh_delay_ms, ?DEFAULT_REFRESH_DELAY_MS).

env_int(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, V} when is_integer(V) ->
            V;
        {ok, V} when is_binary(V) ->
            binary_to_integer(V);
        {ok, V} when is_list(V) ->
            list_to_integer(V);
        _ ->
            Default
    end.

env_bool(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, true} -> true;
        {ok, <<"true">>} -> true;
        {ok, "true"} -> true;
        {ok, false} -> false;
        {ok, <<"false">>} -> false;
        {ok, "false"} -> false;
        _ -> Default
    end.

token_contract() ->
    to_list(?DAMAGE_TOKEN_CONTRACT).

normalize_account(AeAccount) when is_binary(AeAccount) ->
    AeAccount;
normalize_account(AeAccount) when is_list(AeAccount) ->
    list_to_binary(AeAccount).

to_list(V) when is_binary(V) ->
    binary_to_list(V);
to_list(V) when is_list(V) ->
    V;
to_list(V) ->
    lists:flatten(io_lib:format("~p", [V])).

to_integer(null) ->
    0;
to_integer(undefined) ->
    0;
to_integer(V) when is_integer(V) ->
    V;
to_integer(V) when is_float(V) ->
    round(V);
to_integer(V) when is_binary(V) ->
    binary_to_integer(V);
to_integer(V) when is_list(V) ->
    list_to_integer(V).

units(Amount, Decimals) ->
    Amount / math:pow(10, Decimals).

format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) ->
    list_to_binary(lists:flatten(io_lib:format("~p", [Reason]))).

now_ms() ->
    erlang:monotonic_time(millisecond).
