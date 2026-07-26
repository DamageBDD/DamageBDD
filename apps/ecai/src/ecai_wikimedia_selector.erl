%%--------------------------------------------------------------------
%% Low-memory pageview selection for the Wikimedia visibility corpus.
%%
%% Processing is deliberately split into recoverable units:
%%   1. Each pageview month is decompressed once into independent partition
%%      files under a temporary directory, then atomically published.
%%   2. One partition at a time is aggregated in ETS and reduced to its local
%%      top-K file.
%%   3. A streaming K-way merge produces the global ranked selection.
%%
%% No complete pageview dump or global page table is held in memory.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_selector).

-export([
    version/0,
    prepare/3,
    spool_month/4,
    aggregate_partition/3,
    merge_selection/2,
    load_selection/1,
    lookup/3,
    close_selection/1,
    parse_pageview_line/2,
    paths/1
]).

-define(SCHEMA, <<"ecai-wikimedia-selector/v1">>).
-define(RECORD_HEADER_BYTES, 20).
-define(DEFAULT_PARTITIONS, 128).
-define(DEFAULT_BUFFER_BYTES, 262144).
-define(DEFAULT_LIMIT, 250000).
-define(DEFAULT_ACTIVE_MONTHS, 6).
-define(DEFAULT_OVERSAMPLE_PERCENT, 125).

-spec version() -> binary().
version() -> ?SCHEMA.

-spec prepare(file:filename_all(), map(), map()) -> {ok, map()} | {error, term()}.
prepare(WorkDir0, Catalog, Opts) when is_map(Catalog), is_map(Opts) ->
    try
        WorkDir = path_list(WorkDir0),
        SelectDir = filename:join(WorkDir, "selection"),
        Downloads = filename:join(WorkDir, "downloads/pageviews"),
        Spool = filename:join(SelectDir, "spool"),
        Top = filename:join(SelectDir, "top"),
        ok = filelib:ensure_dir(filename:join(Downloads, "x")),
        ok = filelib:ensure_dir(filename:join(Spool, "x")),
        ok = filelib:ensure_dir(filename:join(Top, "x")),
        Partitions = bounded_integer(
            selection_shards,
            Opts,
            ?DEFAULT_PARTITIONS,
            8,
            1024
        ),
        Limit = bounded_integer(limit, Opts, ?DEFAULT_LIMIT, 1, 10000000),
        Oversample = bounded_integer(
            oversample_percent,
            Opts,
            ?DEFAULT_OVERSAMPLE_PERCENT,
            100,
            1000
        ),
        CandidateLimit = (Limit * Oversample + 99) div 100,
        MinMonths0 = bounded_integer(
            minimum_active_months,
            Opts,
            ?DEFAULT_ACTIVE_MONTHS,
            1,
            64
        ),
        Months = maps:get(pageview_months, Catalog),
        MinMonths = erlang:min(MinMonths0, length(Months)),
        {ok, #{
            schema => ?SCHEMA,
            work_dir => WorkDir,
            select_dir => SelectDir,
            downloads_dir => Downloads,
            spool_dir => Spool,
            top_dir => Top,
            selection_path => filename:join(SelectDir, "selection.jsonl"),
            selection_meta_path => filename:join(SelectDir, "selection-meta.json"),
            partitions => Partitions,
            buffer_bytes => bounded_integer(
                partition_buffer_bytes,
                Opts,
                ?DEFAULT_BUFFER_BYTES,
                4096,
                16777216
            ),
            limit => Limit,
            candidate_limit => CandidateLimit,
            minimum_active_months => MinMonths,
            project => maps:get(pageview_project, Catalog),
            months => Months,
            keep_downloads => maps:get(keep_downloads, Opts, false),
            keep_intermediates => maps:get(keep_intermediates, Opts, false)
        }}
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace -> {error, {selector_prepare_failed, Class, Reason, Stacktrace}}
    end;
prepare(_WorkDir, _Catalog, _Opts) ->
    {error, badarg}.

-spec paths(map()) -> map().
paths(Runtime) ->
    maps:with(
        [
            select_dir,
            downloads_dir,
            spool_dir,
            top_dir,
            selection_path,
            selection_meta_path
        ],
        Runtime
    ).

-spec spool_month(map(), map(), pos_integer(), fun((map()) -> any())) ->
    {ok, map()} | {error, term()}.
spool_month(Runtime, Source, MonthIndex, ProgressFun) when
    is_map(Runtime),
    is_map(Source),
    is_integer(MonthIndex),
    MonthIndex > 0,
    is_function(ProgressFun, 1)
->
    Month = maps:get(month, Source),
    FinalDir = filename:join(maps:get(spool_dir, Runtime), binary_to_list(Month)),
    Marker = filename:join(FinalDir, "COMPLETE.json"),
    case read_marker(Marker) of
        {ok, Meta} -> {ok, Meta#{cached => true}};
        not_found -> spool_month_fresh(Runtime, Source, MonthIndex, ProgressFun, FinalDir);
        {error, _Reason} = Error -> Error
    end;
spool_month(_Runtime, _Source, _MonthIndex, _ProgressFun) ->
    {error, badarg}.

spool_month_fresh(Runtime, Source, MonthIndex, ProgressFun, FinalDir) ->
    Name = maps:get(name, Source),
    DownloadPath = filename:join(
        maps:get(downloads_dir, Runtime),
        binary_to_list(Name)
    ),
    safe_progress(ProgressFun, #{
        phase => downloading_pageviews,
        month => maps:get(month, Source),
        source => maps:get(url, Source)
    }),
    case
        ecai_http_stream:download(
            maps:get(url, Source),
            DownloadPath,
            #{progress_fun => ProgressFun}
        )
    of
        {ok, DownloadMeta} ->
            TmpDir = FinalDir ++ ".tmp-" ++ unique_suffix(),
            _ = remove_tree(TmpDir),
            ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
            case open_partition_writers(TmpDir, maps:get(partitions, Runtime)) of
                {ok, Writers0} ->
                    Initial = #{
                        writers => Writers0,
                        project_rows => 0,
                        skipped_rows => 0,
                        malformed_rows => 0,
                        total_views => 0
                    },
                    FoldFun = fun(Line, State0) ->
                        spool_pageview_line(
                            Line,
                            State0,
                            Runtime,
                            MonthIndex
                        )
                    end,
                    case
                        ecai_bzip2_stream:fold_lines(
                            DownloadPath,
                            FoldFun,
                            Initial,
                            #{}
                        )
                    of
                        {ok, State1, StreamStats} ->
                            case
                                close_partition_writers(
                                    maps:get(writers, State1),
                                    maps:get(buffer_bytes, Runtime)
                                )
                            of
                                {ok, PartitionStats} ->
                                    Meta = #{
                                        schema => ?SCHEMA,
                                        month => maps:get(month, Source),
                                        month_index => MonthIndex,
                                        source_url => maps:get(url, Source),
                                        source_name => Name,
                                        download => DownloadMeta,
                                        stream => StreamStats,
                                        project_rows => maps:get(project_rows, State1),
                                        skipped_rows => maps:get(skipped_rows, State1),
                                        malformed_rows => maps:get(malformed_rows, State1),
                                        total_views => maps:get(total_views, State1),
                                        partitions => PartitionStats
                                    },
                                    case
                                        atomic_write(
                                            filename:join(TmpDir, "COMPLETE.json"),
                                            jsx:encode(ecai_index_job_codec:externalize(Meta))
                                        )
                                    of
                                        ok ->
                                            case publish_directory(TmpDir, FinalDir) of
                                                ok ->
                                                    maybe_delete_download(Runtime, DownloadPath),
                                                    safe_progress(ProgressFun, #{
                                                        phase => pageview_month_complete,
                                                        month => maps:get(month, Source),
                                                        records => maps:get(project_rows, State1),
                                                        total_views => maps:get(total_views, State1)
                                                    }),
                                                    {ok, Meta};
                                                {error, _Reason} = Error ->
                                                    Error
                                            end;
                                        {error, Reason} ->
                                            {error, {month_marker_write_failed, Reason}}
                                    end;
                                {error, _Reason} = Error ->
                                    _ = close_partition_writers_best_effort(
                                        maps:get(writers, State1)
                                    ),
                                    Error
                            end;
                        {error, Reason} ->
                            _ = close_partition_writers_best_effort(
                                maps:get(writers, Initial)
                            ),
                            {error, {pageview_decompression_failed, Name, Reason}}
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {pageview_download_failed, Name, Reason}}
    end.

spool_pageview_line(Line, State0, Runtime, MonthIndex) ->
    Project = maps:get(project, Runtime),
    case parse_pageview_line(Line, Project) of
        {ok, PageId, Title, Views} ->
            Record = encode_spool_record(PageId, Views, MonthIndex, Title),
            Partition = PageId rem maps:get(partitions, Runtime),
            Writers0 = maps:get(writers, State0),
            case
                append_partition_record(
                    Writers0,
                    Partition,
                    Record,
                    maps:get(buffer_bytes, Runtime)
                )
            of
                {ok, Writers1} ->
                    {ok, State0#{
                        writers => Writers1,
                        project_rows => maps:get(project_rows, State0) + 1,
                        total_views => maps:get(total_views, State0) + Views
                    }};
                {error, _Reason} = Error ->
                    Error
            end;
        skip ->
            {ok, State0#{skipped_rows => maps:get(skipped_rows, State0) + 1}};
        malformed ->
            {ok, State0#{malformed_rows => maps:get(malformed_rows, State0) + 1}}
    end.

-spec parse_pageview_line(binary(), binary()) ->
    {ok, non_neg_integer(), binary(), non_neg_integer()} | skip | malformed.
parse_pageview_line(<<>>, _Project) ->
    skip;
parse_pageview_line(Line, Project) when is_binary(Line), is_binary(Project) ->
    Tokens = binary:split(Line, <<" ">>, [global, trim_all]),
    case Tokens of
        [Project, Title, PageIdBin, ViewsBin | _Rest] ->
            case {parse_nonnegative(PageIdBin), parse_nonnegative(ViewsBin)} of
                {{ok, PageId}, {ok, Views}} when PageId > 0, Views > 0 ->
                    case byte_size(Title) =< 65535 of
                        true -> {ok, PageId, Title, Views};
                        false -> malformed
                    end;
                _ ->
                    malformed
            end;
        [OtherProject, _Title, _PageIdBin, _ViewsBin | _Rest] when
            OtherProject =/= Project
        ->
            skip;
        _ ->
            malformed
    end;
parse_pageview_line(_Line, _Project) ->
    malformed.

-spec aggregate_partition(map(), non_neg_integer(), fun((map()) -> any())) ->
    {ok, map()} | {error, term()}.
aggregate_partition(Runtime, Partition, ProgressFun) when
    is_map(Runtime),
    is_integer(Partition),
    Partition >= 0,
    is_function(ProgressFun, 1)
->
    Count = maps:get(partitions, Runtime),
    case Partition < Count of
        false ->
            {error, {invalid_partition, Partition, Count}};
        true ->
            TopPath = top_path(Runtime, Partition),
            MarkerPath = TopPath ++ ".complete.json",
            case read_marker(MarkerPath) of
                {ok, Meta} ->
                    {ok, Meta#{cached => true}};
                not_found ->
                    aggregate_partition_fresh(Runtime, Partition, ProgressFun, TopPath, MarkerPath);
                {error, _Reason} = Error ->
                    Error
            end
    end;
aggregate_partition(_Runtime, _Partition, _ProgressFun) ->
    {error, badarg}.

aggregate_partition_fresh(Runtime, Partition, ProgressFun, TopPath, MarkerPath) ->
    safe_progress(ProgressFun, #{phase => aggregating_pageviews, partition => Partition}),
    Tab = ets:new(ecai_wikimedia_pageviews, [set, private, compressed]),
    try
        case aggregate_partition_months(Runtime, Partition, Tab) of
            {ok, RecordCount} ->
                CandidateLimit = maps:get(candidate_limit, Runtime),
                MinMonths = maps:get(minimum_active_months, Runtime),
                TopSet = ets:foldl(
                    fun({PageId, Views, Mask, _LatestMonth, Title}, Heap0) ->
                        MonthCount = popcount(Mask),
                        case MonthCount >= MinMonths of
                            true ->
                                bounded_top_insert(
                                    {Views, PageId, Title, MonthCount},
                                    Heap0,
                                    CandidateLimit
                                );
                            false ->
                                Heap0
                        end
                    end,
                    gb_sets:empty(),
                    Tab
                ),
                Entries = lists:reverse(gb_sets:to_list(TopSet)),
                case write_top_file(TopPath, Entries) of
                    ok ->
                        Meta = #{
                            schema => ?SCHEMA,
                            partition => Partition,
                            aggregate_records => RecordCount,
                            unique_pages => ets:info(Tab, size),
                            top_records => length(Entries),
                            minimum_active_months => MinMonths,
                            candidate_limit => CandidateLimit
                        },
                        case
                            atomic_write(
                                MarkerPath,
                                jsx:encode(ecai_index_job_codec:externalize(Meta))
                            )
                        of
                            ok -> {ok, Meta};
                            {error, Reason} -> {error, {partition_marker_write_failed, Reason}}
                        end;
                    {error, _Reason} = Error ->
                        Error
                end;
            {error, _Reason} = Error ->
                Error
        end
    after
        ets:delete(Tab)
    end.

aggregate_partition_months(Runtime, Partition, Tab) ->
    Months = maps:get(months, Runtime),
    aggregate_month_files(Runtime, Partition, Months, Tab, 0).

aggregate_month_files(_Runtime, _Partition, [], _Tab, Count) ->
    {ok, Count};
aggregate_month_files(Runtime, Partition, [Month | Rest], Tab, Count0) ->
    Path = spool_path(Runtime, Month, Partition),
    case
        fold_spool_records(Path, fun(PageId, Views, MonthIndex, Title) ->
            update_aggregate(Tab, PageId, Views, MonthIndex, Title)
        end)
    of
        {ok, Count} ->
            aggregate_month_files(Runtime, Partition, Rest, Tab, Count0 + Count);
        {error, _Reason} = Error ->
            Error
    end.

update_aggregate(Tab, PageId, Views, MonthIndex, Title) ->
    Bit = 1 bsl (MonthIndex - 1),
    case ets:lookup(Tab, PageId) of
        [] ->
            true = ets:insert(Tab, {PageId, Views, Bit, MonthIndex, Title});
        [{PageId, ExistingViews, Mask, LatestMonth, ExistingTitle}] ->
            {NewLatest, NewTitle} =
                case MonthIndex >= LatestMonth of
                    true -> {MonthIndex, Title};
                    false -> {LatestMonth, ExistingTitle}
                end,
            true = ets:insert(
                Tab,
                {PageId, ExistingViews + Views, Mask bor Bit, NewLatest, NewTitle}
            )
    end,
    ok.

-spec merge_selection(map(), fun((map()) -> any())) -> {ok, map()} | {error, term()}.
merge_selection(Runtime, ProgressFun) when is_map(Runtime), is_function(ProgressFun, 1) ->
    SelectionPath = maps:get(selection_path, Runtime),
    MetaPath = maps:get(selection_meta_path, Runtime),
    case {filelib:is_regular(SelectionPath), read_marker(MetaPath)} of
        {true, {ok, Meta}} ->
            maybe_cleanup_selection_inputs(Runtime),
            {ok, Meta#{cached => true}};
        _ ->
            merge_selection_fresh(Runtime, ProgressFun, SelectionPath, MetaPath)
    end;
merge_selection(_Runtime, _ProgressFun) ->
    {error, badarg}.

merge_selection_fresh(Runtime, ProgressFun, SelectionPath, MetaPath) ->
    safe_progress(ProgressFun, #{phase => merging_selection}),
    Partitions = maps:get(partitions, Runtime),
    Paths = [top_path(Runtime, P) || P <- lists:seq(0, Partitions - 1)],
    case open_top_readers(Paths, 0, [], gb_sets:empty()) of
        {ok, Readers0, Heap0} ->
            Tmp = SelectionPath ++ ".tmp",
            case file:open(Tmp, [write, raw, binary]) of
                {ok, Out} ->
                    Limit = maps:get(candidate_limit, Runtime),
                    Result =
                        try
                            merge_top_loop(Readers0, Heap0, Out, Limit, 1, 0, 0)
                        after
                            close_readers(Readers0),
                            ok = file:close(Out)
                        end,
                    case Result of
                        {ok, Selected, TotalViews} ->
                            ok = sync_file(Tmp),
                            case file:rename(Tmp, SelectionPath) of
                                ok ->
                                    Digest = hash_file(SelectionPath),
                                    Meta = #{
                                        schema => ?SCHEMA,
                                        selected => Selected,
                                        requested_limit => maps:get(limit, Runtime),
                                        candidate_limit => Limit,
                                        minimum_active_months => maps:get(
                                            minimum_active_months,
                                            Runtime
                                        ),
                                        total_views => TotalViews,
                                        sha256 => ecai_index_job_codec:id_hex(Digest),
                                        path => unicode:characters_to_binary(SelectionPath)
                                    },
                                    case
                                        atomic_write(
                                            MetaPath,
                                            jsx:encode(ecai_index_job_codec:externalize(Meta))
                                        )
                                    of
                                        ok ->
                                            maybe_cleanup_selection_inputs(Runtime),
                                            {ok, Meta};
                                        {error, Reason} ->
                                            {error, {selection_meta_write_failed, Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, {selection_rename_failed, Reason}}
                            end;
                        {error, _Reason} = Error ->
                            _ = file:delete(Tmp),
                            Error
                    end;
                {error, Reason} ->
                    {error, {selection_open_failed, Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

merge_top_loop(_Readers, _Heap, _Out, Limit, _Rank, Selected, TotalViews) when
    Selected >= Limit
->
    {ok, Selected, TotalViews};
merge_top_loop(Readers, Heap, Out, Limit, _Rank, Selected, TotalViews) ->
    case gb_sets:is_empty(Heap) of
        true ->
            {ok, Selected, TotalViews};
        false ->
            {{_NegViews, _NegPageId, ReaderIndex, Record}, Heap1} =
                gb_sets:take_smallest(Heap),
            Rank = Selected + 1,
            Ranked = Record#{rank => Rank},
            case
                file:write(
                    Out,
                    <<(jsx:encode(ecai_index_job_codec:externalize(Ranked)))/binary, "\n">>
                )
            of
                ok ->
                    case read_next_top(Readers, ReaderIndex, Heap1) of
                        {ok, Readers1, Heap2} ->
                            merge_top_loop(
                                Readers1,
                                Heap2,
                                Out,
                                Limit,
                                Rank + 1,
                                Selected + 1,
                                TotalViews + maps:get(pageviews, Record)
                            );
                        {error, _Reason} = Error ->
                            Error
                    end;
                {error, Reason} ->
                    {error, {selection_write_failed, Reason}}
            end
    end.

-spec load_selection(file:filename_all()) -> {ok, ets:tid(), non_neg_integer()} | {error, term()}.
load_selection(Path0) ->
    try
        Path = path_list(Path0),
        Tab = ets:new(ecai_wikimedia_selection, [set, private, compressed, {read_concurrency, true}]),
        case file:open(Path, [read, raw, binary]) of
            {ok, Fd} ->
                try load_selection_lines(Fd, Tab, 0) of
                    {ok, Count} ->
                        {ok, Tab, Count};
                    {error, _Reason} = Error ->
                        ets:delete(Tab),
                        Error
                after
                    ok = file:close(Fd)
                end;
            {error, Reason} ->
                ets:delete(Tab),
                {error, {selection_open_failed, Path, Reason}}
        end
    catch
        error:badarg -> {error, badarg}
    end.

-spec lookup(ets:tid(), non_neg_integer() | undefined, binary() | undefined) ->
    {ok, map()} | not_found.
lookup(Tab, PageId, Title) ->
    case lookup_key(Tab, {id, PageId}) of
        {ok, Meta} -> {ok, Meta};
        not_found -> lookup_key(Tab, {title, Title})
    end.

-spec close_selection(ets:tid()) -> ok.
close_selection(Tab) ->
    try ets:delete(Tab) of
        true -> ok
    catch
        error:badarg -> ok
    end.

load_selection_lines(Fd, Tab, Count) ->
    case file:read_line(Fd) of
        eof ->
            {ok, Count};
        {ok, Line} ->
            case decode_json_line(Line) of
                {ok, Map} ->
                    PageId = maps:get(<<"page_id">>, Map),
                    Title = maps:get(<<"title">>, Map),
                    Meta = #{
                        page_id => PageId,
                        title => Title,
                        pageviews => maps:get(<<"pageviews">>, Map),
                        active_months => maps:get(<<"active_months">>, Map),
                        rank => maps:get(<<"rank">>, Map)
                    },
                    true = ets:insert(Tab, [{{id, PageId}, Meta}, {{title, Title}, Meta}]),
                    load_selection_lines(Fd, Tab, Count + 1);
                {error, Reason} ->
                    {error, {invalid_selection_line, Count + 1, Reason}}
            end;
        {error, Reason} ->
            {error, {selection_read_failed, Reason}}
    end.

lookup_key(_Tab, {_Kind, undefined}) ->
    not_found;
lookup_key(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [{Key, Meta}] -> {ok, Meta};
        [] -> not_found
    end.

open_partition_writers(Dir, Count) ->
    open_partition_writers(Dir, Count, 0, []).

open_partition_writers(_Dir, Count, Count, Acc) ->
    {ok, list_to_tuple(lists:reverse(Acc))};
open_partition_writers(Dir, Count, Index, Acc) ->
    Path = filename:join(Dir, partition_filename(Index)),
    case file:open(Path, [write, raw, binary]) of
        {ok, Fd} ->
            open_partition_writers(
                Dir,
                Count,
                Index + 1,
                [{Fd, [], 0, 0, Path} | Acc]
            );
        {error, Reason} ->
            _ = close_partition_writers_best_effort(list_to_tuple(lists:reverse(Acc))),
            {error, {partition_open_failed, Index, Reason}}
    end.

append_partition_record(Writers0, Partition, Record, BufferLimit) ->
    Position = Partition + 1,
    {Fd, Chunks0, Bytes0, Count0, Path} = element(Position, Writers0),
    Chunks1 = [Record | Chunks0],
    Bytes1 = Bytes0 + byte_size(Record),
    case Bytes1 >= BufferLimit of
        true ->
            case file:write(Fd, lists:reverse(Chunks1)) of
                ok ->
                    {ok, setelement(Position, Writers0, {Fd, [], 0, Count0 + 1, Path})};
                {error, Reason} ->
                    {error, {partition_write_failed, Partition, Reason}}
            end;
        false ->
            {ok,
                setelement(
                    Position,
                    Writers0,
                    {Fd, Chunks1, Bytes1, Count0 + 1, Path}
                )}
    end.

close_partition_writers(Writers0, _BufferLimit) ->
    close_partition_writers(Writers0, 1, []).

close_partition_writers(Writers, Position, Acc) when Position > tuple_size(Writers) ->
    {ok, lists:reverse(Acc)};
close_partition_writers(Writers, Position, Acc) ->
    {Fd, Chunks, _Bytes, Count, Path} = element(Position, Writers),
    Result =
        try
            case Chunks of
                [] -> ok;
                _ -> ok = file:write(Fd, lists:reverse(Chunks))
            end,
            ok = file:sync(Fd),
            ok
        catch
            error:{badmatch, {error, Reason0}} -> {error, Reason0};
            Class:Reason0 -> {error, {Class, Reason0}}
        after
            _ = file:close(Fd)
        end,
    case Result of
        ok ->
            close_partition_writers(
                Writers,
                Position + 1,
                [
                    #{
                        partition => Position - 1,
                        records => Count,
                        bytes => file_size(Path)
                    }
                    | Acc
                ]
            );
        {error, Reason} ->
            {error, {partition_close_failed, Position - 1, Reason}}
    end.

close_partition_writers_best_effort(Writers) when is_tuple(Writers) ->
    lists:foreach(
        fun(Position) ->
            case element(Position, Writers) of
                {Fd, _Chunks, _Bytes, _Count, _Path} ->
                    try file:close(Fd) of
                        _ -> ok
                    catch
                        _:_ -> ok
                    end
            end
        end,
        lists:seq(1, tuple_size(Writers))
    ),
    ok.

encode_spool_record(PageId, Views, MonthIndex, Title) ->
    <<
        PageId:64/unsigned-big-integer,
        Views:64/unsigned-big-integer,
        MonthIndex:16/unsigned-big-integer,
        (byte_size(Title)):16/unsigned-big-integer,
        Title/binary
    >>.

fold_spool_records(Path, Fun) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                fold_spool_loop(Fd, Fun, 0)
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, {spool_open_failed, Path, Reason}}
    end.

fold_spool_loop(Fd, Fun, Count) ->
    case file:read(Fd, ?RECORD_HEADER_BYTES) of
        eof ->
            {ok, Count};
        {ok, <<
            PageId:64/unsigned-big-integer,
            Views:64/unsigned-big-integer,
            MonthIndex:16/unsigned-big-integer,
            TitleLen:16/unsigned-big-integer
        >>} ->
            case file:read(Fd, TitleLen) of
                {ok, Title} when byte_size(Title) =:= TitleLen ->
                    ok = Fun(PageId, Views, MonthIndex, Title),
                    fold_spool_loop(Fd, Fun, Count + 1);
                eof ->
                    {error, {truncated_spool_title, Count}};
                {ok, Short} ->
                    {error, {truncated_spool_title, Count, byte_size(Short), TitleLen}};
                {error, Reason} ->
                    {error, {spool_read_failed, Reason}}
            end;
        {ok, Short} ->
            {error, {truncated_spool_header, Count, byte_size(Short)}};
        {error, Reason} ->
            {error, {spool_read_failed, Reason}}
    end.

bounded_top_insert(Entry, Heap0, Limit) ->
    Heap1 = gb_sets:add(Entry, Heap0),
    case gb_sets:size(Heap1) > Limit of
        true ->
            {_Smallest, Heap2} = gb_sets:take_smallest(Heap1),
            Heap2;
        false ->
            Heap1
    end.

write_top_file(Path, Entries) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    lists:foreach(
                        fun({Views, PageId, Title, MonthCount}) ->
                            Line = jsx:encode(#{
                                <<"page_id">> => PageId,
                                <<"title">> => Title,
                                <<"pageviews">> => Views,
                                <<"active_months">> => MonthCount
                            }),
                            ok = file:write(Fd, <<Line/binary, "\n">>)
                        end,
                        Entries
                    ),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} ->
            {error, {top_file_open_failed, Reason}}
    end.

open_top_readers([], _Index, ReadersAcc, Heap) ->
    {ok, list_to_tuple(lists:reverse(ReadersAcc)), Heap};
open_top_readers([Path | Rest], Index, ReadersAcc, Heap0) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            case read_top_record(Fd) of
                eof ->
                    open_top_readers(Rest, Index + 1, [Fd | ReadersAcc], Heap0);
                {ok, Record} ->
                    Heap1 = gb_sets:add(heap_entry(Index, Record), Heap0),
                    open_top_readers(Rest, Index + 1, [Fd | ReadersAcc], Heap1);
                {error, Reason} ->
                    _ = file:close(Fd),
                    close_reader_list(ReadersAcc),
                    {error, {top_file_invalid, Path, Reason}}
            end;
        {error, Reason} ->
            close_reader_list(ReadersAcc),
            {error, {top_file_open_failed, Path, Reason}}
    end.

read_next_top(Readers, ReaderIndex, Heap0) ->
    Fd = element(ReaderIndex + 1, Readers),
    case read_top_record(Fd) of
        eof -> {ok, Readers, Heap0};
        {ok, Record} -> {ok, Readers, gb_sets:add(heap_entry(ReaderIndex, Record), Heap0)};
        {error, _Reason} = Error -> Error
    end.

heap_entry(ReaderIndex, Record) ->
    Views = maps:get(pageviews, Record),
    PageId = maps:get(page_id, Record),
    {-Views, -PageId, ReaderIndex, Record}.

read_top_record(Fd) ->
    case file:read_line(Fd) of
        eof ->
            eof;
        {ok, Line} ->
            case decode_json_line(Line) of
                {ok, Map} ->
                    try
                        {ok, #{
                            page_id => maps:get(<<"page_id">>, Map),
                            title => maps:get(<<"title">>, Map),
                            pageviews => maps:get(<<"pageviews">>, Map),
                            active_months => maps:get(<<"active_months">>, Map)
                        }}
                    catch
                        error:{badkey, Key} -> {error, {missing_field, Key}}
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {top_file_read_failed, Reason}}
    end.

close_readers(Readers) when is_tuple(Readers) ->
    lists:foreach(
        fun(Index) ->
            try file:close(element(Index, Readers)) of
                _ -> ok
            catch
                _:_ -> ok
            end
        end,
        lists:seq(1, tuple_size(Readers))
    ).

close_reader_list(Fds) ->
    lists:foreach(
        fun(Fd) ->
            try file:close(Fd) of
                _ -> ok
            catch
                _:_ -> ok
            end
        end,
        Fds
    ).

spool_path(Runtime, Month, Partition) ->
    filename:join(
        [maps:get(spool_dir, Runtime), binary_to_list(Month), partition_filename(Partition)]
    ).

top_path(Runtime, Partition) ->
    filename:join(
        maps:get(top_dir, Runtime),
        lists:flatten(io_lib:format("top-~4..0B.jsonl", [Partition]))
    ).

partition_filename(Partition) ->
    lists:flatten(io_lib:format("part-~4..0B.bin", [Partition])).

publish_directory(TmpDir, FinalDir) ->
    _ = remove_tree(FinalDir),
    case file:rename(TmpDir, FinalDir) of
        ok -> ok;
        {error, Reason} -> {error, {spool_publish_failed, TmpDir, FinalDir, Reason}}
    end.

maybe_cleanup_selection_inputs(#{keep_intermediates := true}) ->
    ok;
maybe_cleanup_selection_inputs(Runtime) ->
    %% The merged selection is the durable boundary. Partition spools can be
    %% tens of gigabytes and are no longer required for content extraction or
    %% recovery once selection.jsonl and its metadata are synced.
    _ = remove_tree(maps:get(spool_dir, Runtime)),
    ok.

maybe_delete_download(#{keep_downloads := false}, Path) ->
    _ = file:delete(Path),
    ok;
maybe_delete_download(_Runtime, _Path) ->
    ok.

read_marker(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try jsx:decode(Bytes, [return_maps]) of
                Map when is_map(Map) -> {ok, external_marker_to_internal(Map)};
                _ -> {error, {marker_not_map, Path}}
            catch
                error:Reason -> {error, {invalid_marker, Path, Reason}}
            end;
        {error, enoent} ->
            not_found;
        {error, Reason} ->
            {error, {marker_read_failed, Path, Reason}}
    end.

external_marker_to_internal(Map) ->
    maps:from_list([
        {marker_key(Key), Value}
     || {Key, Value} <- maps:to_list(Map)
    ]).

marker_key(<<"schema">>) -> schema;
marker_key(<<"month">>) -> month;
marker_key(<<"month_index">>) -> month_index;
marker_key(<<"source_url">>) -> source_url;
marker_key(<<"source_name">>) -> source_name;
marker_key(<<"project_rows">>) -> project_rows;
marker_key(<<"skipped_rows">>) -> skipped_rows;
marker_key(<<"malformed_rows">>) -> malformed_rows;
marker_key(<<"total_views">>) -> total_views;
marker_key(<<"partition">>) -> partition;
marker_key(<<"aggregate_records">>) -> aggregate_records;
marker_key(<<"unique_pages">>) -> unique_pages;
marker_key(<<"top_records">>) -> top_records;
marker_key(<<"minimum_active_months">>) -> minimum_active_months;
marker_key(<<"candidate_limit">>) -> candidate_limit;
marker_key(<<"selected">>) -> selected;
marker_key(<<"requested_limit">>) -> requested_limit;
marker_key(<<"sha256">>) -> sha256;
marker_key(<<"path">>) -> path;
marker_key(Other) -> Other.

decode_json_line(Line0) ->
    Line = trim_line(Line0),
    try jsx:decode(Line, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, not_map}
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

trim_line(Bin) when is_binary(Bin) ->
    trim_line(Bin, byte_size(Bin)).

trim_line(_Bin, 0) ->
    <<>>;
trim_line(Bin, Size) ->
    case binary:at(Bin, Size - 1) of
        $\n -> trim_line(Bin, Size - 1);
        $\r -> trim_line(Bin, Size - 1);
        _ -> binary:part(Bin, 0, Size)
    end.

parse_nonnegative(Bin) ->
    try binary_to_integer(Bin) of
        Value when Value >= 0 -> {ok, Value};
        _ -> error
    catch
        error:badarg -> error
    end.

popcount(Value) when Value >= 0 -> popcount(Value, 0).
popcount(0, Count) -> Count;
popcount(Value, Count) -> popcount(Value band (Value - 1), Count + 1).

hash_file(Path) ->
    {ok, Fd} = file:open(Path, [read, raw, binary]),
    try
        hash_file_loop(Fd, crypto:hash_init(sha256))
    after
        ok = file:close(Fd)
    end.

hash_file_loop(Fd, Context) ->
    case file:read(Fd, 1048576) of
        eof -> crypto:hash_final(Context);
        {ok, Bin} -> hash_file_loop(Fd, crypto:hash_update(Context, Bin));
        {error, Reason} -> erlang:error({hash_read_failed, Reason})
    end.

atomic_write(Path, Bytes) ->
    ok = filelib:ensure_dir(Path),
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Bytes),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

sync_file(Path) ->
    case file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            try
                file:sync(Fd)
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _Reason} -> 0
    end.

safe_progress(Fun, Progress) ->
    try Fun(Progress) of
        _ -> ok
    catch
        _:_ -> ok
    end.

bounded_integer(Key, Map, Default, Min, Max) ->
    case maps:get(Key, Map, Default) of
        Value when is_integer(Value), Value >= Min, Value =< Max -> Value;
        _ -> Default
    end.

unique_suffix() ->
    integer_to_list(erlang:unique_integer([positive, monotonic])).

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} ->
            case element(3, Info) of
                directory ->
                    case file:list_dir(Path) of
                        {ok, Names} ->
                            lists:foreach(
                                fun(Name) -> remove_tree(filename:join(Path, Name)) end,
                                Names
                            ),
                            _ = file:del_dir(Path),
                            ok;
                        {error, _Reason} ->
                            ok
                    end;
                _ ->
                    _ = file:delete(Path),
                    ok
            end;
        {error, _Reason} ->
            ok
    end.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) ->
    erlang:error(badarg).
