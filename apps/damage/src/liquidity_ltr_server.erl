-module(liquidity_ltr_server).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, get_ltr/0, get_full/0, refresh/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(FRED_HOST, "api.stlouisfed.org").
-define(FRED_PORT, 443).
-define(FRED_PATH, "/fred/series/observations").
-define(FRED_START, "2018-01-01").
-define(FRED_TIMEOUT, 30000).
%% 1h refresh; tune as you like
-define(REFRESH_MS, 3600 * 1000).

-record(state, {
    ltr :: undefined | float(),
    components :: map() | undefined,
    last_ok :: calendar:datetime() | undefined
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Get just the latest LTR (float() | undefined)
get_ltr() ->
    gen_server:call(?MODULE, get_ltr).

%% Get full map of components (C1..C4, LTR_raw, LTR, last_ok, etc.)
get_full() ->
    gen_server:call(?MODULE, get_full).

%% Force immediate refresh (async)
refresh() ->
    gen_server:cast(?MODULE, refresh).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Kick off an immediate refresh
    self() ! refresh,
    {ok, #state{ltr = undefined, components = undefined, last_ok = undefined}}.

handle_call(get_ltr, _From, State = #state{ltr = LTR}) ->
    {reply, LTR, State};
handle_call(get_full, _From, State = #state{components = C}) ->
    {reply, C, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(refresh, State) ->
    {noreply, safe_do_refresh(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh, State) ->
    {noreply, safe_do_refresh(State)};
handle_info(_Info, State) ->
    {noreply, State}.

safe_do_refresh(State) ->
    try
        do_refresh(State)
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING("liquidity_ltr_server refresh failed: ~p:~p ~p", [Class, Reason, Stack]),
            erlang:send_after(5 * 60 * 1000, self(), refresh),
            State
    end.

terminate(Reason, _State) ->
    ?LOG_INFO("liquidity_ltr_server terminating: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal Refresh Logic
%%%===================================================================

do_refresh(State) ->
    case compute_liquidity_tightness() of
        {ok, Map = #{ltr := LTR}} ->
            %?LOG_DEBUG("Updated Liquidity Tightness Rating to ~p", [LTR]),
            erlang:send_after(?REFRESH_MS, self(), refresh),
            State#state{
                ltr = LTR,
                components = Map,
                last_ok = calendar:local_time()
            };
        {error, Reason} ->
            ?LOG_WARNING("Failed to compute LTR: ~p", [Reason]),
            %% retry sooner on failure
            erlang:send_after(5 * 60 * 1000, self(), refresh),
            State
    end.

%%%===================================================================
%%% Core LTR computation (ported from liquidity_factor.py)
%%%===================================================================

compute_liquidity_tightness() ->
    FredKey = fred_api_key(),
    case FredKey of
        undefined ->
            {error, missing_fred_api_key};
        _ ->
            case fetch_required_series(FredKey) of
                {ok, #{sofr := Sofr, iorb := Iorb, srf := SrfMin, rrp := OnRrp, repo := RepoOps}} ->
                    try
                        {Sofr1, Iorb1, Srf1, Rrp1, Repo1} =
                            align_series([Sofr, Iorb, SrfMin, OnRrp, RepoOps]),

                        C1Base = lists:zipwith(fun(S, I) -> S - I end, Sofr1, Iorb1),
                        C2Base = lists:zipwith(fun(Srf, S) -> Srf - S end, Srf1, Sofr1),
                        C3Base = [math:log(1 + max(R, 0.0)) || R <- Rrp1],
                        C4Base =
                            case sum_abs(Repo1) of
                                -0.0 -> lists:duplicate(length(Repo1), 0.0);
                                +0.0 -> lists:duplicate(length(Repo1), 0.0);
                                _ -> Repo1
                            end,

                        C1 = zscore(C1Base),
                        C2 = zscore_neg(C2Base),
                        C3 = zscore_neg(C3Base),
                        C4 = zscore(C4Base),

                        Zipped12 = lists:zip(C1, C2),
                        Zipped34 = lists:zip(C3, C4),
                        ZipList = lists:zipwith(
                            fun({A, B}, {C, D}) -> {A, B, C, D} end,
                            Zipped12,
                            Zipped34
                        ),
                        LTRRawList = lists:zipwith(
                            fun({C1v, C2v, C3v, C4v}, _Acc) ->
                                (0.40 * C1v + 0.25 * C2v + 0.25 * C3v + 0.10 * C4v)
                            end,
                            ZipList,
                            C1
                        ),

                        case LTRRawList of
                            [] ->
                                {error, empty_series_after_alignment};
                            _ ->
                                LTRRaw = lists:last(LTRRawList),
                                LTR0 = 50 + 15 * LTRRaw,
                                LTR = clamp(LTR0, 0.0, 100.0),
                                {ok, #{
                                    c1_base => C1Base,
                                    c2_base => C2Base,
                                    c3_base => C3Base,
                                    c4_base => C4Base,
                                    c1_last => lists:last(C1),
                                    c2_last => lists:last(C2),
                                    c3_last => lists:last(C3),
                                    c4_last => lists:last(C4),
                                    ltr_raw => LTRRaw,
                                    ltr => LTR
                                }}
                        end
                    catch
                        Class:Err:Stack ->
                            ?LOG_ERROR("LTR computation failed: ~p ~p ~p", [Class, Err, Stack]),
                            {error, {Class, Err}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

fetch_required_series(FredKey) ->
    case fetch_series("SOFR", FredKey) of
        {ok, Sofr} ->
            case fetch_series("IORB", FredKey) of
                {ok, Iorb} ->
                    case fetch_series("SRFTSYD", FredKey) of
                        {ok, SrfMin} ->
                            case fetch_series("RRPONTSYD", FredKey) of
                                {ok, OnRrp} ->
                                    RepoOps =
                                        case fetch_series("RPONTSYD", FredKey) of
                                            {ok, R} -> R;
                                            {error, _} -> []
                                        end,
                                    {ok, #{
                                        sofr => Sofr,
                                        iorb => Iorb,
                                        srf => SrfMin,
                                        rrp => OnRrp,
                                        repo => RepoOps
                                    }};
                                {error, Reason} ->
                                    {error, {fred_series_failed, <<"RRPONTSYD">>, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {fred_series_failed, <<"SRFTSYD">>, Reason}}
                    end;
                {error, Reason} ->
                    {error, {fred_series_failed, <<"IORB">>, Reason}}
            end;
        {error, Reason} ->
            {error, {fred_series_failed, <<"SOFR">>, Reason}}
    end.

%%%===================================================================
%%% FRED HTTP via gun
%%%===================================================================

fred_api_key() ->
    case secrets:retrieve_decrypt(fred_api_key) of
        false -> undefined;
        error -> undefined;
        {ok, Key} -> Key
    end.

fetch_series(SeriesId0, ApiKey) when is_list(SeriesId0) ->
    fetch_series(list_to_binary(SeriesId0), ApiKey);
fetch_series(SeriesId, ApiKey) when is_binary(SeriesId) ->
    Host = ?FRED_HOST,
    Port = ?FRED_PORT,
    Path = fred_path(SeriesId, ApiKey),
    Opts = #{transport => tls, tls_opts => [{verify, verify_none}]},
    try
        case gun:open(Host, Port, Opts) of
            {ok, ConnPid} ->
                do_fetch_series(ConnPid, Path);
            Error ->
                {error, Error}
        end
    catch
        exit:{noproc, _} ->
            {error, dependency_gone};
        exit:noproc ->
            {error, dependency_gone};
        exit:{shutdown, _} ->
            {error, shutting_down};
        exit:shutdown ->
            {error, shutting_down};
        Class:Reason:Stack ->
            ?LOG_WARNING(
                "FRED fetch crashed for ~p: ~p:~p ~p",
                [SeriesId, Class, Reason, Stack]
            ),
            {error, {Class, Reason}}
    end.

do_fetch_series(ConnPid, Path) ->
    Headers = [{<<"accept">>, <<"application/json">>}],
    try
        StreamRef = gun:get(ConnPid, Path, Headers),
        Result =
            case gun:await(ConnPid, StreamRef, ?FRED_TIMEOUT) of
                {response, nofin, 200, _RespHeaders} ->
                    case gun:await_body(ConnPid, StreamRef) of
                        {ok, Body} ->
                            decode_series(Body);
                        Error ->
                            {error, {await_body_failed, Error}}
                    end;
                {response, _Fin, Status, _RespHeaders} ->
                    {error, {http_status, Status}};
                Other ->
                    {error, {unexpected, Other}}
            end,
        safe_gun_close(ConnPid),
        Result
    catch
        exit:{noproc, _} ->
            safe_gun_close(ConnPid),
            {error, dependency_gone};
        exit:noproc ->
            safe_gun_close(ConnPid),
            {error, dependency_gone};
        exit:{shutdown, _} ->
            safe_gun_close(ConnPid),
            {error, shutting_down};
        exit:shutdown ->
            safe_gun_close(ConnPid),
            {error, shutting_down};
        Class:Reason:Stack ->
            safe_gun_close(ConnPid),
            ?LOG_WARNING("FRED request failed: ~p:~p ~p", [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

safe_gun_close(ConnPid) ->
    try
        gun:close(ConnPid)
    catch
        _:_ -> ok
    end.

fred_path(SeriesId, ApiKey) ->
    %% "/fred/series/observations?series_id=SOFR&api_key=...&file_type=json&observation_start=2018-01-01"
    Q = io_lib:format(
        "~s?series_id=~s&api_key=~s&file_type=json&observation_start=~s",
        [?FRED_PATH, binary_to_list(SeriesId), ApiKey, ?FRED_START]
    ),
    lists:flatten(Q).

decode_series(Body) when is_binary(Body) ->
    Json = jsx:decode(Body, [return_maps]),
    Observations = maps:get(<<"observations">>, Json, []),
    %% Keep only numeric values; drop ".", ""
    Values =
        [
            to_float(maps:get(<<"value">>, Obs, <<"">>))
         || Obs <- Observations
        ],
    {ok, Values}.

to_float(Bin) when is_binary(Bin) ->
    try
        list_to_float(binary_to_list(Bin))
    catch
        _:_ -> 0.0
    end.

%%%===================================================================
%%% Math helpers (z-score, alignment, etc.)
%%%===================================================================

align_series(ListOfLists) ->
    %% Trim all lists from the left so they have same length N = min length
    Lengths = [length(L) || L <- ListOfLists],
    N = lists:min(Lengths),
    Trim = fun(L) -> drop_left(length(L) - N, L) end,
    [S1, S2, S3, S4, S5] = [Trim(L) || L <- ListOfLists],
    {S1, S2, S3, S4, S5}.

drop_left(N, L) when N =< 0 -> L;
drop_left(N, L) -> lists:nthtail(N, L).

zscore(List) ->
    {Mu, Sd} = mean_std(List),
    case Sd == 0.0 orelse Sd =:= undefined of
        true -> [0.0 || _ <- List];
        false -> [(X - Mu) / Sd || X <- List]
    end.

zscore_neg(List) ->
    [-Z || Z <- zscore(List)].

mean_std([]) ->
    {0.0, 0.0};
mean_std(List) ->
    N = length(List),
    Sum = lists:sum(List),
    Mu = Sum / N,
    Var = variance(List, Mu, N),
    Sd = math:sqrt(Var),
    {Mu, Sd}.

variance(_, _Mu, 0) ->
    0.0;
variance(List, Mu, N) ->
    Sq = lists:sum([(X - Mu) * (X - Mu) || X <- List]),
    Sq / N.

sum_abs(List) ->
    lists:sum([abs(X) || X <- List]).

clamp(X, Min, _Max) when X < Min -> Min;
clamp(X, _Min, Max) when X > Max -> Max;
clamp(X, _Min, _Max) -> X.
