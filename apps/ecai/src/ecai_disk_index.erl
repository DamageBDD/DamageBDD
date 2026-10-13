%%--------------------------------------------------------------------
%% Disk-backed ECAI index encoder
%% Records are fixed-width and sorted by KeyPoint for binary-search.
%%
%% Each entry:
%%   #{key := KeyPoint33, kind := Kind, doc_id := DocId,
%%     off := PayloadOffset, len := PayloadLen}
%%
%% KeyPoint33 is a 33-byte compressed EC point (e.g., secp256k1).
%%--------------------------------------------------------------------

-module(ecai_disk_index).
-export([encode/2, encode/3]).

-define(MAGIC, <<"ECAI">>).
-define(VERSION, 1).
-define(HEADER_BYTES, 64).
-define(RECORD_BYTES, 48).

-type entry() :: #{
    %% 33 bytes
    key := binary(),
    %% 0..255
    kind := non_neg_integer(),
    %% 0..2^32-1
    doc_id := non_neg_integer(),
    %% 0..2^64-1
    off := non_neg_integer(),
    %% 0..65535
    len := non_neg_integer()
}.

%% encode(IndexEntries, IndexPath) -> ok | {error, Reason}
-spec encode([entry()], file:filename()) -> ok | {error, term()}.
-spec encode([entry()], file:filename(), map()) -> ok | {error, term()}.
encode(Entries0, Path) ->
    encode(Entries0, Path, #{}).

%% Options:
%%   #{fsync => true|false, sort => true|false}
encode(Entries0, Path, Opts) when is_list(Entries0) ->
    Sort = maps:get(sort, Opts, true),
    Fsync = maps:get(fsync, Opts, true),

    %% Validate + normalize
    Entries1 = [validate_entry(E) || E <- Entries0],

    %% Sort by key (lexicographic on compressed point bytes)
    Entries =
        case Sort of
            true -> lists:sort(fun cmp_entry/2, Entries1);
            false -> Entries1
        end,

    N = length(Entries),

    %% Write file
    case file:open(Path, [raw, binary, write]) of
        {ok, FD} ->
            try
                ok = write_header(FD, N),
                ok = write_records(FD, Entries),
                ok = maybe_fsync(FD, Fsync),
                ok = file:close(FD),
                ok
            catch
                C:R ->
                    _ = file:close(FD),
                    {error, {C, R}}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

cmp_entry(#{key := K1}, #{key := K2}) -> K1 =< K2.

validate_entry(
    E = #{
        key := K,
        kind := Kind,
        doc_id := DocId,
        off := Off,
        len := Len
    }
) ->
    %% Key
    true = is_binary(K),
    33 = byte_size(K),

    %% Kind (u8)
    true = is_integer(Kind),
    true = (0 =< Kind andalso Kind =< 255),

    %% DocId (u32)
    true = is_integer(DocId),
    true = (0 =< DocId andalso DocId =< 16#FFFFFFFF),

    %% Offset (u64)
    true = is_integer(Off),
    true = (0 =< Off andalso Off =< 16#FFFFFFFFFFFFFFFF),

    %% Length (u16)
    true = is_integer(Len),
    true = (0 =< Len andalso Len =< 16#FFFF),

    E;
validate_entry(Other) ->
    erlang:error({bad_entry, Other}).

write_header(FD, N) ->
    %% Header is fixed at 64 bytes so records start at a stable offset.
    %% Big-endian for easy cross-language reading.
    RecSz = ?RECORD_BYTES,
    Flags = 0,

    Hdr0 =
        %% 4
        <<?MAGIC/binary,
            %% 2
            ?VERSION:16/big-unsigned,
            %% 2
            Flags:16/big-unsigned,
            %% 8
            N:64/big-unsigned,
            %% 4
            RecSz:32/big-unsigned,
            %% pad to 64
            0:((?HEADER_BYTES - 4 - 2 - 2 - 8 - 4) * 8)>>,
    ok = file:write(FD, Hdr0).

write_records(FD, Entries) ->
    %% Write in chunks to reduce syscall overhead
    Bin = iolist_to_binary([encode_record(E) || E <- Entries]),
    ok = file:write(FD, Bin).

encode_record(#{key := KeyPoint33, kind := Kind, doc_id := DocId, off := Off, len := Len}) ->
    %% 48 bytes total:
    %% 33 key + 1 kind + 4 doc + 8 off + 2 len = 48
    <<KeyPoint33/binary, Kind:8/unsigned, DocId:32/big-unsigned, Off:64/big-unsigned,
        Len:16/big-unsigned>>.

maybe_fsync(_FD, false) ->
    ok;
maybe_fsync(FD, true) ->
    %% Erlang/OTP has file:sync/1
    file:sync(FD).
