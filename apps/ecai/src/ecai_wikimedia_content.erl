%%--------------------------------------------------------------------
%% Selected Wikimedia content extraction from CirrusSearch JSON dumps.
%%
%% One compressed shard is downloaded, streamed through bzip2, filtered by the
%% pageview selection table, normalized to the existing Wikipedia loader
%% schema, and atomically published as a small JSONL file. Large compressed
%% inputs are deleted after success unless the operator requests retention.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_content).

-export([
    version/0,
    prepare/4,
    extract_shard/4,
    finalize_ranked/2,
    index_files/1,
    extracted_files/1,
    paths/1,
    normalize_document/4
]).

-define(SCHEMA, <<"ecai-wikimedia-content/v1">>).
-define(DEFAULT_ABSTRACT_BYTES, 16384).
-define(DEFAULT_INDEX_CHUNK_LINES, 5000).

-spec version() -> binary().
version() -> ?SCHEMA.

-spec prepare(file:filename_all(), map(), map(), map()) -> {ok, map()} | {error, term()}.
prepare(WorkDir0, Catalog, SelectorRuntime, Opts) when
    is_map(Catalog), is_map(SelectorRuntime), is_map(Opts)
->
    try
        WorkDir = path_list(WorkDir0),
        DownloadDir = filename:join(WorkDir, "downloads/content"),
        ExtractDir = filename:join(WorkDir, "extracted"),
        IndexDir = filename:join(WorkDir, "index-input"),
        ok = filelib:ensure_dir(filename:join(DownloadDir, "x")),
        ok = filelib:ensure_dir(filename:join(ExtractDir, "x")),
        ok = filelib:ensure_dir(filename:join(IndexDir, "x")),
        {ok, #{
            schema => ?SCHEMA,
            work_dir => WorkDir,
            download_dir => DownloadDir,
            extract_dir => ExtractDir,
            index_dir => IndexDir,
            index_complete_path => filename:join(IndexDir, "COMPLETE.json"),
            project => maps:get(project, Catalog),
            pageview_project => maps:get(pageview_project, Catalog),
            release => maps:get(cirrus_release, Catalog),
            selection_path => maps:get(selection_path, SelectorRuntime),
            limit => maps:get(limit, SelectorRuntime),
            candidate_limit => maps:get(candidate_limit, SelectorRuntime),
            abstract_max_bytes => bounded_integer(
                abstract_max_bytes,
                Opts,
                ?DEFAULT_ABSTRACT_BYTES,
                1024,
                16777216
            ),
            cirrus_max_line_bytes => bounded_integer(
                cirrus_max_line_bytes,
                Opts,
                67108864,
                1048576,
                268435456
            ),
            index_chunk_lines => bounded_integer(
                index_chunk_lines,
                Opts,
                ?DEFAULT_INDEX_CHUNK_LINES,
                100,
                100000
            ),
            keep_downloads => maps:get(keep_downloads, Opts, false),
            keep_intermediates => maps:get(keep_intermediates, Opts, false),
            publish_extracted_ipfs => maps:get(publish_extracted_ipfs, Opts, false)
        }}
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace -> {error, {content_prepare_failed, Class, Reason, Stacktrace}}
    end;
prepare(_WorkDir, _Catalog, _SelectorRuntime, _Opts) ->
    {error, badarg}.

-spec paths(map()) -> map().
paths(Runtime) ->
    maps:with(
        [download_dir, extract_dir, index_dir, index_complete_path, selection_path],
        Runtime
    ).

-spec extract_shard(map(), map(), ets:tid(), fun((map()) -> any())) ->
    {ok, map()} | {error, term()}.
extract_shard(Runtime, Source, SelectionTab, ProgressFun) when
    is_map(Runtime),
    is_map(Source),
    is_function(ProgressFun, 1)
->
    Name = maps:get(name, Source),
    BaseName = strip_suffix(Name, <<".json.bz2">>),
    OutputPath = filename:join(
        maps:get(extract_dir, Runtime),
        binary_to_list(<<BaseName/binary, ".selected.jsonl">>)
    ),
    MarkerPath = OutputPath ++ ".complete.json",
    case read_output_marker(MarkerPath) of
        {ok, Meta} ->
            {ok, Meta#{cached => true}};
        not_found ->
            extract_shard_fresh(
                Runtime,
                Source,
                SelectionTab,
                ProgressFun,
                OutputPath,
                MarkerPath
            );
        {error, _Reason} = Error ->
            Error
    end;
extract_shard(_Runtime, _Source, _SelectionTab, _ProgressFun) ->
    {error, badarg}.

extract_shard_fresh(Runtime, Source, SelectionTab, ProgressFun, OutputPath, MarkerPath) ->
    Name = maps:get(name, Source),
    DownloadPath = filename:join(
        maps:get(download_dir, Runtime),
        binary_to_list(Name)
    ),
    safe_progress(ProgressFun, #{
        phase => downloading_content,
        source => maps:get(url, Source),
        shard => Name
    }),
    case
        ecai_http_stream:download(
            maps:get(url, Source),
            DownloadPath,
            #{progress_fun => ProgressFun}
        )
    of
        {ok, DownloadMeta} ->
            Tmp = OutputPath ++ ".tmp",
            case file:open(Tmp, [write, raw, binary]) of
                {ok, Out} ->
                    Initial = #{
                        out => Out,
                        expecting_source => false,
                        source_lines => 0,
                        action_lines => 0,
                        selected => 0,
                        namespace_skipped => 0,
                        unselected => 0,
                        malformed => 0
                    },
                    ShardRuntime = Runtime#{current_shard => Name},
                    Fold = fun(Line, State) ->
                        process_cirrus_line(
                            Line,
                            State,
                            ShardRuntime,
                            SelectionTab
                        )
                    end,
                    Result =
                        try
                            ecai_bzip2_stream:fold_lines(
                                DownloadPath,
                                Fold,
                                Initial,
                                #{max_line_bytes => maps:get(cirrus_max_line_bytes, Runtime)}
                            )
                        after
                            ok = file:sync(Out),
                            ok = file:close(Out)
                        end,
                    case Result of
                        {ok, State1, StreamStats} ->
                            case file:rename(Tmp, OutputPath) of
                                ok ->
                                    Digest = hash_file(OutputPath),
                                    case maybe_publish_file(Runtime, OutputPath) of
                                        {ok, Cid} ->
                                            Meta = #{
                                                schema => ?SCHEMA,
                                                shard => Name,
                                                source_url => maps:get(url, Source),
                                                output_path => unicode:characters_to_binary(
                                                    OutputPath
                                                ),
                                                output_bytes => file_size(OutputPath),
                                                output_sha256 => ecai_index_job_codec:id_hex(
                                                    Digest
                                                ),
                                                output_cid => Cid,
                                                download => DownloadMeta,
                                                stream => StreamStats,
                                                source_lines => maps:get(source_lines, State1),
                                                action_lines => maps:get(action_lines, State1),
                                                selected => maps:get(selected, State1),
                                                namespace_skipped => maps:get(
                                                    namespace_skipped, State1
                                                ),
                                                unselected => maps:get(unselected, State1),
                                                malformed => maps:get(malformed, State1)
                                            },
                                            case
                                                atomic_write(
                                                    MarkerPath,
                                                    jsx:encode(
                                                        ecai_index_job_codec:externalize(Meta)
                                                    )
                                                )
                                            of
                                                ok ->
                                                    maybe_delete_download(Runtime, DownloadPath),
                                                    safe_progress(ProgressFun, #{
                                                        phase => content_shard_complete,
                                                        shard => Name,
                                                        selected => maps:get(selected, State1)
                                                    }),
                                                    {ok, Meta};
                                                {error, Reason} ->
                                                    {error, {content_marker_write_failed, Reason}}
                                            end;
                                        {error, PublishReason} ->
                                            {error, {content_ipfs_publish_failed, PublishReason}}
                                    end;
                                {error, Reason} ->
                                    {error, {content_output_rename_failed, Reason}}
                            end;
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, {content_decompression_failed, Name, Reason}}
                    end;
                {error, Reason} ->
                    {error, {content_output_open_failed, OutputPath, Reason}}
            end;
        {error, Reason} ->
            {error, {content_download_failed, Name, Reason}}
    end.

process_cirrus_line(<<>>, State, _Runtime, _SelectionTab) ->
    {ok, State};
process_cirrus_line(Line, State0, Runtime, SelectionTab) ->
    case decode_json(Line) of
        {ok, Map0} ->
            case classify_line(Map0, maps:get(expecting_source, State0)) of
                action ->
                    {ok, State0#{
                        expecting_source => true,
                        action_lines => maps:get(action_lines, State0) + 1
                    }};
                {source, SourceMap} ->
                    State1 = State0#{
                        expecting_source => false,
                        source_lines => maps:get(source_lines, State0) + 1
                    },
                    process_source_map(SourceMap, State1, Runtime, SelectionTab);
                ignore ->
                    {ok, State0#{malformed => maps:get(malformed, State0) + 1}}
            end;
        {error, _Reason} ->
            {ok, State0#{
                expecting_source => false,
                malformed => maps:get(malformed, State0) + 1
            }}
    end.

classify_line(Map, _Expecting) when is_map(Map) ->
    case is_bulk_action(Map) of
        true ->
            action;
        false ->
            case maps:get(<<"_source">>, Map, undefined) of
                Source when is_map(Source) -> {source, Source};
                _ -> {source, Map}
            end
    end.

is_bulk_action(Map) ->
    maps:is_key(<<"index">>, Map) orelse
        maps:is_key(<<"create">>, Map) orelse
        maps:is_key(<<"update">>, Map) orelse
        maps:is_key(<<"delete">>, Map).

process_source_map(Source, State0, Runtime, SelectionTab) ->
    PageId = first_integer(Source, [<<"page_id">>, <<"pageid">>, <<"id">>]),
    Title = first_binary(Source, [<<"title">>, <<"name">>], <<>>),
    Namespace = first_integer(Source, [<<"namespace">>, <<"namespace_id">>, <<"ns">>]),
    case Namespace of
        Value when Value =/= undefined, Value =/= 0 ->
            {ok, State0#{namespace_skipped => maps:get(namespace_skipped, State0) + 1}};
        _ ->
            case ecai_wikimedia_selector:lookup(SelectionTab, PageId, pageview_title(Title)) of
                {ok, Visibility} ->
                    case normalize_document(Source, Visibility, Runtime, Title) of
                        {ok, Document} ->
                            Out = maps:get(out, State0),
                            Line = jsx:encode(Document),
                            case file:write(Out, <<Line/binary, "\n">>) of
                                ok ->
                                    {ok, State0#{selected => maps:get(selected, State0) + 1}};
                                {error, Reason} ->
                                    {error, {content_output_write_failed, Reason}}
                            end;
                        {error, _Reason} ->
                            {ok, State0#{malformed => maps:get(malformed, State0) + 1}}
                    end;
                not_found ->
                    {ok, State0#{unselected => maps:get(unselected, State0) + 1}}
            end
    end.

-spec normalize_document(map(), map(), map(), binary()) -> {ok, map()} | {error, term()}.
normalize_document(Source, Visibility, Runtime, Title0) ->
    try
        Title =
            case Title0 of
                <<>> -> maps:get(title, Visibility);
                _ -> Title0
            end,
        PageId =
            case first_integer(Source, [<<"page_id">>, <<"pageid">>, <<"id">>]) of
                undefined -> maps:get(page_id, Visibility);
                Value -> Value
            end,
        Abstract0 = first_text(
            Source,
            [
                <<"opening_text">>,
                <<"description">>,
                <<"text">>,
                <<"auxiliary_text">>,
                <<"source_text">>
            ]
        ),
        Abstract = utf8_prefix(Abstract0, maps:get(abstract_max_bytes, Runtime)),
        Wikidata = first_binary(
            Source,
            [<<"wikibase_item">>, <<"wikidata_id">>, <<"wikidata">>],
            <<>>
        ),
        Categories = string_list(first_value(Source, [<<"category">>, <<"categories">>], [])),
        Redirects = redirect_titles(first_value(Source, [<<"redirect">>, <<"redirects">>], [])),
        Url = canonical_url(Runtime, Source, Title),
        DateModified = first_binary(
            Source,
            [<<"timestamp">>, <<"date_modified">>, <<"last_updated">>],
            <<>>
        ),
        {ok, #{
            <<"name">> => Title,
            <<"url">> => Url,
            <<"identifier">> => PageId,
            <<"abstract">> => Abstract,
            <<"in_language">> => #{
                <<"identifier">> => language_code(maps:get(project, Runtime))
            },
            <<"main_entity">> => #{<<"identifier">> => Wikidata},
            <<"date_modified">> => DateModified,
            <<"license">> => [
                #{
                    <<"identifier">> => <<"CC-BY-SA">>,
                    <<"name">> => <<"Creative Commons Attribution-ShareAlike">>,
                    <<"url">> => <<"https://creativecommons.org/licenses/by-sa/4.0/">>
                }
            ],
            <<"categories">> => Categories,
            <<"redirects">> => Redirects,
            <<"visibility">> => #{
                <<"rank">> => maps:get(rank, Visibility),
                <<"pageviews">> => maps:get(pageviews, Visibility),
                <<"active_months">> => maps:get(active_months, Visibility)
            },
            <<"ecai_source">> => #{
                <<"schema">> => ?SCHEMA,
                <<"project">> => maps:get(project, Runtime),
                <<"release">> => maps:get(release, Runtime),
                <<"page_id">> => PageId,
                <<"shard">> => maps:get(current_shard, Runtime, <<>>),
                <<"revision_id">> => first_integer(
                    Source,
                    [<<"revision_id">>, <<"rev_id">>, <<"rev_id_num">>]
                )
            }
        }}
    catch
        Class:Reason -> {error, {normalize_failed, Class, Reason}}
    end.

-spec finalize_ranked(map(), fun((map()) -> any())) -> {ok, map()} | {error, term()}.
finalize_ranked(Runtime, ProgressFun) when is_map(Runtime), is_function(ProgressFun, 1) ->
    MarkerPath = maps:get(index_complete_path, Runtime),
    case read_output_marker(MarkerPath) of
        {ok, Meta} ->
            maybe_cleanup_extracted(Runtime),
            {ok, Meta#{cached => true}};
        not_found ->
            finalize_ranked_fresh(Runtime, ProgressFun, MarkerPath);
        {error, _Reason} = Error ->
            Error
    end;
finalize_ranked(_Runtime, _ProgressFun) ->
    {error, badarg}.

finalize_ranked_fresh(Runtime, ProgressFun, MarkerPath) ->
    safe_progress(ProgressFun, #{phase => finalizing_visibility_selection}),
    Extracted = extracted_files(Runtime),
    case collect_valid_ranks(Extracted, gb_sets:empty(), 0) of
        {ok, RankSet, RecordCount} ->
            OrderedRanks = gb_sets:to_list(RankSet),
            Requested = maps:get(limit, Runtime),
            ChosenRanks = lists:sublist(OrderedRanks, Requested),
            ChosenSet = gb_sets:from_list(ChosenRanks),
            TmpDir = maps:get(index_dir, Runtime) ++ ".tmp-" ++ unique_suffix(),
            _ = remove_tree(TmpDir),
            ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
            Writer0 = new_ranked_writer(TmpDir, maps:get(index_chunk_lines, Runtime)),
            case write_chosen_records(Extracted, ChosenSet, Writer0) of
                {ok, Writer1} ->
                    case close_ranked_writer(Writer1) of
                        {ok, Files, SelectedCount} ->
                            Meta0 = #{
                                schema => ?SCHEMA,
                                candidate_records_found => RecordCount,
                                requested_records => Requested,
                                selected_records => SelectedCount,
                                highest_included_rank => last_or_zero(ChosenRanks),
                                index_files => [
                                    unicode:characters_to_binary(Path)
                                 || Path <- Files
                                ]
                            },
                            case
                                atomic_write(
                                    filename:join(TmpDir, "COMPLETE.json"),
                                    jsx:encode(ecai_index_job_codec:externalize(Meta0))
                                )
                            of
                                ok ->
                                    case publish_directory(TmpDir, maps:get(index_dir, Runtime)) of
                                        ok ->
                                            Meta = Meta0#{
                                                index_files => index_files(Runtime)
                                            },
                                            safe_progress(ProgressFun, #{
                                                phase => visibility_selection_complete,
                                                selected_records => SelectedCount
                                            }),
                                            maybe_cleanup_extracted(Runtime),
                                            {ok, Meta};
                                        {error, _Reason} = Error ->
                                            Error
                                    end;
                                {error, Reason} ->
                                    {error, {index_complete_write_failed, Reason}}
                            end;
                        {error, _Reason} = Error ->
                            Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec index_files(map()) -> [binary()].
index_files(Runtime) ->
    Dir = maps:get(index_dir, Runtime),
    case file:list_dir(Dir) of
        {ok, Names} ->
            [
                unicode:characters_to_binary(filename:join(Dir, Name))
             || Name <- lists:sort(Names),
                lists:prefix("index-", Name),
                filename:extension(Name) =:= ".jsonl"
            ];
        {error, _Reason} ->
            []
    end.

-spec extracted_files(map()) -> [file:filename_all()].
extracted_files(Runtime) ->
    Dir = maps:get(extract_dir, Runtime),
    case file:list_dir(Dir) of
        {ok, Names} ->
            [
                filename:join(Dir, Name)
             || Name <- lists:sort(Names),
                lists:suffix(".selected.jsonl", Name)
            ];
        {error, _Reason} ->
            []
    end.

collect_valid_ranks([], Set, Count) ->
    {ok, Set, Count};
collect_valid_ranks([Path | Rest], Set0, Count0) ->
    case
        fold_jsonl(
            Path,
            fun(Map, {Set, Count}) ->
                Rank = visibility_integer(Map, <<"rank">>, 0),
                case Rank > 0 of
                    true -> {ok, {gb_sets:add(Rank, Set), Count + 1}};
                    false -> {ok, {Set, Count}}
                end
            end,
            {Set0, Count0}
        )
    of
        {ok, {Set1, Count1}} -> collect_valid_ranks(Rest, Set1, Count1);
        {error, _Reason} = Error -> Error
    end.

write_chosen_records([], _ChosenSet, Writer) ->
    {ok, Writer};
write_chosen_records([Path | Rest], ChosenSet, Writer0) ->
    case
        fold_jsonl(
            Path,
            fun(Map, Writer) ->
                Rank = visibility_integer(Map, <<"rank">>, 0),
                case gb_sets:is_member(Rank, ChosenSet) of
                    true -> ranked_writer_write(Writer, Rank, jsx:encode(Map));
                    false -> {ok, Writer}
                end
            end,
            Writer0
        )
    of
        {ok, Writer1} -> write_chosen_records(Rest, ChosenSet, Writer1);
        {error, _Reason} = Error -> Error
    end.

new_ranked_writer(Dir, ChunkLines) ->
    #{
        dir => Dir,
        chunk_lines => ChunkLines,
        chunk_index => 0,
        current_fd => undefined,
        current_tmp => undefined,
        current_final => undefined,
        current_lines => 0,
        total_lines => 0,
        files => [],
        seen_ranks => ets:new(ecai_wikimedia_ranked_seen, [set, private])
    }.

ranked_writer_write(Writer0, Rank, Line) ->
    Seen = maps:get(seen_ranks, Writer0),
    case ets:insert_new(Seen, {Rank}) of
        false -> {ok, Writer0};
        true -> ranked_writer_write_unique(Writer0, Line)
    end.

ranked_writer_write_unique(Writer0, Line) ->
    case ensure_ranked_writer_open(Writer0) of
        {ok, Writer1} ->
            Fd = maps:get(current_fd, Writer1),
            case file:write(Fd, <<Line/binary, "\n">>) of
                ok ->
                    Writer2 = Writer1#{
                        current_lines => maps:get(current_lines, Writer1) + 1,
                        total_lines => maps:get(total_lines, Writer1) + 1
                    },
                    case maps:get(current_lines, Writer2) >= maps:get(chunk_lines, Writer2) of
                        true -> close_current_ranked_file(Writer2);
                        false -> {ok, Writer2}
                    end;
                {error, Reason} ->
                    {error, {index_input_write_failed, Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

ensure_ranked_writer_open(#{current_fd := Fd} = Writer) when Fd =/= undefined ->
    {ok, Writer};
ensure_ranked_writer_open(Writer0) ->
    Index = maps:get(chunk_index, Writer0),
    Name = lists:flatten(io_lib:format("index-~6..0B.jsonl", [Index])),
    Final = filename:join(maps:get(dir, Writer0), Name),
    Tmp = Final ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            {ok, Writer0#{
                current_fd => Fd,
                current_tmp => Tmp,
                current_final => Final,
                current_lines => 0
            }};
        {error, Reason} ->
            {error, {index_input_open_failed, Final, Reason}}
    end.

close_current_ranked_file(#{current_fd := undefined} = Writer) ->
    {ok, Writer};
close_current_ranked_file(Writer0) ->
    Fd = maps:get(current_fd, Writer0),
    Tmp = maps:get(current_tmp, Writer0),
    Final = maps:get(current_final, Writer0),
    Result =
        try
            file:sync(Fd)
        after
            ok = file:close(Fd)
        end,
    case Result of
        ok ->
            case file:rename(Tmp, Final) of
                ok ->
                    {ok, Writer0#{
                        chunk_index => maps:get(chunk_index, Writer0) + 1,
                        current_fd => undefined,
                        current_tmp => undefined,
                        current_final => undefined,
                        current_lines => 0,
                        files => [Final | maps:get(files, Writer0)]
                    }};
                {error, Reason} ->
                    {error, {index_input_rename_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {index_input_sync_failed, Reason}}
    end.

close_ranked_writer(Writer0) ->
    Seen = maps:get(seen_ranks, Writer0, undefined),
    Result =
        case close_current_ranked_file(Writer0) of
            {ok, Writer1} ->
                {ok, lists:reverse(maps:get(files, Writer1)), maps:get(total_lines, Writer1)};
            {error, _Reason} = Error ->
                Error
        end,
    case Seen of
        undefined ->
            ok;
        _ ->
            _ = ets:delete(Seen),
            ok
    end,
    Result.

fold_jsonl(Path, Fun, Acc0) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                fold_jsonl_loop(Fd, Path, Fun, Acc0, 1)
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, {jsonl_open_failed, Path, Reason}}
    end.

fold_jsonl_loop(Fd, Path, Fun, Acc0, LineNo) ->
    case file:read_line(Fd) of
        eof ->
            {ok, Acc0};
        {ok, Line} ->
            case decode_json(Line) of
                {ok, Map} ->
                    case Fun(Map, Acc0) of
                        {ok, Acc1} -> fold_jsonl_loop(Fd, Path, Fun, Acc1, LineNo + 1);
                        {error, _Reason} = Error -> Error;
                        Other -> {error, {invalid_jsonl_fold_return, Other}}
                    end;
                {error, Reason} ->
                    {error, {invalid_jsonl_line, Path, LineNo, Reason}}
            end;
        {error, Reason} ->
            {error, {jsonl_read_failed, Path, Reason}}
    end.

visibility_integer(Map, Key, Default) ->
    case maps:get(<<"visibility">>, Map, undefined) of
        Visibility when is_map(Visibility) ->
            case maps:get(Key, Visibility, Default) of
                Value when is_integer(Value) -> Value;
                _ -> Default
            end;
        _ ->
            Default
    end.

first_integer(Map, Keys) ->
    case first_value(Map, Keys, undefined) of
        Value when is_integer(Value) -> Value;
        Bin when is_binary(Bin) ->
            try
                binary_to_integer(Bin)
            catch
                error:badarg -> undefined
            end;
        _ ->
            undefined
    end.

first_binary(Map, Keys, Default) ->
    case first_value(Map, Keys, Default) of
        Bin when is_binary(Bin) -> Bin;
        List when is_list(List) ->
            case is_string_list(List) of
                true -> unicode:characters_to_binary(List);
                false -> Default
            end;
        Value when is_integer(Value) -> integer_to_binary(Value);
        _ ->
            Default
    end.

first_text(Map, Keys) ->
    first_nonempty_text(Map, Keys).

first_nonempty_text(_Map, []) ->
    <<>>;
first_nonempty_text(Map, [Key | Rest]) ->
    case maps:find(Key, Map) of
        {ok, Value} when Value =/= null ->
            case text_value(Value) of
                <<>> -> first_nonempty_text(Map, Rest);
                Text -> Text
            end;
        _ ->
            first_nonempty_text(Map, Rest)
    end.

first_value(_Map, [], Default) ->
    Default;
first_value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Value} when Value =/= null -> Value;
        _ -> first_value(Map, Rest, Default)
    end.

text_value(Bin) when is_binary(Bin) -> Bin;
text_value(List) when is_list(List) ->
    case is_string_list(List) of
        true ->
            unicode:characters_to_binary(List);
        false ->
            iolist_to_binary(
                lists:join(<<"\n">>, [text_value(Item) || Item <- List])
            )
    end;
text_value(Map) when is_map(Map) ->
    first_text(Map, [<<"plain">>, <<"text">>, <<"value">>]);
text_value(Value) when is_integer(Value); is_float(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value]));
text_value(_Other) ->
    <<>>.

string_list(List) when is_list(List) ->
    lists:usort([
        text_value(Item)
     || Item <- List,
        byte_size(text_value(Item)) > 0
    ]);
string_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> [Bin];
string_list(_Other) ->
    [].

redirect_titles(List) when is_list(List) ->
    lists:usort([
        case Item of
            Map when is_map(Map) -> first_binary(Map, [<<"title">>, <<"name">>], <<>>);
            _ -> text_value(Item)
        end
     || Item <- List,
        redirect_nonempty(Item)
    ]);
redirect_titles(_Other) ->
    [].

redirect_nonempty(Map) when is_map(Map) ->
    first_binary(Map, [<<"title">>, <<"name">>], <<>>) =/= <<>>;
redirect_nonempty(Value) ->
    text_value(Value) =/= <<>>.

canonical_url(Runtime, Source, Title) ->
    case first_binary(Source, [<<"url">>, <<"canonical_url">>], <<>>) of
        <<>> ->
            Project = maps:get(pageview_project, Runtime),
            EncodedTitle = url_title(Title),
            <<"https://", Project/binary, "/wiki/", EncodedTitle/binary>>;
        Url ->
            Url
    end.

url_title(Title0) ->
    Title = binary:replace(Title0, <<" ">>, <<"_">>, [global]),
    try uri_string:quote(Title) of
        Bin when is_binary(Bin) -> Bin;
        List when is_list(List) -> unicode:characters_to_binary(List)
    catch
        _:_ -> Title
    end.

pageview_title(Title) ->
    binary:replace(Title, <<" ">>, <<"_">>, [global]).

language_code(Project) ->
    case binary:split(Project, <<"wiki">>) of
        [Lang, <<>>] when byte_size(Lang) > 0 -> Lang;
        _ -> Project
    end.

utf8_prefix(Bin0, MaxBytes) ->
    Bin =
        case ecai_chunker:validate_utf8(Bin0) of
            ok -> Bin0;
            {error, _Reason} -> <<>>
        end,
    case byte_size(Bin) =< MaxBytes of
        true -> Bin;
        false -> utf8_prefix_shrink(Bin, MaxBytes)
    end.

utf8_prefix_shrink(Bin, Size) when Size =< 0 -> <<>>;
utf8_prefix_shrink(Bin, Size) ->
    Prefix = binary:part(Bin, 0, Size),
    case ecai_chunker:validate_utf8(Prefix) of
        ok -> Prefix;
        {error, _Reason} -> utf8_prefix_shrink(Bin, Size - 1)
    end.

maybe_publish_file(#{publish_extracted_ipfs := false}, _Path) ->
    {ok, null};
maybe_publish_file(_Runtime, Path) ->
    normalize_add_response(damage_ipfs:add({file, Path})).

maybe_cleanup_extracted(#{keep_intermediates := true}) ->
    ok;
maybe_cleanup_extracted(Runtime) ->
    %% Exact top-N index input is now durable. Remove the oversampled extracted
    %% shard files so a completed job retains only the material needed for
    %% search replay and the NFT artifact.
    _ = remove_tree(maps:get(extract_dir, Runtime)),
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

read_output_marker(Path) ->
    case read_marker(Path) of
        {ok, Meta} ->
            case validate_output_marker(Meta) of
                ok -> {ok, Meta};
                {error, stale_marker} -> not_found;
                {error, incomplete_marker} -> not_found;
                {error, Reason} -> {error, {output_marker_invalid, Path, Reason}}
            end;
        Other -> Other
    end.

validate_output_marker(Meta) ->
    case
        {
            maps:get(output_path, Meta, undefined),
            maps:get(output_bytes, Meta, undefined),
            maps:get(output_sha256, Meta, undefined)
        }
    of
        {Path0, Bytes, Sha} when
            (is_binary(Path0) orelse is_list(Path0)), is_integer(Bytes), is_binary(Sha)
        ->
            Path = path_list(Path0),
            case filelib:is_regular(Path) andalso file_size(Path) =:= Bytes of
                false ->
                    {error, stale_marker};
                true ->
                    Digest = hash_file(Path),
                    case ecai_index_job_codec:id_hex(Digest) =:= Sha of
                        true -> ok;
                        false -> {error, stale_marker}
                    end
            end;
        _ ->
            {error, incomplete_marker}
    end.

external_marker_to_internal(Map) ->
    maps:from_list([{marker_key(K), V} || {K, V} <- maps:to_list(Map)]).

marker_key(<<"schema">>) -> schema;
marker_key(<<"shard">>) -> shard;
marker_key(<<"output_path">>) -> output_path;
marker_key(<<"output_bytes">>) -> output_bytes;
marker_key(<<"output_sha256">>) -> output_sha256;
marker_key(<<"output_cid">>) -> output_cid;
marker_key(<<"selected">>) -> selected;
marker_key(<<"namespace_skipped">>) -> namespace_skipped;
marker_key(<<"unselected">>) -> unselected;
marker_key(<<"malformed">>) -> malformed;
marker_key(<<"candidate_records_found">>) -> candidate_records_found;
marker_key(<<"requested_records">>) -> requested_records;
marker_key(<<"selected_records">>) -> selected_records;
marker_key(<<"highest_included_rank">>) -> highest_included_rank;
marker_key(<<"index_files">>) -> index_files;
marker_key(Other) -> Other.

decode_json(Line0) ->
    Line = trim_line_end(Line0),
    try jsx:decode(Line, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, not_map}
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

%% OTP compatibility: avoid binary:trim/3 and remove only line-ending bytes.
trim_line_end(Bin) when is_binary(Bin) ->
    trim_line_end(Bin, byte_size(Bin)).

trim_line_end(_Bin, 0) ->
    <<>>;
trim_line_end(Bin, Size) ->
    case binary:at(Bin, Size - 1) of
        $\n -> trim_line_end(Bin, Size - 1);
        $\r -> trim_line_end(Bin, Size - 1);
        _ -> binary:part(Bin, 0, Size)
    end.

strip_suffix(Bin, Suffix) ->
    BinSize = byte_size(Bin),
    SuffixSize = byte_size(Suffix),
    case
        BinSize >= SuffixSize andalso
            binary:part(Bin, BinSize - SuffixSize, SuffixSize) =:= Suffix
    of
        true -> binary:part(Bin, 0, BinSize - SuffixSize);
        false -> Bin
    end.

is_string_list([]) ->
    true;
is_string_list([H | T]) when is_integer(H), H >= 0, H =< 16#10FFFF ->
    is_string_list(T);
is_string_list(_Other) ->
    false.

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

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _Reason} -> 0
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

publish_directory(TmpDir, FinalDir) ->
    _ = remove_tree(FinalDir),
    case file:rename(TmpDir, FinalDir) of
        ok -> ok;
        {error, Reason} -> {error, {index_input_publish_failed, Reason}}
    end.

last_or_zero([]) -> 0;
last_or_zero(List) -> lists:last(List).

normalize_add_response({ok, Value}) ->
    normalize_add_response(Value);
normalize_add_response([Value]) ->
    normalize_add_response(Value);
normalize_add_response(#{hash := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"Hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> {ok, Bin};
normalize_add_response(List) when is_list(List), List =/= [] ->
    try unicode:characters_to_binary(string:trim(List)) of
        <<>> -> {error, empty_cid};
        Bin -> {ok, Bin}
    catch
        _:_ -> {error, invalid_cid}
    end;
normalize_add_response({error, _Reason} = Error) ->
    Error;
normalize_add_response(Other) ->
    {error, {invalid_ipfs_add_response, Other}}.

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

unique_suffix() -> integer_to_list(erlang:unique_integer([positive, monotonic])).

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
