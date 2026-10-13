%%%===================================================================
%%% ecai_wikipedia_chunker.erl
%%%
%%% Compatibility facade for the historical Wikipedia JSONL chunker.
%%% The shared implementation now lives in ecai_chunker.
%%%===================================================================
-module(ecai_wikipedia_chunker).

-export([
    make_chunks_ndjson/3
]).

-spec make_chunks_ndjson(binary() | list(), binary() | list(), pos_integer()) ->
    [ecai_chunker:line_chunk()].
make_chunks_ndjson(InPath, OutDir, LinesPerChunk) ->
    ecai_chunker:make_chunks_ndjson(
        wikipedia,
        InPath,
        OutDir,
        LinesPerChunk
    ).
