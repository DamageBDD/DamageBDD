%% Operator-only upstream Wikimedia DAG. Jobs use the existing durable queue.
%% A trusted shared filesystem is the v1 transport; this is NOT a public worker
%% protocol. Workers on different nodes must see the same configured work root.
%% Content-addressed receipts commit files; they are not proofs of correct work.
-module(ecai_wikimedia_work).
-include_lib("kernel/include/file.hrl").
-export([plan/2, build/3, read_plan/1, status/1, enqueue_ready/2,
         unit/2, execute/3, receipt/2, verify_receipt/2,
         index_plan/3, root_dir/0, clear_stopped_unit_lock/2]).
-ifdef(TEST).
-export([verify_input/4]).
-endif.
-define(SCHEMA, <<"ecai-wikimedia-work/v1">>).
-define(MAX_TERM, 16777216).

%% plan(Spec, DesktopLimits) resolves the source catalog ONCE before fan-out.
plan(Spec0, Limits) -> guarded(fun() ->
    {ok, Spec} = need(ecai_index_job_codec:normalize_spec(Spec0)),
    require(maps:get(kind, Spec) =:= wikimedia_visibility, wrong_job_kind),
    {ok, Catalog} = need(ecai_wikimedia_catalog:resolve(maps:get(source, Spec))),
    {ok, Plan} = need(build(Spec, Catalog, Limits)),
    Root = maps:get(root, Plan), Dir = plan_dir(Root),
    ok = ensure(Dir),
    with_lock(filename:join(Dir, "plan.lock"), fun() ->
        File = filename:join(Dir, "plan.etf"),
        case read_term(File) of
            {ok, Plan} -> {ok, Root, Plan};
            {ok, _} -> fail(existing_plan_conflict);
            {error, enoent} -> ok = write_term(File, Plan), {ok, Root, Plan};
            {error, Why} -> fail(Why)
        end
    end)
end).

%% Pure builder, separately testable with a pinned catalog (no HTTP requests).
build(Spec, Catalog, Limits) -> guarded(fun() ->
    require(is_map(Spec) andalso is_map(Catalog) andalso is_map(Limits), badarg),
    require(maps:get(kind, Spec) =:= wikimedia_visibility, wrong_job_kind),
    O = maps:get(options, Spec), Source = maps:get(source, Spec),
    require(maps:get(project, Source) =:= maps:get(project, Catalog) andalso
        maps:get(pageview_project, Source) =:= maps:get(pageview_project, Catalog) andalso
        maps:get(pageview_months, Source) =:= maps:get(pageview_months, Catalog), catalog_mismatch),
    Release = maps:get(content_release, Source),
    require(Release =:= latest orelse Release =:= <<"latest">> orelse
        Release =:= maps:get(cirrus_release, Catalog), catalog_release_mismatch),
    Months = maps:get(pageview_sources, Catalog), Content = maps:get(content_shards, Catalog),
    require(length(Months) > 0 andalso length(Months) =< 64, invalid_months),
    require(length(Content) > 0 andalso length(Content) =< 2048, invalid_content_shards),
    require([maps:get(month, M) || M <- Months] =:= maps:get(pageview_months, Catalog), invalid_month_order),
    require(length(lists:usort([maps:get(month, M) || M <- Months])) =:= length(Months), duplicate_month),
    lists:foreach(fun safe_source/1, Months ++ Content),
    Names = [maps:get(name, C) || C <- Content],
    require(length(lists:usort(Names)) =:= length(Names), duplicate_content_name),
    Partitions = limit(partitions, Limits, 128, 8, 1024),
    MaxCandidates = limit(max_candidates, Limits, 50000, 1, 100000),
    N = maps:get(limit, O), Oversample = maps:get(oversample_percent, O),
    require((N * Oversample + 99) div 100 =< MaxCandidates, candidate_memory_budget_exceeded),
    Desktop = #{partitions => Partitions, max_candidates => MaxCandidates,
        max_partition_pages => limit(max_partition_pages, Limits, 200000, 1, 1000000),
        max_partition_memory_bytes => limit(max_partition_memory_bytes, Limits, 134217728, 1048576, 1073741824),
        max_line_bytes => limit(max_line_bytes, Limits, 4194304, 1048576, 16777216),
        worker_heap_words => limit(worker_heap_words, Limits, 16777216, 1048576, 134217728)},
    %% Prevent individual intermediate jobs from publishing/minting artifacts.
    Opts = O#{selection_shards => Partitions, partition_buffer_bytes => 4096,
        cirrus_max_line_bytes => maps:get(max_line_bytes, Desktop),
        pageview_max_line_bytes => maps:get(max_line_bytes, Desktop),
        max_partition_pages => maps:get(max_partition_pages, Desktop),
        max_partition_memory_bytes => maps:get(max_partition_memory_bytes, Desktop),
        index_chunk_lines => 250, keep_intermediates => true, keep_downloads => true,
        publish_extracted_ipfs => false},
    Core = #{schema => ?SCHEMA, original_spec => Spec, catalog => Catalog,
             options => Opts, limits => Desktop},
    Root = digest(Core),
    Ms = [make_unit(Root, pageviews, I, #{source => M}, []) || {M,I} <- enumerate(Months)],
    As = [make_unit(Root, aggregate, P, #{partition => P}, ids(Ms)) || P <- lists:seq(0, Partitions-1)],
    Sel = make_unit(Root, selection, 0, #{}, ids(As)),
    Cs = [make_unit(Root, content, I, #{source => C}, [maps:get(id, Sel)]) || {C,I} <- enumerate(Content)],
    Final = make_unit(Root, ranked, 0, #{}, ids(Cs)),
    {ok, Core#{root => Root, units => Ms ++ As ++ [Sel] ++ Cs ++ [Final]}}
end).

make_unit(Root, Stage, Ordinal, Fields, Deps) ->
    Fields#{id => digest({Root, Stage, Ordinal}), stage => Stage,
            ordinal => Ordinal, dependencies => Deps}.
enumerate(L) -> lists:zip(L, lists:seq(1, length(L))).
ids(Units) -> [maps:get(id, U) || U <- Units].

read_plan(Root) -> guarded(fun() ->
    hash(Root),
    {ok, P} = need(read_term(filename:join(plan_dir(Root), "plan.etf"))),
    require(maps:get(schema, P) =:= ?SCHEMA andalso maps:get(root, P) =:= Root, wrong_plan),
    %% Rebuild to validate the DAG as well as the immutable input coordinates.
    {ok, P} = need(build(maps:get(original_spec, P), maps:get(catalog, P), maps:get(limits, P))),
    {ok, P}
end).
unit(Root, Id) -> guarded(fun() ->
    hash(Id), {ok, P} = need(read_plan(Root)),
    {ok, P, find_unit(Id, P)}
end).
find_unit(Id, P) ->
    case [U || U <- maps:get(units, P), maps:get(id, U) =:= Id] of
        [U] -> U; _ -> fail(unknown_unit)
    end.

%% Inspect scheduling without hashing all potentially large spool files.
%% The worker verifies its direct input receipts before consuming any bytes.
status(Root) -> guarded(fun() ->
    {ok, P} = need(read_plan(Root)),
    {ok, Rows} = need(queue_rows(Root, P)),
    Done = [maps:get(id, R) || R <- Rows, maps:get(state, R) =:= completed],
    WithReady = [R#{ready => maps:get(state, R) =:= unqueued andalso
        lists:all(fun(D) -> lists:member(D, Done) end, maps:get(dependencies, R))} || R <- Rows],
    {ok, #{root => Root, total => length(Rows), completed => length(Done), units => WithReady}}
end).

%% Safe to repeat after timeout/crash: one stable key per immutable unit.
%% Does not enqueue failed jobs again; use the existing retry endpoint/shell API.
enqueue_ready(Root, Count) -> guarded(fun() ->
    require(is_integer(Count) andalso Count >= 1 andalso Count =< 64, invalid_page_size),
    {ok, P} = need(read_plan(Root)),
    with_lock(filename:join(plan_dir(Root), "enqueue.lock"), fun() ->
        {ok, St} = need(status(Root)),
        Ready = lists:sublist([U || U <- maps:get(units, St), maps:get(ready, U)], Count),
        Jobs = [enqueue_one(Root, P, U) || U <- Ready],
        {ok, Jobs}
    end)
end).
enqueue_one(Root, P, U) ->
    Id = maps:get(id, U), Spec = job_spec(Root, P, Id),
    ecai_index_dispatch:enqueue(job_file(Root, Id), Spec, <<"ecai-wm-unit:", Id/binary>>).
job_spec(Root, P, Id) ->
    #{kind => wikimedia_unit, owner => maps:get(owner, maps:get(original_spec, P)),
      source => #{plan_root => Root, unit_id => Id},
      target => #{mode => ledger_only, base_dir => unicode:characters_to_binary(plan_dir(Root))},
      options => #{batch_size => 1, max_retries => 3},
      finalize => #{build_nft_manifest => false, publish_ipfs => false, auto_mint => false}}.
queue_rows(Root, P) -> guarded(fun() ->
    {ok, [queue_row(Root, U) || U <- maps:get(units, P)]}
end).
queue_row(Root, U) ->
    case ecai_index_dispatch:read(job_file(Root, maps:get(id, U))) of
        {error, enoent} -> U#{state => unqueued};
        {ok, #{state := dispatching, node := Node}} ->
            %% Unknown enqueue result: replay only on its already-pinned node.
            U#{state => unqueued, assigned_node => Node};
        {ok, #{job_id := JobId, node := Node} = Placement} ->
            case ecai_index_dispatch:get(Placement) of
                {ok, #{<<"state">> := State}} ->
                    U#{job_id => JobId, assigned_node => Node, state => queue_state(State)};
                {error, Why} -> U#{job_id => JobId, assigned_node => Node, state => unavailable, error => Why}
            end;
        {error, Why} -> fail({job_receipt_unavailable, Why});
        _ -> fail(invalid_job_receipt)
    end.
queue_state(<<"completed">>) -> completed;
queue_state(<<"failed">>) -> failed;
queue_state(<<"canceled">>) -> canceled;
queue_state(<<"paused">>) -> paused;
queue_state(_) -> active.

%% run_batch calls execute in the worker. One unit is one safe restart boundary.
execute(Root, Id, Progress) when is_function(Progress, 1) -> guarded(fun() ->
    {ok, P, U} = need(unit(Root, Id)),
    Dir = plan_dir(Root),
    with_lock(filename:join(Dir, binary_to_list(Id) ++ ".lock"), fun() ->
        Deps = [begin {ok, R} = need(verify_input(Root, P, U, D)), maps:get(receipt_sha256, R) end
                || D <- maps:get(dependencies, U)],
        case receipt(Root, Id) of
            {ok, Existing} ->
                require(maps:get(dependencies, Existing) =:= Deps, changed_dependency),
                verify_receipt(Root, Id);
            {error, enoent} ->
                Opts = maps:get(options, P), Catalog = maps:get(catalog, P),
                {ok, Selector} = need(ecai_wikimedia_selector:prepare(Dir, Catalog, Opts)),
                {ok, Content} = need(ecai_wikimedia_content:prepare(Dir, Catalog, Selector, Opts)),
                {Meta, Files} = run(U, Selector, Content, Progress),
                {ok, Identity} = need(ecai_index_source:describe_paths(Files)),
                Record = #{schema => <<"ecai-wikimedia-receipt/v1">>, root => Root, unit_id => Id,
                    stage => maps:get(stage, U), dependencies => Deps,
                    files => [unicode:characters_to_binary(F) || F <- Files], source_identity => Identity,
                    result => maps:without([cached], Meta)},
                R = Record#{receipt_sha256 => digest(Record)},
                ok = write_term(receipt_file(Root, Id), R), {ok, R};
            {error, Why} -> fail(Why)
        end
    end)
end).
%% Aggregation consumes ONE partition per month, not every partition. Verify
%% only those committed bytes to avoid rereading the entire spool N times.
%% The complete producer receipt is still hashed into the dependency identity.
verify_input(Root, Plan, #{stage := aggregate, partition := Partition}, DepId) -> guarded(fun() ->
    Dep = find_unit(DepId, Plan),
    require(maps:get(stage, Dep) =:= pageviews, invalid_partition_dependency),
    Month = maps:get(month, maps:get(source, Dep)),
    File = filename:join([plan_dir(Root), "selection", "spool", binary_to_list(Month),
        lists:flatten(io_lib:format("part-~4..0B.bin", [Partition]))]),
    {ok, R} = need(receipt(Root, DepId)),
    Paths = maps:get(files, R), Descriptors = maps:get(files, maps:get(source_identity, R)),
    require(length(Paths) =:= length(Descriptors), invalid_receipt),
    Matches = [Desc || {Path, Desc} <- lists:zip(Paths, Descriptors),
        filename:absname(path(Path)) =:= filename:absname(File)],
    case Matches of
        [Descriptor] ->
            ok = need_ok(ecai_index_source:verify_paths([File],
                #{files => [Descriptor#{ordinal => 1}]}));
        [] ->
            %% A month can legitimately have no rows in this partition, but a
            %% newly appeared uncommitted file must NOT be silently consumed.
            require(file:read_file_info(File) =:= {error, enoent}, uncommitted_partition_file);
        _ -> fail(duplicate_partition_descriptor)
    end,
    {ok, R}
end);
verify_input(Root, _Plan, _Unit, DepId) -> verify_receipt(Root, DepId).

run(#{stage := pageviews, source := Source, ordinal := Ord}, Sel, _Con, F) ->
    {ok, Meta} = need(ecai_wikimedia_selector:spool_month(Sel, Source, Ord, F)),
    Dir = filename:join(maps:get(spool_dir, Sel), binary_to_list(maps:get(month, Source))),
    {Meta, files_in(Dir)};
run(#{stage := aggregate, partition := P}, Sel, _Con, F) ->
    {ok, Meta} = need(ecai_wikimedia_selector:aggregate_partition(Sel, P, F)),
    File = filename:join(maps:get(top_dir, Sel), lists:flatten(io_lib:format("top-~4..0B.jsonl", [P]))),
    {Meta, [File, File ++ ".complete.json"]};
run(#{stage := selection}, Sel, _Con, F) ->
    {ok, Meta} = need(ecai_wikimedia_selector:merge_selection(Sel, F)),
    {Meta, [maps:get(selection_path, Sel), maps:get(selection_meta_path, Sel)]};
run(#{stage := content, source := Source}, Sel, Con, F) ->
    {ok, Tab, _Count} = need(ecai_wikimedia_selector:load_selection(maps:get(selection_path, Sel))),
    try
        {ok, Meta} = need(ecai_wikimedia_content:extract_shard(Con, Source, Tab, F)),
        File = path(maps:get(output_path, Meta)),
        {Meta, [File, File ++ ".complete.json"]}
    after ecai_wikimedia_selector:close_selection(Tab) end;
run(#{stage := ranked}, _Sel, Con, F) ->
    {ok, Meta} = need(ecai_wikimedia_content:finalize_ranked(Con, F)),
    {Meta, files_in(maps:get(index_dir, Con))}.

receipt(Root, Id) -> guarded(fun() ->
    hash(Root), hash(Id),
    {ok, R} = need(read_term(receipt_file(Root, Id))),
    require(maps:get(root, R) =:= Root andalso maps:get(unit_id, R) =:= Id andalso
        maps:get(receipt_sha256, R) =:= digest(maps:remove(receipt_sha256, R)), invalid_receipt),
    {ok, R}
end).
verify_receipt(Root, Id) -> guarded(fun() ->
    {ok, R} = need(receipt(Root, Id)),
    ok = need_ok(ecai_index_source:verify_paths(maps:get(files, R), maps:get(source_identity, R))),
    {ok, R}
end).

%% Retains the existing logical merge format: upstream finalization -> small
%% independently built snapshots -> ecai_index_shards:merge/2 and search/3.
index_plan(Root, OutputRoot, Limits) -> guarded(fun() ->
    {ok, P} = need(read_plan(Root)),
    [Final] = [U || U <- maps:get(units, P), maps:get(stage, U) =:= ranked],
    {ok, R} = need(verify_receipt(Root, maps:get(id, Final))),
    Inputs = [F || F <- maps:get(files, R), filename:extension(path(F)) =:= ".jsonl"],
    require(Inputs =/= [], no_selected_records),
    Original = maps:get(original_spec, P),
    Spec = #{kind => wikipedia_jsonl, owner => maps:get(owner, Original),
        source => #{paths => Inputs}, target => maps:get(target, Original),
        options => #{batch_size => 1}, finalize => #{build_nft_manifest => false}},
    ecai_index_shards:plan(Spec, OutputRoot, Limits)
end).

%% Explicit recovery, never a time-based lease steal. Failure to contact the
%% recorded node is NOT proof that its worker has stopped.
clear_stopped_unit_lock(Root, Id) -> guarded(fun() ->
    hash(Root), hash(Id),
    File = filename:join(plan_dir(Root), binary_to_list(Id) ++ ".lock"),
    with_lock(File ++ ".recovery", fun() ->
        {ok, #{node := Node, pid := Pid}} = need(read_term(File)),
        require(is_pid(Pid) andalso node(Pid) =:= Node andalso
            lists:member(Node, ecai_index_dispatch:workers()), invalid_lock_owner),
        Alive = try
            case Node =:= node() of
                true -> erlang:is_process_alive(Pid);
                false -> erpc:call(Node, erlang, is_process_alive, [Pid], 5000)
            end
        catch _:_ -> unknown end,
        require(Alive =:= false, worker_not_proven_stopped),
        ok = need_ok(file:delete(File)), {ok, lock_cleared}
    end)
end).

root_dir() -> path(application:get_env(ecai, wikimedia_work_dir, "/var/lib/damage/ecai/wikimedia-work")).
plan_dir(Root) -> hash(Root), filename:join(filename:absname(root_dir()), binary_to_list(Root)).
job_file(Root, Id) -> filename:join(plan_dir(Root), binary_to_list(Id) ++ ".job.etf").
receipt_file(Root, Id) -> filename:join(plan_dir(Root), binary_to_list(Id) ++ ".receipt.etf").
files_in(Dir) ->
    {ok, Names} = need(file:list_dir(Dir)),
    [filename:join(Dir, N) || N <- lists:sort(Names), filelib:is_regular(filename:join(Dir, N))].
ensure(Dir) -> need_ok(filelib:ensure_dir(filename:join(Dir, ".keep"))).
with_lock(File, F) ->
    case file:open(File, [write, raw, binary, exclusive]) of
        {ok, Io} ->
            try
                ok = need_ok(file:write(Io, term_to_binary(#{node => node(), pid => self()}))),
                ok = need_ok(file:sync(Io)), F()
            after file:close(Io), file:delete(File) end;
        {error, eexist} -> fail({work_locked, File});
        {error, Why} -> fail({lock_failed, Why})
    end.
%% Locks are intentionally NOT stolen on a timer. Fence a lost worker before
%% removing its stale lock. Shared storage must provide atomic exclusive create.
write_term(File, T) ->
    B = term_to_binary(T), require(byte_size(B) =< ?MAX_TERM, metadata_too_large),
    Tmp = File ++ ".tmp-" ++ binary_to_list(ecai_index_job_codec:id_hex(crypto:strong_rand_bytes(8))),
    {ok, Io} = need(file:open(Tmp, [write, raw, binary, exclusive])),
    try
        ok = need_ok(file:write(Io, B)), ok = need_ok(file:sync(Io))
    after file:close(Io) end,
    need_ok(file:rename(Tmp, File)).
read_term(File) ->
    case file:read_file_info(File) of
        {ok, #file_info{size = Size}} when Size =< ?MAX_TERM ->
            case file:read_file(File) of
                {ok, <<131,80,_/binary>>} -> {error, compressed_metadata_not_allowed};
                {ok, B} -> try {ok, binary_to_term(B, [safe])} catch _:_ -> {error, invalid_metadata} end;
                Error -> Error
            end;
        {ok, _} -> {error, metadata_too_large};
        Error -> Error
    end.
safe_source(S) ->
    Name = maps:get(name, S), Url = maps:get(url, S),
    require(is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 255, invalid_source_name),
    require(binary:match(Name, [<<"/">>, <<"\\">>, <<"..">>, <<0>>]) =:= nomatch, unsafe_source_name),
    require(is_binary(Url) andalso byte_size(Url) > 0, invalid_source_url).
limit(K, M, D, Min, Max) ->
    V = maps:get(K, M, D), require(is_integer(V) andalso V >= Min andalso V =< Max, {invalid_limit, K}), V.
hash(H) -> require(is_binary(H) andalso byte_size(H) =:= 64 andalso
    re:run(H, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match, invalid_hash).
digest(T) -> ecai_index_job_codec:id_hex(crypto:hash(sha256, ecai_index_job_codec:canonical_binary(T))).
path(B) when is_binary(B) -> unicode:characters_to_list(B);
path(L) when is_list(L) -> L.
need({ok, _} = O) -> O;
need({ok, _, _} = O) -> O;
need({error, E}) -> fail(E).
need_ok(ok) -> ok;
need_ok({error, E}) -> fail(E).
require(true, _) -> ok;
require(false, R) -> fail(R).
fail(R) -> throw({wikimedia_work, R}).
guarded(F) -> try F() catch throw:{wikimedia_work, R} -> {error, R}; C:R -> {error, {C,R}} end.
