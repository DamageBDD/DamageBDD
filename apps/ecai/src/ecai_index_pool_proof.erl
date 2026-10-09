%% Compare independent, bounded index builds without relying on ETS iteration
%% order in compressed ETF files. This is recomputation, not a succinct proof.
-module(ecai_index_pool_proof).
-include_lib("kernel/include/file.hrl").
-import(ecai_index_pool_util, [need/1, ensure/2, guarded/1, hash/1]).
-export([snapshot/2, canonical/1, compare/2]).

snapshot(Path0, ExpectedSha) -> guarded(fun() ->
    Path = ecai_index_pool_util:shared_path(Path0),
    Max = application:get_env(ecai, index_pool_max_snapshot_bytes, 67108864),
    ensure(is_integer(Max) andalso Max >= 1048576 andalso Max =< 268435456, invalid_snapshot_limit),
    #file_info{type = regular, size = Size} = need(file:read_link_info(Path)),
    ensure(Size > 0 andalso Size =< Max, snapshot_too_large),
    B = need(file:read_file(Path)),
    Actual = ecai_index_job_codec:id_hex(crypto:hash(sha256, B)),
    ensure(Actual =:= ExpectedSha, snapshot_bytes_changed),
    Flat = uncompress(B, Max),
    Map = binary_to_term(Flat, [safe]),
    Canonical = canonical(Map),
    ensure(length(maps:get(rec, Canonical)) > 0, empty_index_not_rewardable),
    #{snapshot_sha256 => Actual, semantic_sha256 => hash(Canonical),
      records => length(maps:get(rec, Canonical)), bytes => Size,
      schema => <<"ecai-index-recomputation/v1">>}
end).
canonical(#{version := 1, opts := Opts, seq := Seq} = M) when is_map(Opts), is_integer(Seq) ->
    Keys = [postings, df, tag, root, rec, i2d, d2i],
    Tables = maps:from_list([{K, table(maps:get(K, M))} || K <- Keys]),
    Tables#{version => 1, opts => Opts, seq => Seq};
canonical(_) -> throw({pool, unsupported_snapshot_schema}).
table(L) when is_list(L) ->
    ensure(lists:all(fun(X) -> is_tuple(X) andalso tuple_size(X) =:= 2 end, L), invalid_snapshot_table),
    Sorted = lists:sort(L),
    ensure(length(lists:usort([element(1, X) || X <- Sorted])) =:= length(L), duplicate_snapshot_rows),
    Sorted;
table(_) -> throw({pool, invalid_snapshot_table}).
compare(#{semantic_sha256 := A, records := N}, #{semantic_sha256 := A, records := N}) -> true;
compare(_, _) -> false.

uncompress(<<131,80,Declared:32/unsigned-big, Data/binary>>, Max) ->
    ensure(Declared > 0 andalso Declared =< Max, expanded_snapshot_too_large),
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z),
        {Parts, Size} = inflate(Z, Data, [], 0, Max),
        ok = zlib:inflateEnd(Z),
        ensure(Size =:= Declared, invalid_compressed_snapshot),
        iolist_to_binary([<<131>>, lists:reverse(Parts)])
    after zlib:close(Z) end;
uncompress(<<131,_/binary>> = B, Max) -> ensure(byte_size(B) =< Max, snapshot_too_large), B;
uncompress(_, _) -> throw({pool, invalid_snapshot}).
inflate(Z, Data, Acc, Size, Max) ->
    {Status, Out} = zlib:safeInflate(Z, Data),
    Next = Size + iolist_size(Out),
    ensure(Next =< Max, expanded_snapshot_too_large),
    case Status of
        finished -> {[Out | Acc], Next};
        continue -> inflate(Z, <<>>, [Out | Acc], Next, Max)
    end.
