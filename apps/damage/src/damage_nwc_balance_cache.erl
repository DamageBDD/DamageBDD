-module(damage_nwc_balance_cache).

-export([
    start/0,
    get/1,
    put/2,
    invalidate/1
]).

-define(TABLE, ?MODULE).
-define(DEFAULT_TTL_MS, 60000).

start() ->
    case ets:info(?TABLE) of
        undefined ->
            try ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]) of
                _ -> ok
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end.

get(Key0) ->
    ok = start(),
    Key = cache_key(Key0),
    Now = erlang:system_time(millisecond),
    TtlMs = ttl_ms(),
    case ets:lookup(?TABLE, Key) of
        [{Key, #{ts := Ts, value := Value}}] ->
            case Now - Ts < TtlMs of
                true ->
                    {ok, Value};
                false ->
                    ets:delete(?TABLE, Key),
                    miss
            end;
        [] ->
            miss
    end.

put(Key0, Value) ->
    ok = start(),
    Key = cache_key(Key0),
    Now = erlang:system_time(millisecond),
    true = ets:insert(?TABLE, {Key, #{ts => Now, value => Value}}),
    ok.

invalidate(Key0) ->
    ok = start(),
    Key = cache_key(Key0),
    ets:delete(?TABLE, Key),
    ok.

ttl_ms() ->
    pos_int(application:get_env(damage, nwc_balance_cache_ttl_ms), ?DEFAULT_TTL_MS).

pos_int({ok, V}, Default) ->
    pos_int(V, Default);
pos_int(V, _Default) when is_integer(V), V > 0 ->
    V;
pos_int(V, Default) when is_binary(V) ->
    try binary_to_integer(V) of
        I when I > 0 -> I;
        _ -> Default
    catch
        _:_ -> Default
    end;
pos_int(V, Default) when is_list(V) ->
    try list_to_integer(V) of
        I when I > 0 -> I;
        _ -> Default
    catch
        _:_ -> Default
    end;
pos_int(_V, Default) ->
    Default.

cache_key(B) when is_binary(B) -> B;
cache_key(L) when is_list(L) -> unicode:characters_to_binary(L);
cache_key(A) when is_atom(A) -> atom_to_binary(A, utf8);
cache_key(V) -> iolist_to_binary(io_lib:format("~p", [V])).
