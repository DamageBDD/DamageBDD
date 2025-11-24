%%%-------------------------------------------------------------------
%%% ecai_yelp_loader.erl — NDJSON Yelp loader using ecai_tokenizer
%%%-------------------------------------------------------------------
-module(ecai_yelp_loader).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(warn_export_all).

-include_lib("kernel/include/logger.hrl").

%% Public API
-export([
    % (InputNdjsonPath, OutDir, ChunkSize) -> [ChunkPaths]
    make_chunks_ndjson/3,
    % ([ChunkPath]) -> [{ChunkPath,CID}]
    ipfs_add_chunks/1,
    % ([ChunkPath], ClusterId, ClusterSize) -> [ChunkPath]
    assign_chunks/3,
    % (Ctx, [ChunkPath], LimitPerChunk|infinity) -> ok
    index_chunks/3,
    % (Ctx) -> [#{tag:=Bin, root:=Hex, df:=Int}]
    extract_headers/1,
    % ([{ChunkPath,CID}], Headers) -> #{cids:=..., merkle_root:=<<>>, headers:=Headers}
    build_manifest/2,
    % ([CIDBin]) -> <<32 bytes>>
    manifest_root/1
]).
-import(damage_utils, [ensure_dir/1]).

%%%===================================================================
%%% 1) CHUNK NDJSON (streaming, memory-safe)
%%%===================================================================

-spec make_chunks_ndjson(file:filename_all(), file:filename_all(), pos_integer()) -> [binary()].
make_chunks_ndjson(InPath, OutDir, ChunkSize) when ChunkSize > 0 ->
    ok = ensure_dir(OutDir),
    ?LOG_DEBUG("Yelp in ~p", [InPath]),
    {ok, Fd} = file:open(InPath, [read, raw, binary]),
    Paths = chunk_loop(Fd, OutDir, ChunkSize, 1, 0, []),
    ok = file:close(Fd),
    ?LOG_INFO("Wrote ~p chunks to ~ts~n", [length(Paths), OutDir]),
    Paths.

chunk_loop(Fd, OutDir, K, ChunkIdx, CountInChunk, AccPaths) ->
    case file:read_line(Fd) of
        eof ->
            %% finish last partial chunk file if any lines were written already
            finalize_open_chunk(OutDir, ChunkIdx, CountInChunk, AccPaths);
        {ok, Line} ->
            case CountInChunk of
                0 ->
                    Path = chunk_path(OutDir, ChunkIdx),
                    {ok, W} = file:open(Path, [write, raw, binary]),
                    ok = file:write(W, Line),
                    ok = file:close(W),
                    chunk_loop(Fd, OutDir, K, ChunkIdx, 1, [Path | AccPaths]);
                N when N < K ->
                    Path = chunk_path(OutDir, ChunkIdx),
                    ok = file:write_file(Path, Line, [append]),
                    chunk_loop(Fd, OutDir, K, ChunkIdx, N + 1, AccPaths);
                _N when _N >= K ->
                    %% complete current, start new with this line
                    NextIdx = ChunkIdx + 1,
                    Path2 = chunk_path(OutDir, NextIdx),
                    {ok, W2} = file:open(Path2, [write, raw, binary]),
                    ok = file:write(W2, Line),
                    ok = file:close(W2),
                    chunk_loop(Fd, OutDir, K, NextIdx, 1, [Path2 | AccPaths])
            end
    end.

finalize_open_chunk(_OutDir, _Idx, 0, AccPaths) ->
    lists:reverse([iolist_to_binary(P) || P <- AccPaths]);
finalize_open_chunk(_OutDir, _Idx, _N, AccPaths) ->
    lists:reverse([iolist_to_binary(P) || P <- AccPaths]).

chunk_path(OutDir, Idx) ->
    filename:join(OutDir, iolist_to_binary(io_lib:format("chunk_~6..0B.ndjson", [Idx]))).

%%%===================================================================
%%% 2) IPFS: add chunks → CIDs
%%%===================================================================

-spec ipfs_add_chunks([binary() | list()]) -> [{binary(), binary()}].
ipfs_add_chunks(Paths) ->
    [{to_bin(P), ipfs_add(to_bin(P))} || P <- Paths].

ipfs_add(Path) ->
    %% CIDv1, quiet output
    Cmd = io_lib:format("ipfs add -Q --cid-version=1 --raw-leaves ~ts", [Path]),
    CID = string:trim(os:cmd(lists:flatten(Cmd))),
    to_bin(CID).

%%%===================================================================
%%% 3) SHARDING: deterministic assignment by path hash (or CID later)
%%%===================================================================

-spec assign_chunks([binary()], non_neg_integer(), pos_integer()) -> [binary()].
assign_chunks(ChunkPaths, ClusterId, ClusterSize) when
    ClusterSize > 0
->
    [P || P <- ChunkPaths, (erlang:phash2(P) rem ClusterSize) =:= ClusterId].

%%%===================================================================
%%% 4) INDEX chunks into ecai_search (streaming)
%%%===================================================================

-spec index_chunks(term(), [binary()], pos_integer() | infinity) -> ok.
index_chunks(Ctx, ChunkPaths, LimitPerChunk) ->
    [index_one(Ctx, to_bin(P), LimitPerChunk) || P <- ChunkPaths],
    ok.

index_one(Ctx, Path, Limit) ->
    {ok, Fd} = file:open(Path, [read, raw, binary]),
    Lim =
        case Limit of
            infinity -> infinity;
            N when is_integer(N), N > 0 -> N
        end,
    ?LOG_INFO("Indexing ~ts (~p limit)~n", [Path, Lim]),
    ok = index_lines(Ctx, Fd, Lim, 0),
    ok = file:close(Fd),
    ok.

index_lines(_Ctx, _Fd, N, Cnt) when N =/= infinity, Cnt >= N -> ok;
index_lines(Ctx, Fd, N, Cnt) ->
    case file:read_line(Fd) of
        eof ->
            ok;
        {ok, Line} ->
            %% Each line is one business JSON object
            case safe_decode(Line) of
                {ok, Map} ->
                    case yelp_to_record(Map) of
                        skip ->
                            ok;
                        {business, DocId, Rec} ->
                            case ecai_search:add_record(Ctx, DocId, Rec) of
                                ok -> ok;
                                %% idempotent
                                {error, exists} -> ok
                            end;
                        {review, DocId,
                            #{
                                stars := Stars,
                                useful := Useful,
                                funny := Funny,
                                cool := Cool,
                                text := Text
                            } = _Rec} ->
                            ecai_search:add_review_stats(
                                Ctx,
                                DocId,
                                to_float(Stars),
                                to_int(Useful),
                                to_int(Funny),
                                to_int(Cool)
                            ),
                            ecai_search:index_text(Ctx, DocId, <<"rev">>, Text, 40)
                    end;
                _ ->
                    ok
            end,
            index_lines(Ctx, Fd, N, Cnt + 1)
    end.

safe_decode(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        M when is_map(M) -> {ok, M};
        _ -> error
    catch
        _:_ -> error
    end.

%%%===================================================================
%%% 5) PROJECT Yelp → ECAI record (using ecai_tokenizer)
%%%===================================================================

%% Expected Yelp fields in each JSON line:
%%  business_id, name, city, state, postal_code, categories (CSV), phone
-spec yelp_to_record(map()) -> skip | {binary(), map()}.
yelp_to_record(#{<<"business_id">> := undefined} = _B) ->
    skip;
yelp_to_record(#{<<"review_id">> := RevId, <<"business_id">> := DocId} = R) ->
    Stars = maps:get(<<"stars">>, R, 0.0),
    Useful = maps:get(<<"useful">>, R, 0),
    Funny = maps:get(<<"funny">>, R, 0),
    Cool = maps:get(<<"cool">>, R, 0),
    Text = maps:get(<<"text">>, R, <<>>),
    {review, DocId, #{
        business_id => DocId,
        review_id => RevId,
        stars => Stars,
        useful => Useful,
        funny => Funny,
        cool => Cool,
        text => Text
    }};
yelp_to_record(#{<<"business_id">> := BID} = B) ->
    Name = maps:get(<<"name">>, B, <<>>),
    City = maps:get(<<"city">>, B, <<>>),
    Cats = maps:get(<<"categories">>, B, <<>>),
    Post = maps:get(<<"postal_code">>, B, <<>>),
    Phone = maps:get(<<"phone">>, B, <<>>),

    %% Use tokenizer for normalization
    %?LOG_DEBUG("yelp_to_record ~p", [Name]),
    NameBin = ecai_tokenizer:lower_ascii(Name),
    CityBin = ecai_tokenizer:lower_ascii(City),
    %% categories: CSV split -> lower_ascii per item
    CatItems = cat_items(Cats),
    CatMain =
        case CatItems of
            [] -> <<>>;
            [H | _] -> H
        end,
    %% tags: all categories + postcode (as tag) if present
    PostTag =
        case ecai_tokenizer:digits_only(Post) of
            <<>> -> [];
            D -> [D]
        end,
    TagsBin = CatItems ++ PostTag,
    PhoneNorm = ecai_tokenizer:digits_only(Phone),

    %% keep Yelp business_id as the doc key
    DocId = BID,

    {business, DocId, #{
        name => NameBin,
        category => CatMain,
        city => CityBin,
        tags => TagsBin,
        phone => PhoneNorm
    }}.

cat_items(null) ->
    [];
cat_items(Cats) ->
    %% split on commas; trim spaces; lower; to binary via tokenizer
    Cs = binary:split(to_bin(Cats), <<$,>>, [global]),
    [ecai_tokenizer:lower_ascii(string:trim(C)) || C <- Cs, C =/= <<>>].

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    case catch erlang:binary_to_integer(B) of
        V when is_integer(V) -> V;
        _ -> 0
    end;
to_int(_) ->
    0.

to_float(F) when is_float(F) -> F;
to_float(I) when is_integer(I) -> float(I);
to_float(B) when is_binary(B) ->
    case string:to_float(binary_to_list(B)) of
        {V, _} -> V;
        _ -> 0.0
    end;
to_float(_) ->
    0.0.

%%%===================================================================
%%% 6) HEADERS + MANIFEST (Merkle over CIDs)
%%%===================================================================

extract_headers(Ctx) ->
    ecai_search:export_onchain_headers(Ctx).

build_manifest(ChunkCIDs, Headers) ->
    CIDs = [CID || {_P, CID} <- ChunkCIDs],
    Root = manifest_root(CIDs),
    #{cids => CIDs, merkle_root => Root, headers => Headers}.

manifest_root(CIDs) ->
    Leaves = [leaf(CID) || CID <- CIDs],
    tree_root(Leaves).

leaf(CID) ->
    <<0, (crypto:hash(sha256, CID))/binary>>.

node(L, R) ->
    <<1, (crypto:hash(sha256, <<L/binary, R/binary>>))/binary>>.

tree_root([]) -> <<1, (crypto:hash(sha256, <<>>))/binary>>;
tree_root([X]) -> X;
tree_root([A, B | Rest]) -> tree_root([node(A, B) | pairup(Rest)]).

pairup([]) -> [];
pairup([A]) -> [node(A, A)];
pairup([A, B | Rest]) -> [node(A, B) | pairup(Rest)].

%%%===================================================================
%%% Utils
%%%===================================================================

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
