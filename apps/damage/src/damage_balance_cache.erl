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

-behaviour(gen_server).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
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
    credit_damage/2,
    execution_damage_balance/1,
    has_enough_damage/2,
    fetch_sats_ledger/1,
    fetch_damage_balance_mdw/1
]).

-define(TAB, damage_balance_cache_ets).

-define(DEFAULT_FRESH_MS, 5000).
-define(DEFAULT_STALE_MS, 60000).
-define(DEFAULT_HARD_MS, 300000).
-define(DEFAULT_REQUEST_TIMEOUT_MS, 60000).
-define(DEFAULT_REFRESH_DELAY_MS, 2500).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    create_table(),
    {ok, #{}}.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
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
    execution_damage_balance(AeAccount).

%% Execution billing must look only at the DAMAGE token balance.
%% AE balance and sats/NWC ledger balance are dashboard fields only and must
%% never make an execution pass or fail.
execution_damage_balance(AeAccount) ->
    damage_from_snapshot(snapshot(AeAccount)).

%% Return a DAMAGE-only balance decision.  On an apparent miss/low balance,
%% force one foreground refresh before rejecting so a stale cache cannot create
%% a false 402 for a funded account.
has_enough_damage(AeAccount0, Required0) ->
    AeAccount = normalize_account(AeAccount0),
    Required = to_integer_ceil(Required0),
    Snap0 = snapshot(AeAccount),
    Balance0 = damage_from_snapshot(Snap0),
    case Balance0 >= Required of
        true ->
            {ok, Balance0, Snap0};
        false ->
            case refresh_execution(AeAccount) of
                {ok, Snap1} ->
                    Balance1 = damage_from_snapshot(Snap1),
                    case Balance1 >= Required of
                        true -> {ok, Balance1, Snap1};
                        false -> {error, insufficient_damage, Balance1, Snap1}
                    end;
                {error, Reason} ->
                    {error, insufficient_damage, Balance0,
                        maps:put(error, format_error(Reason), Snap0)}
            end
    end.

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

refresh_execution(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    ensure_table(),
    case fetch_with_timeout(AeAccount, request_timeout_ms(), true) of
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
                    Class:Reason0:Stack ->
                        ?LOG_ERROR("balance async refresh crashed ~p", [
                            #{
                                account => AeAccount,
                                class => Class,
                                reason => Reason0,
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
    fetch_with_timeout(AeAccount, TimeoutMs, false).

fetch_with_timeout(AeAccount, TimeoutMs, ForceTop) ->
    Parent = self(),
    Ref = make_ref(),
    Pid =
        spawn(fun() ->
            Parent !
                {Ref,
                    try fetch_snapshot(AeAccount, ForceTop) of
                        Result -> Result
                    catch
                        Class:Reason:Stack ->
                            {error, {Class, Reason, Stack}}
                    end}
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
    fetch_snapshot(AeAccount, false).

fetch_snapshot(AeAccount, ForceTop) ->
    Damage = fetch_damage_balance_mdw(AeAccount, ForceTop),
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
    fetch_damage_balance_mdw(AeAccount, false).

fetch_damage_balance_mdw(AeAccount, ForceTop) ->
    Contract = token_contract(),
    case
        mdw_get_json(fun(PathPrefix) ->
            PathPrefix ++
                "v3/aex9/" ++ Contract ++
                "/balances/" ++ binary_to_list(AeAccount) ++
                mdw_top_query(ForceTop)
        end)
    of
        {ok, Json} ->
            extract_damage_amount(Json, Contract);
        {error, Reason} ->
            ?LOG_WARNING(
                "mdw damage contract balance failed account=~p contract=~s reason=~p",
                [AeAccount, Contract, Reason]
            ),
            fetch_damage_balance_from_account_list(AeAccount, Contract)
    end.

fetch_damage_balance_from_account_list(AeAccount, Contract) ->
    case
        mdw_get_json(fun(PathPrefix) ->
            PathPrefix ++
                "v3/accounts/" ++ binary_to_list(AeAccount) ++
                "/aex9/balances"
        end)
    of
        {ok, Json} ->
            extract_damage_amount(Json, Contract);
        {error, Reason} ->
            ?LOG_WARNING(
                "mdw account aex9 fallback failed account=~p contract=~s reason=~p",
                [AeAccount, Contract, Reason]
            ),
            0
    end.

fetch_ae_balance_fast(AeAccount) ->
    try damage_ae:get_ae_balance(AeAccount) of
        #{balance := Balance} ->
            to_integer(Balance);
        #{<<"balance">> := Balance} ->
            to_integer(Balance);
        #{amount := Balance} ->
            to_integer(Balance);
        #{<<"amount">> := Balance} ->
            to_integer(Balance)
    catch
        _Class:Reason:_Stack ->
            ?LOG_DEBUG("ae balance fallback account=~p error=~p", [AeAccount, Reason]),
            0
    end.

fetch_sats_ledger(AeAccount) ->
    try damage_nwc:ledger_balance_for_account_cached(AeAccount) of
        #{balance_msat := _} = Ledger ->
            Ledger;
        #{<<"balance_msat">> := Msats} = Ledger ->
            maps:put(balance_msat, to_integer(Msats), Ledger);
        Msats when is_integer(Msats) ->
            #{balance_msat => Msats};
        Other ->
            ?LOG_DEBUG("NWC ledger balance unavailable for account=~p result=~p", [
                AeAccount, Other
            ]),
            #{balance_msat => 0, nwc_status => <<"unavailable">>}
    catch
        _:{invalid_hex64, _} ->
            #{balance_msat => 0, nwc_status => <<"not_nwc_client">>};
        _:{{invalid_hex64, _}, _} ->
            #{balance_msat => 0, nwc_status => <<"not_nwc_client">>};
        Class:Reason:Stack ->
            ?LOG_DEBUG("NWC ledger balance failed account=~p error=~p", [
                AeAccount,
                #{class => Class, reason => Reason, stack => Stack}
            ]),
            #{balance_msat => 0, nwc_status => <<"error">>}
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
                try
                    gun:close(ConnPid)
                catch
                    _Class:_Reason:_Stack -> ok
                end
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
    try jsx:decode(Body, [return_maps, {labels, atom}]) of
        Json ->
            {ok, Json}
    catch
        Class:Reason:_Stack ->
            {error, {json_decode_failed, {Class, Reason}, Body}}
    end.

%%====================================================================
%% Cache internals
%%====================================================================

store_snapshot(AeAccount, Snap) ->
    ensure_table(),
    Now = now_ms(),
    ets:insert(?TAB, {
        {snapshot, AeAccount},
        Snap,
        Now,
        Now + fresh_ms(),
        Now + hard_ms()
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
                    case ets:info(?TAB, protection) of
                        public ->
                            ok;
                        Protection ->
                            exit({balance_cache_bad_ets_protection, ?TAB, Protection})
                    end
            end;
        _ ->
            case ets:info(?TAB, protection) of
                public ->
                    ok;
                Protection ->
                    exit({balance_cache_bad_ets_protection, ?TAB, Protection})
            end
    end.

create_table() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

%%====================================================================
%% JSON shape handling
%%====================================================================

extract_damage_amount(#{amount := null}, _Contract) ->
    0;
extract_damage_amount(#{<<"amount">> := null}, _Contract) ->
    0;
%% Direct endpoint:
%% /v3/aex9/<contract>/balances/<account>
extract_damage_amount(#{contract := Contract0, amount := Amount}, Contract) ->
    case to_list(Contract0) =:= Contract of
        true -> to_integer(Amount);
        false -> 0
    end;
extract_damage_amount(#{<<"contract">> := Contract0, <<"amount">> := Amount}, Contract) ->
    case to_list(Contract0) =:= Contract of
        true -> to_integer(Amount);
        false -> 0
    end;
%% Some MDW/client shapes use contract_id.
extract_damage_amount(#{contract_id := Contract0, amount := Amount}, Contract) ->
    case to_list(Contract0) =:= Contract of
        true -> to_integer(Amount);
        false -> 0
    end;
extract_damage_amount(#{<<"contract_id">> := Contract0, <<"amount">> := Amount}, Contract) ->
    case to_list(Contract0) =:= Contract of
        true -> to_integer(Amount);
        false -> 0
    end;
%% Fallback list endpoint.
extract_damage_amount(#{data := Data}, Contract) when is_list(Data) ->
    extract_damage_amount_from_list(Data, Contract);
extract_damage_amount(#{<<"data">> := Data}, Contract) when is_list(Data) ->
    extract_damage_amount_from_list(Data, Contract);
%% If direct endpoint returns only amount, trust it because the path already
%% included the DAMAGE contract.
extract_damage_amount(#{amount := Amount}, _Contract) ->
    to_integer(Amount);
extract_damage_amount(#{<<"amount">> := Amount}, _Contract) ->
    to_integer(Amount);
extract_damage_amount(_, _Contract) ->
    0.

extract_damage_amount_from_list([], _Contract) ->
    0;
extract_damage_amount_from_list([Item | Rest], Contract) when is_map(Item) ->
    case extract_damage_amount(Item, Contract) of
        0 -> extract_damage_amount_from_list(Rest, Contract);
        Amount -> Amount
    end;
extract_damage_amount_from_list([_ | Rest], Contract) ->
    extract_damage_amount_from_list(Rest, Contract).

%%====================================================================
%% Config/helpers
%%====================================================================

mdw_top_query(ForceTop) ->
    case ForceTop of
        true -> "?top=true";
        false -> mdw_top_query()
    end.

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
    case application:get_env(damage, damage_token_contract) of
        {ok, Contract} ->
            to_list(Contract);
        _ ->
            to_list(?DAMAGE_TOKEN_CONTRACT)
    end.

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

to_integer_ceil(V) when is_integer(V) ->
    V;
to_integer_ceil(V) when is_float(V) ->
    T = trunc(V),
    case V > T of
        true -> T + 1;
        false -> T
    end;
to_integer_ceil(V) when is_binary(V) ->
    to_integer_ceil(binary_to_integer(V));
to_integer_ceil(V) when is_list(V) ->
    to_integer_ceil(list_to_integer(V));
to_integer_ceil(null) ->
    0;
to_integer_ceil(undefined) ->
    0.

damage_from_snapshot(#{damage := Damage}) ->
    to_integer(Damage);
damage_from_snapshot(#{<<"damage">> := Damage}) ->
    to_integer(Damage);
damage_from_snapshot(_Snap) ->
    0.

units(Amount, Decimals) ->
    Amount / math:pow(10, Decimals).

format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) ->
    list_to_binary(lists:flatten(io_lib:format("~p", [Reason]))).

now_ms() ->
    erlang:system_time(millisecond).
