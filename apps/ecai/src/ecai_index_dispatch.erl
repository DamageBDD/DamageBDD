%% Permissioned multi-node queue placement over an EXISTING trusted Erlang
%% cluster. Not a public RPC or a lease protocol. Persist node placement BEFORE
%% enqueue so ambiguous responses cannot move one task to another node.
-module(ecai_index_dispatch).
-include_lib("kernel/include/file.hrl").
-export([enqueue/3, get/1, read/1, workers/0]).
workers() -> application:get_env(ecai, indexing_worker_nodes, [node()]).

enqueue(File0, Spec, Key) -> guarded(fun() ->
    File = path(File0),
    ok = need_ok(filelib:ensure_dir(File)),
    with_lock(File ++ ".lock", fun() ->
        {ok, Sha} = need(ecai_index_job_codec:spec_hash(Spec)),
        Hex = ecai_index_job_codec:id_hex(Sha),
        Identity = #{spec_sha256 => Hex, idempotency_key => Key},
        Intent = case read(File) of
            {error, enoent} ->
                Ns = workers(), require(Ns =/= [] andalso is_list(Ns) andalso
                    lists:all(fun erlang:is_atom/1, Ns), invalid_worker_nodes),
                <<Choice:64/unsigned-big, _/binary>> = crypto:hash(sha256, Key),
                Node = lists:nth((Choice rem length(Ns)) + 1, Ns),
                I = Identity#{node => Node, state => dispatching},
                ok = write(File, I), I;
            {ok, Old} ->
                require(maps:with([spec_sha256, idempotency_key], Old) =:= Identity, dispatch_identity_changed),
                Old;
            {error, R} -> fail(R)
        end,
        Node1 = maps:get(node, Intent),
        %% Even after restart use the pinned node. Removal from the operator's
        %% allowlist blocks work instead of selecting a new node silently.
        {ok, Job} = need(call(Node1, enqueue, [Spec, #{idempotency_key => Key}])),
        require(maps:get(<<"spec_hash">>, Job) =:= Hex, queue_identity_mismatch),
        Accepted = Intent#{state => acknowledged, job_id => maps:get(<<"id">>, Job)},
        ok = write(File, Accepted), {ok, Accepted}
    end)
end).
get(#{node := Node, job_id := JobId, spec_sha256 := Sha}) -> guarded(fun() ->
    {ok, Job} = need(call(Node, get, [JobId])),
    require(maps:get(<<"spec_hash">>, Job) =:= Sha, queue_identity_mismatch), {ok, Job}
end);
get(JobId) when is_binary(JobId) ->
    %% Compatibility with pre-cluster local shard-plan receipts.
    try ecai_index_jobs_srv:get(JobId) catch _:_ -> {error, queue_unavailable} end;
get(_) -> {error, dispatch_not_acknowledged}.
call(Node, Method, Args) ->
    require(lists:member(Node, workers()), worker_node_not_allowed),
    try
        case Node =:= node() of
            true -> apply(ecai_index_jobs_srv, Method, Args);
            false -> erpc:call(Node, ecai_index_jobs_srv, Method, Args, 10000)
        end
    catch _:_ -> {error, {queue_unavailable, Node}} end.
read(File0) ->
    File = path(File0),
    case file:read_file_info(File) of
        {ok, #file_info{size = S}} when S =< 65536 ->
            case file:read_file(File) of
                {ok, <<131,80,_/binary>>} -> {error, compressed_dispatch_not_allowed};
                {ok, B} -> try
                    M = binary_to_term(B, [safe]),
                    true = is_map(M), {ok, M}
                catch _:_ -> {error, corrupt_dispatch} end;
                E -> E
            end;
        {ok, _} -> {error, dispatch_too_large};
        E -> E
    end.
write(File, M) ->
    B = term_to_binary(M), require(byte_size(B) =< 65536, dispatch_too_large),
    Tmp = File ++ ".tmp",
    {ok, Fd} = need(file:open(Tmp, [write, raw, binary])),
    try ok = need_ok(file:write(Fd, B)), ok = need_ok(file:sync(Fd))
    after file:close(Fd) end,
    need_ok(file:rename(Tmp, File)).
with_lock(L, F) ->
    case file:open(L, [write, raw, binary, exclusive]) of
        {ok, Io} -> try F() after file:close(Io), file:delete(L) end;
        {error, eexist} -> fail(dispatch_locked);
        {error, R} -> fail(R)
    end.
path(B) when is_binary(B) -> unicode:characters_to_list(B);
path(L) when is_list(L) -> L.
require(true, _) -> ok;
require(false, R) -> fail(R).
need({ok, _} = O) -> O;
need({error, R}) -> fail(R).
need_ok(ok) -> ok;
need_ok({error, R}) -> fail(R).
fail(R) -> throw({index_dispatch, R}).
guarded(F) -> try F() catch throw:{index_dispatch, R} -> {error, R}; C:R -> {error, {C,R}} end.
