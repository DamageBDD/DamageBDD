%%%===================================================================
%%% ecai_wikipedia_chunker.erl  --  line-based chunking for huge JSONL
%%%===================================================================
-module(ecai_wikipedia_chunker).

-export([
    make_chunks_ndjson/3
]).
-import(damage_utils, [ensure_dir/1]).

-include_lib("kernel/include/logger.hrl").

%% A chunk description we return to the caller:
%% #{
%%    path        := binary(),        %% chunk file path
%%    index       := non_neg_integer(), %% 0-based chunk index
%%    start_line  := pos_integer(),   %% first line number in source (1-based)
%%    line_count  := non_neg_integer(), %% number of lines in this chunk
%%    chunk_id    := binary()         %% sha256({SrcPath,Start,Count}) hex
%% }

-spec make_chunks_ndjson(binary() | list(), binary() | list(), pos_integer()) ->
    [map()].
make_chunks_ndjson(InPath0, OutDir0, K)
  when (is_binary(InPath0) orelse is_list(InPath0)),
       (is_binary(OutDir0) orelse is_list(OutDir0)),
       is_integer(K),
       K > 0 ->
    InPath = to_list(InPath0),
    OutDir = to_list(OutDir0),
    ok = ensure_dir(OutDir),
    case file:open(InPath, [read]) of
        {ok, InIo} ->
            try
                loop_split(InIo, InPath, OutDir, K,
                           1,          %% global line number
                           0,          %% lines in current chunk
                           undefined,  %% current chunk file IoDevice or undefined
                           undefined,  %% current chunk index or undefined
                           [],         %% accumulator of chunk maps
                           0)          %% next chunk index to allocate
            after
                file:close(InIo)
            end;
        {error, Reason} ->
            ?LOG_ERROR("ecai_wiki_chunker: cannot open ~s: ~p", [InPath, Reason]),
            erlang:error({cannot_open, InPath, Reason})
    end.

%%%-------------------------------------------------------------------
%%% Internal
%%%-------------------------------------------------------------------

loop_split(InIo, SrcPath, OutDir, K,
           LineNo, CurCount, CurIo, CurIdx, Acc, NextIdx) ->
    case io:get_line(InIo, '') of
        eof ->
            %% finalize last chunk if there was one
            Acc1 =
                case CurIo of
                    undefined ->
                        Acc;
                    _ ->
                        ok = file:close(CurIo),
                        Chunk = make_chunk_meta(SrcPath, OutDir, CurIdx,
                                                LineNo - CurCount, CurCount),
                        [Chunk | Acc]
                end,
            lists:reverse(Acc1);

        {error, Reason} ->
            ?LOG_ERROR("ecai_wiki_chunker: read error ~p", [Reason]),
            erlang:error({read_error, Reason});

        Line ->
            {CurIo1, CurIdx1, NextIdx1, StartLine, CurCount1, Acc1} =
                maybe_start_chunk(CurIo, CurIdx, NextIdx,
                                  SrcPath, OutDir, LineNo, CurCount, Acc),
            ok = file:write(CurIo1, Line),
            CurCount2 = CurCount1 + 1,
            LineNo1   = LineNo + 1,
            %% if we hit K, close chunk and record metadata
            case CurCount2 >= K of
                true ->
                    ok = file:close(CurIo1),
                    Chunk = make_chunk_meta(SrcPath, OutDir, CurIdx1,
                                            StartLine, CurCount2),
                    loop_split(
                      InIo, SrcPath, OutDir, K,
                      LineNo1, 0, undefined, undefined,
                      [Chunk | Acc1], NextIdx1
                    );
                false ->
                    loop_split(
                      InIo, SrcPath, OutDir, K,
                      LineNo1, CurCount2, CurIo1, CurIdx1,
                      Acc1, NextIdx1
                    )
            end
    end.

%% Start a new chunk if we don't have one yet
maybe_start_chunk(undefined, _CurIdx, NextIdx, _SrcPath, OutDir, LineNo, _CurCount, Acc) ->
    FileName = chunk_filename(OutDir, NextIdx),
    case file:open(FileName, [write]) of
        {ok, Io} ->
            {Io, NextIdx, NextIdx + 1, LineNo, 0, Acc};
        {error, Reason} ->
            ?LOG_ERROR("ecai_wiki_chunker: cannot open chunk ~s: ~p", [FileName, Reason]),
            erlang:error({cannot_open_chunk, FileName, Reason})
    end;
maybe_start_chunk(CurIo, CurIdx, NextIdx, _SrcPath, _OutDir, LineNo, CurCount, Acc) ->
    %% Already have an open chunk, reuse it
    {CurIo, CurIdx, NextIdx, LineNo - CurCount, CurCount, Acc}.

chunk_filename(OutDir, Index) ->
    %% zero-padded index
    S = io_lib:format("wiki_chunk_~6.10.0B.jsonl", [Index]),
    filename:join(OutDir, lists:flatten(S)).

make_chunk_meta(SrcPath, OutDir, Index, StartLine, LineCount) ->
    Path = list_to_binary(chunk_filename(OutDir, Index)),
    Id = chunk_id(SrcPath, StartLine, LineCount),
    #{
        path => Path,
        index => Index,
        start_line => StartLine,
        line_count => LineCount,
        chunk_id => Id
    }.

chunk_id(SrcPath, StartLine, LineCount) ->
    Bin = term_to_binary({SrcPath, StartLine, LineCount}),
    crypto:hash(sha256, Bin).


to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L)   -> L.
