%%%-------------------------------------------------------------------
%%% Compatibility facade for callers that adopted ecai_utf8_chunker.
%%%
%%% The implementation now lives in ecai_chunker so Yelp job chunking,
%%% Wikipedia/Yelp line chunking and deterministic UTF-8 windows share one
%%% module and one version contract.
%%%-------------------------------------------------------------------
-module(ecai_utf8_chunker).

-export([
    version/0,
    validate_utf8/1,
    chunk_utf8/3,
    fold_utf8/5
]).

-export_type([chunk/0]).

-type chunk() :: ecai_chunker:chunk().

-spec version() -> binary().
version() ->
    ecai_chunker:version().

-spec validate_utf8(binary()) -> ok | {error, {invalid_utf8, non_neg_integer()}}.
validate_utf8(Bin) ->
    ecai_chunker:validate_utf8(Bin).

-spec chunk_utf8(binary(), pos_integer(), non_neg_integer()) ->
    {ok, [chunk()]} | {error, term()}.
chunk_utf8(Bin, Size, Overlap) ->
    ecai_chunker:chunk_utf8(Bin, Size, Overlap).

-spec fold_utf8(
    binary(),
    pos_integer(),
    non_neg_integer(),
    fun((chunk(), term()) -> {ok, term()} | {error, term()}),
    term()
) -> {ok, term()} | {error, term()}.
fold_utf8(Bin, Size, Overlap, Fun, Acc0) ->
    ecai_chunker:fold_utf8(Bin, Size, Overlap, Fun, Acc0).
