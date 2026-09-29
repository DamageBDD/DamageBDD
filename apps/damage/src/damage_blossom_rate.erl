%%%-------------------------------------------------------------------
%%% Small in-memory rate limiter for the Blossom HTTP surface.
%%%
%%% The limiter is deliberately local to a DamageBDD node. It protects the
%%% expensive HTTP/auth/IPFS path from bursts without turning rate state into
%%% durable application data. Limits are enforced with fixed windows and are
%%% additionally keyed by request class plus client identity (IP or pubkey).
%%%-------------------------------------------------------------------
-module(damage_blossom_rate).

-behaviour(gen_server).

-export([start_link/1, check/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_KEYS, 100000).
-define(SWEEP_EVERY, 1024).

start_link(_Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec check(atom(), term(), non_neg_integer(), pos_integer()) ->
    ok | {error, {rate_limited, pos_integer()}} | {error, rate_limiter_capacity}.
check(_Scope, _Subject, 0, _WindowSeconds) ->
    ok;
check(Scope, Subject, Limit, WindowSeconds) when
    is_atom(Scope),
    is_integer(Limit),
    Limit > 0,
    is_integer(WindowSeconds),
    WindowSeconds > 0
->
    gen_server:call(?SERVER, {check, Scope, Subject, Limit, WindowSeconds}, 5000).

init([]) ->
    Tab = ets:new(?MODULE, [set, private]),
    MaxKeys = configured_int(blossom_rate_max_keys, ?DEFAULT_MAX_KEYS, 1000, 1000000),
    {ok, #{tab => Tab, checks => 0, max_keys => MaxKeys}}.

handle_call(
    {check, Scope, Subject, Limit, WindowSeconds},
    _From,
    #{tab := Tab, checks := Checks0, max_keys := MaxKeys} = State0
) ->
    Now = erlang:monotonic_time(second),
    Checks = Checks0 + 1,
    maybe_sweep(Tab, Checks, Now),
    Key = {Scope, Subject},
    Reply =
        case ets:lookup(Tab, Key) of
            [] ->
                case ensure_capacity(Tab, MaxKeys, Now) of
                    ok ->
                        true = ets:insert(Tab, {Key, Now + WindowSeconds, 1}),
                        ok;
                    {error, _} = Error ->
                        Error
                end;
            [{Key, ExpiresAt, _Count}] when Now >= ExpiresAt ->
                true = ets:insert(Tab, {Key, Now + WindowSeconds, 1}),
                ok;
            [{Key, ExpiresAt, Count}] when Count < Limit ->
                true = ets:insert(Tab, {Key, ExpiresAt, Count + 1}),
                ok;
            [{Key, ExpiresAt, _Count}] ->
                {error, {rate_limited, max(1, ExpiresAt - Now)}}
        end,
    {reply, Reply, State0#{checks => Checks}};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

maybe_sweep(Tab, Checks, Now) ->
    case Checks rem ?SWEEP_EVERY of
        0 -> sweep_expired(Tab, Now);
        _ -> ok
    end.

ensure_capacity(Tab, MaxKeys, Now) ->
    case ets:info(Tab, size) < MaxKeys of
        true ->
            ok;
        false ->
            sweep_expired(Tab, Now),
            case ets:info(Tab, size) < MaxKeys of
                true -> ok;
                false -> {error, rate_limiter_capacity}
            end
    end.

sweep_expired(Tab, Now) ->
    _ = ets:select_delete(Tab, [
        {{'_', '$1', '_'}, [{'=<', '$1', Now}], [true]}
    ]),
    ok.

configured_int(Key, Default, Min, Max) ->
    case application:get_env(damage, Key, Default) of
        I when is_integer(I), I >= Min, I =< Max -> I;
        I when is_integer(I), I > Max -> Max;
        _ -> Default
    end.
