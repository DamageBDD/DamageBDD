%% Complete-source recovery is storage recovery, not hash inversion.
%% Public sources only. Private corpora keep their existing authorised path.
-module(ecai_source_retrieval).
-export([retain/4, disk/2, disk_source/3, from_record/1,
         describe/1, summary/1, reassemble/3, max_bytes/0, index_text/3]).

-define(DEFAULT_MAX_BYTES, 67108864).

max_bytes() ->
    case application:get_env(ecai, source_retrieval_max_bytes, ?DEFAULT_MAX_BYTES) of
        N when is_integer(N), N > 0, N =< 268435456 -> N;
        _ -> ?DEFAULT_MAX_BYTES
    end.

%% Called with the EXACT fetched bytes, before chunk publication. Blobs are
%% immutable, content addressed and outside DETS (which has a 2 GB file limit).
retain(BaseDir, Bytes, SourceKey, Version) when
    is_binary(Bytes), is_binary(SourceKey), is_binary(Version)
->
    protect(fun() ->
        ok = ecai_private_store:assert_public(BaseDir),
        require(byte_size(Bytes) =< max_bytes(), source_too_large),
        ok = ecai_chunker:validate_utf8(Bytes),
        Sha = hex(crypto:hash(sha256, Bytes)),
        Path = blob_path(BaseDir, Sha),
        ok = filelib:ensure_dir(Path),
        %% Concurrent writers of identical content may publish the same bytes.
        case file:read_file(Path) of
            {ok, Existing} -> require(Existing =:= Bytes, source_blob_corrupt);
            {error, enoent} -> ok = atomic_write(Path, Bytes);
            {error, Why} -> fail({source_read_failed, Why})
        end,
        {ok, #{sha256 => Sha, bytes => byte_size(Bytes), complete => true,
               representation => <<"original_utf8_bytes">>,
               source_key => SourceKey, source_version => Version}}
    end);
retain(_, _, _, _) -> {error, badarg}.

disk(BaseDir, DocInt) when is_integer(DocInt), DocInt > 0 ->
    with_docstore(BaseDir, fun(Tab) ->
        case ecai_disk_docstore:get(Tab, DocInt) of
            {ok, Record} -> resolve_disk_record(BaseDir, Record);
            not_found -> {error, source_not_found};
            Error -> Error
        end
    end);
disk(_, _) -> {error, badarg}.

disk_source(BaseDir, SourceKey, Version) when is_binary(SourceKey), is_binary(Version) ->
    with_docstore(BaseDir, fun(Tab) ->
        case ecai_disk_docstore:get_source(Tab, SourceKey, Version) of
            {ok, Ref} -> read_blob(BaseDir, Ref);
            not_found -> {error, source_not_retained};
            Error -> Error
        end
    end);
disk_source(_, _, _) -> {error, badarg}.

with_docstore(BaseDir, Fun) ->
    protect(fun() ->
        ok = ecai_private_store:assert_public(BaseDir),
        %% A read must not create a corpus or an empty metadata store.
        Path = filename:join([BaseDir, "docstore", "ecai_docstore.dets"]),
        require(filelib:is_regular(Path), source_not_found),
        {ok, Tab} = ecai_disk_docstore:open(BaseDir),
        try Fun(Tab) after ecai_disk_docstore:close(Tab) end
    end).

resolve_disk_record(BaseDir, #{source_blob := Ref}) -> read_blob(BaseDir, Ref);
resolve_disk_record(_BaseDir, Record) -> from_record(Record).

read_blob(BaseDir, #{sha256 := Sha, bytes := Size} = Ref) ->
    require(is_integer(Size) andalso Size >= 0 andalso Size =< max_bytes(), source_too_large),
    Path = blob_path(BaseDir, Sha),
    {ok, Fd} = file:open(Path, [read, raw, binary]),
    try
        Bytes = case file:read(Fd, Size + 1) of
            {ok, B} -> B;
            eof -> <<>>;
            {error, Why} -> fail({source_read_failed, Why})
        end,
        require(byte_size(Bytes) =:= Size, source_length_mismatch),
        require(hex(crypto:hash(sha256, Bytes)) =:= Sha, source_hash_mismatch),
        {ok, Ref#{text => Bytes, integrity => verified_sha256}}
    after file:close(Fd) end;
read_blob(_, _) -> {error, invalid_source_descriptor}.

%% Wikimedia keeps the untruncated dump field in normalized JSONL / snapshots.
%% Its declared representation is NOT the original rendered webpage or PDF.
from_record(Record) when is_map(Record) ->
    protect(fun() ->
        ok = ecai_private_policy:assert_public_record(Record),
        case maps:find(source_text, Record) of
            {ok, Text} when is_binary(Text) ->
                require(byte_size(Text) =< max_bytes(), source_too_large),
                Sha = hex(crypto:hash(sha256, Text)),
                require(Sha =:= maps:get(source_sha256, Record, undefined), source_hash_mismatch),
                require(byte_size(Text) =:= maps:get(source_bytes, Record, undefined), source_length_mismatch),
                ok = ecai_chunker:validate_utf8(Text),
                Desc = record_descriptor(Record),
                require(is_boolean(maps:get(complete,Desc)), invalid_source_descriptor),
                require(is_binary(maps:get(representation,Desc)), invalid_source_descriptor),
                {ok, Desc#{text => Text, integrity => verified_sha256}};
            _ ->
                Text = maps:get(text, Record, maps:get(abstract, Record, <<>>)),
                require(is_binary(Text) andalso byte_size(Text) =< max_bytes(), source_too_large),
                {ok, #{text => Text, bytes => byte_size(Text), complete => false,
                       representation => <<"stored_excerpt">>, integrity => unverified,
                       reason => complete_source_not_retained}}
        end
    end);
from_record(_) -> {error, badarg}.

describe(#{source_text := _} = Record) -> record_descriptor(Record);
describe(#{source_blob := Ref}) when is_map(Ref) -> Ref;
describe(#{source_retrieval := Ref}) when is_map(Ref) -> Ref;
describe(_Record) ->
    #{complete => false, representation => <<"stored_excerpt">>}.

record_descriptor(Record) ->
    #{sha256 => maps:get(source_sha256, Record, undefined),
      bytes => maps:get(source_bytes, Record, undefined),
      complete => maps:get(source_complete, Record, false),
      representation => maps:get(source_representation, Record, <<"stored_excerpt">>)}.

index_text(Ctx, DocId, #{source_text := Text} = Record) ->
    case from_record(Record) of
        {ok, _} ->
            Cap = maps:get(source_index_token_limit, Record, 4096),
            true = is_integer(Cap) andalso Cap > 0 andalso Cap =< 65536,
            ecai_search:index_text(Ctx, DocId, <<"text">>, Text, Cap);
        {error, Why} -> erlang:error({invalid_retained_source, Why})
    end;
index_text(_Ctx, _DocId, _Record) -> ok.

%% Search is a projection. Use source retrieval for the full payload; v2 record
%% proofs still commit to the ORIGINAL record, not this projected search map.
summary(Record) ->
    (maps:without([source_text], Record))#{source_retrieval => describe(Record)}.

%% Explicit migration/recovery API for old chunk stores. Requires the expected
%% ORIGINAL byte length and digest from a trusted manifest. No missing-tail
%% guess, ordinal gap, mismatched overlap or silently concatenated version.
reassemble(Records, ExpectedBytes, ExpectedSha) when
    is_list(Records), Records =/= [], is_integer(ExpectedBytes), ExpectedBytes >= 0
->
    protect(fun() ->
        require(ExpectedBytes =< max_bytes(), source_too_large),
        require(length(Records) =< 65536, too_many_chunks),
        Sorted = lists:sort(fun(A,B) -> maps:get(chunk_ordinal,A) < maps:get(chunk_ordinal,B) end, Records),
        [First | _] = Sorted,
        Identity = maps:with([source_key, source_version, chunker], First),
        require(map_size(Identity) =:= 3, missing_source_identity),
        {End, Pieces, _Previous, _NextOrdinal} = lists:foldl(fun(R, {Cursor, Acc, Previous, Ord}) ->
            require(maps:get(chunk_ordinal, R) =:= Ord, chunk_ordinal_gap),
            require(maps:with([source_key,source_version,chunker],R) =:= Identity, mixed_source_versions),
            Text = maps:get(text, R),
            Start = maps:get(chunk_byte_start,R), Stop = maps:get(chunk_byte_end,R),
            require(is_binary(Text) andalso is_integer(Start) andalso is_integer(Stop), invalid_chunk),
            require(Start >= 0 andalso Start =< Cursor andalso Stop > Cursor andalso Stop =< ExpectedBytes, chunk_gap_or_range),
            require(Stop - Start =:= byte_size(Text), chunk_length_mismatch),
            require(crypto:hash(sha256,Text) =:= maps:get(chunk_content_sha256,R), chunk_hash_mismatch),
            Overlap = Cursor - Start,
            require(Overlap =< byte_size(Previous), overlap_out_of_range),
            require(binary:part(Text,0,Overlap) =:= binary:part(Previous,byte_size(Previous)-Overlap,Overlap), chunk_overlap_mismatch),
            Suffix = binary:part(Text,Overlap,byte_size(Text)-Overlap),
            {Stop, [Suffix|Acc], Text, Ord + 1}
        end, {0, [], <<>>, 1}, Sorted),
        Bytes = iolist_to_binary(lists:reverse(Pieces)),
        require(End =:= ExpectedBytes, incomplete_source),
        require(hex(crypto:hash(sha256,Bytes)) =:= ExpectedSha, source_hash_mismatch),
        {ok, #{text => Bytes, bytes => End, sha256 => ExpectedSha,
               complete => true, integrity => verified_sha256,
               representation => <<"reconstructed_utf8_bytes">>}}
    end);
reassemble(_, _, _) -> {error, badarg}.

blob_path(BaseDir, Sha) ->
    require(is_binary(Sha) andalso byte_size(Sha) =:= 64, invalid_source_digest),
    require(lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
                      binary_to_list(Sha)), invalid_source_digest),
    filename:join([BaseDir, "sources", binary_to_list(Sha) ++ ".bin"]).

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    try
        {ok, Fd} = file:open(Tmp, [write, raw, binary, exclusive]),
        try ok = file:write(Fd, Bytes), ok = file:sync(Fd)
        after file:close(Fd) end,
        ok = file:rename(Tmp, Path)
    after _ = file:delete(Tmp) end.

hex(B) -> << <<(digit(N bsr 4)),(digit(N band 15))>> || <<N>> <= B >>.
digit(N) when N < 10 -> $0 + N;
digit(N) -> $a + N - 10.
require(true, _) -> ok;
require(false, Why) -> fail(Why).
fail(Why) -> throw({source_retrieval, Why}).
protect(Fun) ->
    try Fun() catch
        throw:{source_retrieval, Why} -> {error, Why};
        error:{badmatch,{error,Why}} -> {error, Why};
        Class:Why -> {error, {source_retrieval_failed, Class, Why}}
    end.
