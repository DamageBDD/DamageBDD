%% damage_nsecbunker_rate.erl

-module(damage_nsecbunker_rate).

-behaviour(gen_server).

-export([start_link/0, check_and_mark/4, seed/3, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([backend/0]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec check_and_mark(binary(), non_neg_integer(), pos_integer(), pos_integer()) ->
    ok | {error, rate_limited}.
check_and_mark(RequesterPubkey, NowUnix, MaxRequests, WindowSeconds) ->
    case backend() of
        throttle ->
            check_throttle(RequesterPubkey);
        ets ->
            gen_server:call(
                ?SERVER, {check_and_mark, RequesterPubkey, NowUnix, MaxRequests, WindowSeconds}
            )
    end.

check_throttle(RequesterPubkey) ->
    case throttle:check(damage_nsecbunker_rate, RequesterPubkey) of
        {limit_exceeded, _, _} -> {error, rate_limited};
        _ -> ok
    end.

-spec seed(binary(), non_neg_integer(), non_neg_integer()) -> ok.
seed(RequesterPubkey, NowUnix, Count) ->
    gen_server:call(?SERVER, {seed, RequesterPubkey, NowUnix, Count}).

reset() ->
    gen_server:call(?SERVER, reset).

init([]) ->
    %% duplicate_bag is deliberate: identical same-second hits must count.
    Table = ets:new(?MODULE, [duplicate_bag, private]),
    {ok, #{table => Table}}.

handle_call(
    {check_and_mark, RequesterPubkey, NowUnix, MaxRequests, WindowSeconds},
    _From,
    #{table := Table} = State
) ->
    Cutoff = NowUnix - WindowSeconds,
    Existing0 = ets:lookup(Table, RequesterPubkey),
    Existing = [Ts || {_RequesterPubkey, Ts} <- Existing0, Ts >= Cutoff],

    ets:delete(Table, RequesterPubkey),
    [ets:insert(Table, {RequesterPubkey, Ts}) || Ts <- Existing],

    Reply =
        case length(Existing) >= MaxRequests of
            true ->
                {error, rate_limited};
            false ->
                ets:insert(Table, {RequesterPubkey, NowUnix}),
                ok
        end,

    {reply, Reply, State};
handle_call({seed, RequesterPubkey, NowUnix, Count}, _From, #{table := Table} = State) ->
    ets:delete(Table, RequesterPubkey),
    [ets:insert(Table, {RequesterPubkey, NowUnix}) || _ <- lists:seq(1, Count)],
    {reply, ok, State};
handle_call(reset, _From, #{table := Table} = State) ->
    ets:delete_all_objects(Table),
    {reply, ok, State};
handle_call(_Other, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

backend() ->
    normalize_backend(configured_backend(damage_nsecbunker:config())).

configured_backend(Config) when is_map(Config) ->
    RateLimit = maps:get(rate_limit, Config, #{}),
    first_defined(
        [
            maps:get(rate_backend, Config, undefined),
            maps:get(rate_limit_backend, Config, undefined),
            nested_backend(RateLimit)
        ],
        ets
    );
configured_backend(_) ->
    ets.

nested_backend(M) when is_map(M) ->
    first_defined(
        [
            maps:get(backend, M, undefined),
            maps:get(rate_backend, M, undefined),
            maps:get(rate_limit_backend, M, undefined)
        ],
        undefined
    );
nested_backend(_) ->
    undefined.

first_defined([], Default) ->
    Default;
first_defined([undefined | Rest], Default) ->
    first_defined(Rest, Default);
first_defined([Value | _Rest], _Default) ->
    Value.

normalize_backend(ets) -> ets;
normalize_backend(<<"ets">>) -> ets;
normalize_backend("ets") -> ets;
normalize_backend(throttle) -> throttle;
normalize_backend(<<"throttle">>) -> throttle;
normalize_backend("throttle") -> throttle;
normalize_backend(_Other) -> ets.
