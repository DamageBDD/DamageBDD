-module(damage_nwc_balance_cache).

-export([
    start/0,
    get/1,
    put/2,
    invalidate/1
]).

-define(TABLE, ?MODULE).
-define(TTL_MS, 60000).

start() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

get(Key) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, Key) of
        [{Key, #{ts := Ts, value := Value}}] when Now - Ts < ?TTL_MS ->
            {ok, Value};
        [{Key, _Old}] ->
            ets:delete(?TABLE, Key),
            miss;
        [] ->
            miss
    end.

put(Key, Value) ->
    Now = erlang:system_time(millisecond),
    true = ets:insert(?TABLE, {Key, #{ts => Now, value => Value}}),
    ok.

invalidate(Key) ->
    ets:delete(?TABLE, Key),
    ok.
