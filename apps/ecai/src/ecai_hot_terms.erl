%%--------------------------------------------------------------------
%% ecai_hot_terms.erl
%% Small RAM cache for hot term postings
%%--------------------------------------------------------------------
-module(ecai_hot_terms).
-export([new/1, get/2, put/3]).

new(Max) ->
    Tab = ets:new(ecai_hot_terms, [set, public]),
    ets:insert(Tab, {max, Max}),
    Tab.

get(Tab, Term) ->
    case ets:lookup(Tab, Term) of
        [{_, Docs, _Ts}] ->
            ets:insert(Tab, {Term, Docs, now_ms()}),
            {ok, Docs};
        _ ->
            not_found
    end.

put(Tab, Term, Docs) ->
    Max =
        case ets:lookup(Tab, max) of
            [{max, M}] -> M;
            _ -> 10000
        end,
    Sz = ets:info(Tab, size),
    if
        Sz > Max ->
            evict(Tab, Max div 10);
        true ->
            ok
    end,
    ets:insert(Tab, {Term, Docs, now_ms()}),
    ok.

evict(Tab, N) ->
    L = [E || E = {K, _, _} <- ets:tab2list(Tab), K =/= max],
    Old = lists:sublist(
        lists:sort(fun({_, _, A}, {_, _, B}) -> A =< B end, L),
        max(1, N)
    ),
    [ets:delete(Tab, K) || {K, _, _} <- Old],
    ok.

now_ms() ->
    erlang:system_time(millisecond).
