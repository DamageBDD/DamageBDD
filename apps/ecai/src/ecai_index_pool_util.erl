%% Common closed-boundary helpers for the opt-in, private indexing pool.
-module(ecai_index_pool_util).
-include_lib("kernel/include/file.hrl").
-export([need/1, ensure/2, guarded/1, hash/1, field/2, object/1, text/1,
         shared_root/0, shared_path/1, node_named/1, node_names/0, msat/1]).
need(ok) -> ok;
need({ok, V}) -> V;
need({error, R}) -> throw({pool, R});
need(_) -> throw({pool, unexpected_service_response}).
ensure(true, _) -> ok;
ensure(false, R) -> throw({pool, R}).
guarded(F) ->
    try {ok, F()} catch
        throw:{pool, R} -> {error, R};
        error:{badkey, K} -> {error, {missing_field, K}};
        error:badarg -> {error, invalid_input};
        _:_ -> {error, pool_operation_failed}
    end.
hash(T) -> ecai_index_reward_ledger:digest(T).
field(K, M) when is_map(M) -> maps:get(K, M, maps:get(atom_to_binary(K, utf8), M, undefined));
field(_, _) -> undefined.
object({ok, M}) -> object(M);
object(M) when is_map(M) ->
    ensure(field(code, M) =:= undefined andalso field(error, M) =:= undefined, cln_rpc_failed), M;
object(_) -> throw({pool, cln_unavailable}).
text(B) when is_binary(B) -> B;
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(L) when is_list(L) -> unicode:characters_to_binary(L).
msat(N) when is_integer(N), N >= 0 -> N;
msat(B) when is_binary(B) ->
    case re:run(B, <<"^([0-9]+)msat$">>, [{capture, [1], binary}]) of
        {match, [N]} -> binary_to_integer(N);
        _ -> throw({pool, invalid_cln_amount})
    end;
msat(_) -> undefined.
shared_root() ->
    R = application:get_env(ecai, index_pool_shared_root, undefined),
    ensure(R =/= undefined, shared_root_not_configured),
    filename:absname(binary_to_list(text(R))).
%% All paths are server-selected, confined to a trusted shared root. Reject
%% symlink components; neither a browser nor a remote receipt may choose a path
%% outside this root. Workers must have separate OS write permissions in v1.
shared_path(P0) ->
    P = filename:absname(binary_to_list(text(P0))), R = shared_root(),
    Parts = filename:split(P), Base = filename:split(R),
    ensure(lists:prefix(Base, Parts) andalso length(Parts) > length(Base), path_outside_shared_root),
    ensure(not lists:member("..", Parts), invalid_path),
    _ = lists:foldl(fun(Part, Acc) ->
        Full = case Acc of "" -> Part; _ -> filename:join(Acc, Part) end,
        case file:read_link_info(Full) of
            {ok, #file_info{type = symlink}} -> throw({pool, symlink_not_permitted});
            {ok, _} -> ok;
            {error, enoent} -> ok;
            {error, Reason} -> throw({pool, {path_unavailable, Reason}})
        end, Full
    end, "", Parts),
    P.
node_names() ->
    Ns = application:get_env(ecai, indexing_worker_nodes, []),
    [atom_to_binary(N, utf8) || N <- Ns, is_atom(N), N =/= node(), N =/= undefined].
%% Do not create atoms from node names supplied by HTTP clients.
node_named(Name) ->
    case [N || N <- application:get_env(ecai, indexing_worker_nodes, []),
               is_atom(N), atom_to_binary(N, utf8) =:= Name, N =/= node()] of
        [N] -> N;
        _ -> throw({pool, node_not_operator_allowlisted})
    end.
