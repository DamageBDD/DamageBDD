%% Desktop-scale, bounded fan-out of local NDJSON files into independent ECAI
%% search contexts. A merged index is a VERIFIED manifest of immutable shards,
%% never an attempt to load all ETS indexes into one oversized process.
%% Operator API only: not exposed to untrusted HTTP clients.
-module(ecai_index_shards).
-include_lib("kernel/include/file.hrl").

-export([plan/3, read_plan/1, enqueue_batch/3, merge/2, merge_plan/2,
         read_manifest/1, search/3, snapshot/2]).

-define(SCHEMA, <<"ecai-shard-plan/v1">>).
-define(MERGED, <<"ecai-shard-index/v1">>).
-define(READ_BLOCK, 65536).
-define(MAX_MANIFEST_BYTES, 16777216).

%% plan(Spec, LocalWorkRoot, Limits) -> {ok, PlanPath, Plan} | {error, Reason}.
%% Shards are disjoint, deterministic, complete-line slices of the source.
%% The caller owns LocalWorkRoot and should ensure it is not public-writable.
plan(Spec0, OutDir0, Limits0) ->
    try
        {ok, Spec} = expect(ecai_index_job_codec:normalize_spec(Spec0)),
        Kind = maps:get(kind, Spec),
        case lists:member(Kind, [yelp_ndjson, wikipedia_jsonl]) of
            true -> ok;
            false -> fail({unsupported_sharding_kind, Kind})
        end,
        Limits = normalize_limits(Limits0),
        Paths = maps:get(paths, maps:get(source, Spec)),
        {ok, Identity} = expect(ecai_index_source:describe_paths(Paths)),
        GroupId = hex(crypto:hash(sha256, ecai_index_job_codec:canonical_binary(
            #{spec => Spec, source_identity => Identity, limits => Limits}))),
        OutDir = path(OutDir0),
        ok = expect_ok(filelib:ensure_dir(filename:join(OutDir, "x"))),
        GroupDir = filename:join(OutDir, binary_to_list(GroupId)),
        PlanFile = filename:join(GroupDir, "plan.etf"),
        case file:make_dir(GroupDir) of
            ok -> ok;
            {error, eexist} -> fail({plan_already_exists, PlanFile});
            {error, Why} -> fail({cannot_create_shard_group, Why})
        end,
        Profile = case Kind of yelp_ndjson -> yelp; wikipedia_jsonl -> wikipedia end,
        Splits = split_sources(Paths, Profile, GroupDir, Limits, 1, []),
        case length(Splits) of
            0 -> fail(empty_shard_plan);
            N when N > 4096 -> fail({shard_limit_exceeded, N});
            _ -> ok
        end,
        case length(Splits) =< maps:get(max_shards, Limits) of
            true -> ok;
            false -> fail({shard_limit_exceeded, length(Splits)})
        end,
        Groups = group_splits(Splits, Limits, [], [], 0),
        Entries = make_entries(Groups, Spec, GroupId, 1, []),
        Plan = #{schema => ?SCHEMA, group_id => GroupId, kind => Kind,
            source_identity => Identity, original_spec => Spec,
            limits => Limits, entries => Entries, receipts => #{},
            created_at_ms => erlang:system_time(millisecond)},
        ok = expect_ok(write_term(PlanFile, Plan)),
        {ok, PlanFile, Plan}
    catch
        throw:{shard_error, Reason} -> {error, Reason};
        error:{badmatch, {error, Reason}} -> {error, Reason};
        Class:Reason -> {error, {shard_plan_failed, Class, Reason}}
    end.

normalize_limits(Opts) when is_map(Opts) ->
    MaxBytes = bound(max_shard_bytes, Opts, 8*1024*1024, 1, 512*1024*1024),
    MaxLine = bound(max_line_bytes, Opts, 2*1024*1024, 1, MaxBytes),
    #{max_shard_bytes => MaxBytes, max_line_bytes => MaxLine,
      max_lines_per_shard => bound(max_lines_per_shard, Opts, 1000, 1, 100000),
      max_files_per_job => bound(max_files_per_job, Opts, 1, 1, 16),
      max_shards => bound(max_shards, Opts, 4096, 1, 4096)};
normalize_limits(_) -> fail(invalid_shard_limits).

bound(Key, Opts, Default, Min, Max) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value >= Min, Value =< Max -> Value;
        _ -> fail({invalid_shard_limit, Key})
    end.

split_sources([], _Profile, _Dir, _Limits, _Ix, Acc) -> lists:reverse(Acc);
split_sources([Input | Rest], Profile, Dir, Limits, Ix, Acc) ->
    SourceDir = filename:join(Dir, "source-" ++ integer_to_list(Ix)),
    ok = expect_ok(filelib:ensure_dir(filename:join(SourceDir, "x"))),
    Remaining = maps:get(max_shards, Limits) - length(Acc),
    case Remaining > 0 of
        true -> ok;
        false -> fail({shard_limit_exceeded, length(Acc) + 1})
    end,
    Segments = split_file(path(Input), SourceDir, Limits#{max_shards => Remaining}),
    split_sources(Rest, Profile, Dir, Limits, Ix + 1,
        lists:reverse(Segments) ++ Acc).

%% 64 KiB reads with an explicit bound on the unconsumed line. Unlike
%% file:read_line/1 this cannot materialize a multi-gigabyte NDJSON line.
split_file(Input, OutDir, Limits) ->
    case file:open(Input, [read, raw, binary]) of
        {ok, Fd} ->
            try
                Initial = #{dir => OutDir, limits => Limits, next => 1,
                            current => undefined, finished => []},
                split_read(Fd, <<>>, Initial)
            after
                %% Mid-line or disk-write errors must not leak an output FD
                %% in a long-running interactive operator shell.
                close_pending_part(),
                _ = file:close(Fd)
            end;
        {error, Why} -> fail({cannot_open_source, Input, Why})
    end.

split_read(Fd, Pending, State) ->
    case file:read(Fd, ?READ_BLOCK) of
        {ok, Chunk} ->
            Data = <<Pending/binary, Chunk/binary>>,
            {State1, Remaining} = split_complete(Data, State),
            check_line(Remaining, State1),
            split_read(Fd, Remaining, State1);
        eof ->
            State1 = case Pending of
                <<>> -> State;
                _ -> write_line(Pending, State)
            end,
            lists:reverse(maps:get(finished, close_part(State1)));
        {error, Why} -> fail({source_read_failed, Why})
    end.

split_complete(Data, State) ->
    case binary:match(Data, <<"\n">>) of
        nomatch -> {State, Data};
        {Pos, 1} ->
            LineBytes = Pos + 1,
            MaxLine = maps:get(max_line_bytes, maps:get(limits, State)),
            if LineBytes > MaxLine -> fail({line_exceeds_limit, LineBytes}); true -> ok end,
            <<Line:LineBytes/binary, Rest/binary>> = Data,
            split_complete(Rest, write_line(Line, State))
    end.

check_line(Bin, State) ->
    MaxLine = maps:get(max_line_bytes, maps:get(limits, State)),
    if byte_size(Bin) > MaxLine -> fail({line_exceeds_limit, byte_size(Bin)});
       true -> ok end.

write_line(Line, State0) ->
    check_line(Line, State0),
    Size = byte_size(Line),
    Limits = maps:get(limits, State0),
    MaxBytes = maps:get(max_shard_bytes, Limits),
    MaxLines = maps:get(max_lines_per_shard, Limits),
    Current = maps:get(current, State0),
    State1 = case Current of
        undefined -> open_part(State0);
        #{bytes := Bytes, lines := Lines} when Bytes + Size > MaxBytes;
                                               Lines >= MaxLines -> open_part(close_part(State0));
        _ -> State0
    end,
    Part = maps:get(current, State1),
    ok = expect_ok(file:write(maps:get(fd, Part), Line)),
    Part1 = Part#{bytes => maps:get(bytes, Part) + Size,
                  lines => maps:get(lines, Part) + 1,
                  hash => crypto:hash_update(maps:get(hash, Part), Line)},
    State1#{current => Part1}.

open_part(State) ->
    Index = maps:get(next, State),
    MaxShards = maps:get(max_shards, maps:get(limits, State)),
    if Index > MaxShards -> fail({shard_limit_exceeded, Index});
       true -> ok end,
    Name = lists:flatten(io_lib:format("part-~8..0B.ndjson", [Index])),
    Path = filename:join(maps:get(dir, State), Name),
    case file:open(Path, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            put({?MODULE, active_part}, Fd),
            State#{next => Index + 1,
            current => #{fd => Fd, path => unicode:characters_to_binary(Path),
                         bytes => 0, lines => 0, hash => crypto:hash_init(sha256)}};
        {error, Why} -> fail({cannot_create_shard, Path, Why})
    end.

close_part(#{current := undefined} = State) -> State;
close_part(State) ->
    Current = maps:get(current, State),
    Fd = maps:get(fd, Current),
    ok = expect_ok(file:sync(Fd)),
    ok = expect_ok(file:close(Fd)),
    erase({?MODULE, active_part}),
    Entry = (maps:without([fd, hash], Current))#{
        sha256 => hex(crypto:hash_final(maps:get(hash, Current)))},
    State#{current => undefined,
           finished => [Entry | maps:get(finished, State)]}.

close_pending_part() ->
    case erase({?MODULE, active_part}) of
        Fd when is_pid(Fd); is_port(Fd) -> _ = file:close(Fd), ok;
        %% prim_file descriptors may be tuples on newer OTP versions.
        undefined -> ok;
        Fd -> _ = file:close(Fd), ok
    end.

%% Group consecutive byte-bounded parts, without materializing record data.
group_splits([], _Limits, [], Acc, _Bytes) -> lists:reverse(Acc);
group_splits([], _Limits, Current, Acc, _Bytes) -> lists:reverse([lists:reverse(Current) | Acc]);
group_splits([S | Rest], Limits, Current, Acc, Bytes) ->
    Size = maps:get(bytes, S),
    Max = maps:get(max_shard_bytes, Limits),
    Files = maps:get(max_files_per_job, Limits),
    case Current =/= [] andalso (length(Current) >= Files orelse Bytes + Size > Max) of
        true -> group_splits([S | Rest], Limits, [], [lists:reverse(Current) | Acc], 0);
        false -> group_splits(Rest, Limits, [S | Current], Acc, Bytes + Size)
    end.

make_entries([], _Spec, _GroupId, _N, Acc) -> lists:reverse(Acc);
make_entries([Parts | Rest], Spec, GroupId, N, Acc) ->
    Files = [maps:get(path, P) || P <- Parts],
    {ok, Identity} = expect(ecai_index_source:describe_paths(Files)),
    Target = maps:get(target, Spec),
    IndexId = maps:get(index_id, Target),
    Suffix = <<"-shard-", (binary:part(GroupId, 0, 12))/binary,
               "-", (integer_to_binary(N))/binary>>,
    Child = Spec#{source => #{paths => Files},
        target => Target#{index_id => <<IndexId/binary, Suffix/binary>>,
                          mode => shard_search},
        finalize => #{build_nft_manifest => false,
                      publish_ipfs => false, auto_mint => false}},
    {ok, Validated} = expect(ecai_index_job_codec:normalize_spec(Child)),
    {ok, SpecHash} = expect(ecai_index_job_codec:spec_hash(Validated)),
    Entry = #{ordinal => N, spec => Validated, source_identity => Identity,
        spec_sha256 => hex(SpecHash),
        idempotency_key => <<"ecai-shard:", GroupId/binary, ":",
                             (integer_to_binary(N))/binary>>,
        bytes => lists:sum([maps:get(bytes, P) || P <- Parts]),
        lines => lists:sum([maps:get(lines, P) || P <- Parts])},
    make_entries(Rest, Spec, GroupId, N+1, [Entry | Acc]).

%% Enqueue a small page, not thousands of simultaneous jobs. Repeating after a
%% crash uses the same durable idempotency keys and produces the same JobIds.
-spec enqueue_batch(file:filename_all(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
enqueue_batch(PlanPath, Start, Count) when is_integer(Start), Start >= 1,
                                           is_integer(Count), Count >= 1, Count =< 64 ->
    %% A plan receipt file has one writer at a time. Independent operators
    %% cannot race and silently discard previously acknowledged job IDs.
    with_plan_lock(PlanPath, fun() -> enqueue_batch_locked(PlanPath, Start, Count) end);
enqueue_batch(_, _, _) -> {error, invalid_batch_window}.

enqueue_batch_locked(PlanPath, Start, Count) ->
    case read_plan(PlanPath) of
        {ok, Plan0} ->
            Entries = lists:sublist(lists:nthtail(erlang:min(Start - 1,
                length(maps:get(entries, Plan0))), maps:get(entries, Plan0)), Count),
            {Receipts, Failures} = lists:foldl(fun(Entry, {Ok, Bad}) ->
                N = maps:get(ordinal, Entry),
                PlacementFile = filename:join(filename:dirname(path(PlanPath)),
                    "dispatch-" ++ integer_to_list(N) ++ ".etf"),
                Admission = case maps:find(N, Ok) of
                    {ok, Legacy} when is_binary(Legacy) -> {ok, Legacy};
                    _ -> ecai_index_dispatch:enqueue(PlacementFile, maps:get(spec, Entry),
                                                    maps:get(idempotency_key, Entry))
                end,
                case Admission of
                    {ok, Placement} -> {Ok#{N => Placement}, Bad};
                    {error, Reason} -> {Ok, [{N, Reason} | Bad]}
                end
            end, {maps:get(receipts, Plan0, #{}), []}, Entries),
            Plan1 = Plan0#{receipts => Receipts},
            case write_term(path(PlanPath), Plan1) of
                ok -> {ok, #{accepted_total => map_size(Receipts),
                             total_shards => length(maps:get(entries, Plan1)),
                             failures => lists:reverse(Failures),
                             receipts => Receipts}};
                {error, Reason} -> {error, {receipt_persist_failed, Reason}}
            end;
        Other -> Other
    end.

with_plan_lock(PlanPath, Fun) ->
    Lock = path(PlanPath) ++ ".lock",
    case file:open(Lock, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            try Fun()
            after
                _ = file:close(Fd),
                _ = file:delete(Lock)
            end;
        {error, eexist} -> {error, {plan_receipts_locked, Lock}};
        {error, Reason} -> {error, {plan_lock_failed, Reason}}
    end.

%% Merge only fully completed receipts; no global in-memory postings merge.
merge(PlanPath, OutputPath0) ->
    case read_plan(PlanPath) of
        {ok, Plan} -> merge_plan(Plan, OutputPath0);
        Error -> Error
    end.

%% Trusted coordinator API for frozen per-node placements. Public clients
%% cannot submit their own receipts or bypass the verified_receipt checks.
merge_plan(Plan, OutputPath0) ->
    try
        Entries = maps:get(entries, Plan),
        Receipts = maps:get(receipts, Plan, #{}),
        case map_size(Receipts) =:= length(Entries) of
            true -> ok;
            false -> fail({missing_shard_jobs, length(Entries) - map_size(Receipts)})
        end,
        Shards = [verified_receipt(Entry, maps:get(maps:get(ordinal, Entry), Receipts))
                  || Entry <- Entries],
        Identity = #{schema => ?MERGED,
            group_id => maps:get(group_id, Plan),
            original_spec_sha256 => hex(crypto:hash(sha256,
                ecai_index_job_codec:canonical_binary(maps:get(original_spec, Plan)))),
            shards => [maps:with([ordinal, snapshot_sha256, job_id], S) || S <- Shards]},
        Root = hex(crypto:hash(sha256, ecai_index_job_codec:canonical_binary(Identity))),
        Manifest = Identity#{index_root => Root, shards => Shards,
            rank_semantics => per_shard_scores_not_global_idf,
            merged_at_ms => erlang:system_time(millisecond)},
        Path = path(OutputPath0),
        ok = expect_ok(write_term(Path, Manifest)),
        {ok, Manifest}
    catch
        throw:{shard_error, Reason} -> {error, Reason};
        error:{badmatch, {error, Reason}} -> {error, Reason};
        Class:Reason -> {error, {shard_merge_failed, Class, Reason}}
    end.

verified_receipt(Entry, Placement) ->
    {ok, Job} = expect(ecai_index_dispatch:get(Placement)),
    JobId = maps:get(<<"id">>, Job),
    case maps:get(<<"state">>, Job, undefined) of
        <<"completed">> -> ok;
        Other -> fail({shard_not_complete, maps:get(ordinal, Entry), Other})
    end,
    case maps:get(<<"spec_hash">>, Job, undefined) =:= maps:get(spec_sha256, Entry) of
        true -> ok;
        false -> fail({shard_spec_changed, JobId})
    end,
    Paths = maps:get(paths, maps:get(source, maps:get(spec, Entry))),
    ok = expect_ok(ecai_index_source:verify_paths(Paths, maps:get(source_identity, Entry))),
    Result = maps:get(<<"result">>, Job, #{}),
    SnapPath = maps:get(<<"search_snapshot_path">>, Result, undefined),
    SnapSha = maps:get(<<"search_snapshot_sha256">>, Result, undefined),
    case is_binary(SnapPath) andalso is_binary(SnapSha) andalso
         byte_size(SnapSha) =:= 64 of
        true -> ok;
        false -> fail({missing_shard_snapshot, JobId})
    end,
    ok = expect_ok(verify_snapshot(SnapPath, SnapSha)),
    #{ordinal => maps:get(ordinal, Entry), job_id => JobId,
      snapshot_path => SnapPath, snapshot_sha256 => SnapSha,
      records_indexed => maps:get(<<"records_indexed">>, Result, 0)}.

%% Query one verified shard at a time, so peak ETS usage scales with the shard
%% rather than with the aggregate corpus. Scores/roots stay per-shard.
search(ManifestPath, Query, Limit) when is_map(Query), is_integer(Limit),
                                        Limit >= 1, Limit =< 1000 ->
    try
        {ok, Manifest} = expect(read_manifest(ManifestPath)),
        Shards = maps:get(shards, Manifest),
        %% Reduce after every shard. Never accumulate O(shards * Limit)
        %% results or proofs in a desktop process.
        {Top, Proofs} = lists:foldl(fun(S, {AccHits, AccProofs}) ->
            SnapPath = maps:get(snapshot_path, S),
            ok = expect_ok(verify_snapshot(SnapPath, maps:get(snapshot_sha256, S))),
            Ctx0 = ecai_search:new(),
            try
                {ok, Ctx} = expect(ecai_search:load(Ctx0, path(SnapPath))),
                {Results, Headers} = ecai_search:search(Ctx, Query, Limit),
                Ord = maps:get(ordinal, S),
                Best = bounded_top_k(AccHits ++
                    [H#{shard_ordinal => Ord} || H <- Results], Limit),
                Needed = lists:usort([maps:get(shard_ordinal, H) || H <- Best]),
                {Best, maps:with(Needed, AccProofs#{Ord => Headers})}
            after _ = ecai_search:wipe(Ctx0) end
        end, {[], #{}}, Shards),
        {ok, #{results => Top,
            proofs_by_shard => Proofs,
            index_root => maps:get(index_root, Manifest),
            ranking => per_shard_heuristic_not_global_idf}}
    catch
        throw:{shard_error, Reason} -> {error, Reason};
        error:{badmatch, {error, Reason}} -> {error, Reason};
        Class:Reason -> {error, {shard_search_failed, Class, Reason}}
    end;
search(_, _, _) -> {error, invalid_query}.

bounded_top_k(Hits, Limit) ->
    Sorted = lists:sort(fun(A, B) ->
        ScoreA = maps:get(score, A, 0), ScoreB = maps:get(score, B, 0),
        case ScoreA =:= ScoreB of
            true -> {maps:get(doc_id, A), maps:get(shard_ordinal, A)} <
                    {maps:get(doc_id, B), maps:get(shard_ordinal, B)};
            false -> ScoreA > ScoreB
        end
    end, Hits),
    lists:sublist(unique_docs(Sorted, #{}, []), Limit).

unique_docs([], _Seen, Acc) -> lists:reverse(Acc);
unique_docs([Hit | Rest], Seen, Acc) ->
    Id = maps:get(doc_id, Hit),
    case maps:is_key(Id, Seen) of
        true -> unique_docs(Rest, Seen, Acc);
        false -> unique_docs(Rest, Seen#{Id => true}, [Hit | Acc])
    end.

%% Called by the shard-mode adapters before the durable 'completed' transition.
%% Retrying the same job cannot overwrite an existing immutable snapshot.
snapshot(#{id := Id, spec := #{target := Target}}, Ctx) ->
    try
        Dir = filename:join([path(maps:get(base_dir, Target)),
            "shard-snapshots", binary_to_list(Id)]),
        ok = expect_ok(filelib:ensure_dir(filename:join(Dir, "x"))),
        Temp = filename:join(Dir, ".writing-" ++ integer_to_list(
            erlang:unique_integer([positive, monotonic])) ++ ".etf"),
        ok = expect_ok(ecai_search:save(Ctx, Temp)),
        {ok, #{files := [Desc]}} = expect(ecai_index_source:describe_paths([Temp])),
        Sha = maps:get(sha256, Desc),
        Size = maps:get(bytes, Desc),
        MaxSnapshot = snapshot_limit(),
        case Size =< MaxSnapshot of
            true -> ok;
            false ->
                _ = file:delete(Temp),
                fail({snapshot_size_limit_exceeded, Size, MaxSnapshot})
        end,
        Permanent = filename:join(Dir, binary_to_list(Sha) ++ ".etf"),
        case filelib:is_file(Permanent) of
            true ->
                ok = expect_ok(verify_snapshot(Permanent, Sha)),
                ok = expect_ok(file:delete(Temp));
            false -> ok = expect_ok(file:rename(Temp, Permanent))
        end,
        {ok, #{search_snapshot_path => unicode:characters_to_binary(Permanent),
               search_snapshot_sha256 => Sha,
               search_snapshot_bytes => maps:get(bytes, Desc)}}
    catch
        throw:{shard_error, Reason} -> {error, Reason};
        error:{badmatch, {error, Reason}} -> {error, Reason};
        Class:Reason -> {error, {snapshot_write_failed, Class, Reason}}
    end.

snapshot_limit() ->
    case application:get_env(ecai, shard_snapshot_max_bytes, 268435456) of
        Max when is_integer(Max), Max >= 1048576, Max =< 1073741824 -> Max;
        _ -> 268435456
    end.

verify_snapshot(Path, Sha) ->
    Max = snapshot_limit(),
    case file:read_file_info(path(Path)) of
        {ok, #file_info{size = Size}} when Size > Max ->
            {error, {shard_snapshot_too_large, Size}};
        {error, _} = Error -> Error;
        _ -> verify_snapshot_digest(Path, Sha)
    end.

verify_snapshot_digest(Path, Sha) ->
    case ecai_index_source:describe_paths([Path]) of
        {ok, #{files := [#{sha256 := Sha}]}} -> ok;
        {ok, _} -> {error, snapshot_hash_mismatch};
        {error, _} = Error -> Error
    end.

read_plan(File) ->
    case read_term(path(File)) of
        {ok, #{schema := ?SCHEMA, entries := Entries} = Plan} when is_list(Entries) ->
            {ok, Plan};
        {ok, _} -> {error, invalid_shard_plan};
        Error -> Error
    end.

read_manifest(File) ->
    case read_term(path(File)) of
        {ok, #{schema := ?MERGED, shards := Shards} = Manifest} when is_list(Shards) ->
            Identity = (maps:with([schema, group_id, original_spec_sha256], Manifest))#{
                shards => [maps:with([ordinal, snapshot_sha256, job_id], S) || S <- Shards]},
            Root = hex(crypto:hash(sha256, ecai_index_job_codec:canonical_binary(Identity))),
            case Root =:= maps:get(index_root, Manifest, undefined) of
                true -> {ok, Manifest};
                false -> {error, invalid_shard_manifest_root}
            end;
        {ok, _} -> {error, invalid_shard_manifest};
        Error -> Error
    end.

read_term(File) ->
    case file:read_file_info(File) of
        {ok, #file_info{size = Size}} when Size =< ?MAX_MANIFEST_BYTES ->
            case file:read_file(File) of
                {ok, Bytes} ->
                    try {ok, binary_to_term(Bytes, [safe])}
                    catch error:badarg -> {error, corrupt_shard_manifest} end;
                Error -> Error
            end;
        {ok, _} -> {error, shard_manifest_too_large};
        Error -> Error
    end.

write_term(File, Term) ->
    ok = expect_ok(filelib:ensure_dir(filename:join(filename:dirname(File), "x"))),
    Bytes = term_to_binary(Term, [compressed]),
    case byte_size(Bytes) =< ?MAX_MANIFEST_BYTES of
        false -> {error, shard_manifest_too_large};
        true ->
            Tmp = File ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
            case file:open(Tmp, [write, raw, binary, exclusive]) of
                {ok, Fd} ->
                    Result = try
                        ok = expect_ok(file:write(Fd, Bytes)),
                        file:sync(Fd)
                    after _ = file:close(Fd) end,
                    case Result of
                        ok -> file:rename(Tmp, File);
                        Error -> _ = file:delete(Tmp), Error
                    end;
                Error -> Error
            end
    end.

hex(Digest) -> ecai_index_job_codec:id_hex(Digest).
path(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
path(List) when is_list(List) -> List.
expect({ok, Value}) -> {ok, Value};
expect({error, Why}) -> fail(Why).
expect_ok(ok) -> ok;
expect_ok({error, Why}) -> fail(Why).
fail(Why) -> throw({shard_error, Why}).
