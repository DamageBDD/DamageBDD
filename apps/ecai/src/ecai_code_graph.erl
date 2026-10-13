-module(ecai_code_graph).

-export([
    build/1,
    neighborhood/3,
    incoming/2,
    outgoing/2,
    summary/1
]).

build(Analyses0) when is_list(Analyses0) ->
    Analyses = [A || A <- Analyses0, is_map(A), maps:is_key(module, A)],
    Modules = maps:from_list([{maps:get(module, A), A} || A <- Analyses]),
    ModuleSet = maps:from_list([{M, true} || M <- maps:keys(Modules)]),
    Outgoing = maps:from_list([
        {M, internal_targets(A, ModuleSet)}
     || {M, A} <- maps:to_list(Modules)
    ]),
    Incoming = invert_edges(Outgoing),
    #{
        modules => Modules,
        outgoing => Outgoing,
        incoming => Incoming,
        module_count => maps:size(Modules),
        edge_count => lists:sum([length(V) || V <- maps:values(Outgoing)])
    }.

outgoing(Graph, Module) ->
    maps:get(Module, maps:get(outgoing, Graph, #{}), []).

incoming(Graph, Module) ->
    maps:get(Module, maps:get(incoming, Graph, #{}), []).

neighborhood(Graph, Module, Depth) when is_integer(Depth), Depth >= 0 ->
    bfs(Graph, [{Module, 0}], #{Module => 0}, Depth).

summary(Graph) ->
    Modules = maps:get(modules, Graph, #{}),
    lists:sort([
        #{
            module => Module,
            outgoing => outgoing(Graph, Module),
            incoming => incoming(Graph, Module),
            behaviours => maps:get(behaviours, Analysis, []),
            security_boundaries => maps:get(security_boundaries, Analysis, []),
            test_module => maps:get(test_module, Analysis, false)
        }
     || {Module, Analysis} <- maps:to_list(Modules)
    ]).

internal_targets(Analysis, ModuleSet) ->
    Calls = maps:get(remote_calls, Analysis, []),
    lists:usort([
        Target
     || Call <- Calls,
        is_map(Call),
        Target <- [maps:get(module, Call, undefined)],
        Target =/= undefined,
        maps:is_key(Target, ModuleSet)
    ]).

invert_edges(Outgoing) ->
    Seed = maps:from_list([{M, []} || M <- maps:keys(Outgoing)]),
    maps:fold(
        fun(From, Targets, Acc0) ->
            lists:foldl(
                fun(To, Acc) ->
                    maps:update_with(To, fun(L) -> lists:usort([From | L]) end, [From], Acc)
                end,
                Acc0,
                Targets
            )
        end,
        Seed,
        Outgoing
    ).

bfs(_Graph, [], Seen, _MaxDepth) ->
    lists:sort(
        fun({A, DA}, {B, DB}) ->
            (DA < DB) orelse ((DA =:= DB) andalso (A =< B))
        end,
        maps:to_list(Seen)
    );
bfs(Graph, [{_Module, Depth} | Rest], Seen, MaxDepth) when Depth >= MaxDepth ->
    bfs(Graph, Rest, Seen, MaxDepth);
bfs(Graph, [{Module, Depth} | Rest], Seen0, MaxDepth) ->
    Neighbours = lists:usort(outgoing(Graph, Module) ++ incoming(Graph, Module)),
    {Seen1, Added} = lists:foldl(
        fun(N, {Seen, Queue}) ->
            case maps:is_key(N, Seen) of
                true -> {Seen, Queue};
                false -> {Seen#{N => Depth + 1}, Queue ++ [{N, Depth + 1}]}
            end
        end,
        {Seen0, []},
        Neighbours
    ),
    bfs(Graph, Rest ++ Added, Seen1, MaxDepth).
