%%--------------------------------------------------------------------
%% Immutable source descriptors for local indexing inputs.
%%
%% Local filesystem paths are operator configuration and are not included in
%% index identity. Each source file is represented by its ordinal, byte length,
%% and SHA-256 digest. Adapters capture this descriptor before indexing and the
%% artifact finalizer verifies it again, so an NFT manifest cannot describe
%% bytes different from those admitted by the job.
%%--------------------------------------------------------------------
-module(ecai_index_source).

-export([describe_paths/1, verify_paths/2]).

-define(READ_SIZE, 1048576).

-spec describe_paths([binary() | list()]) -> {ok, map()} | {error, term()}.
describe_paths(Paths) when is_list(Paths), Paths =/= [] ->
    describe_paths(Paths, 1, []);
describe_paths([]) ->
    {error, empty_paths};
describe_paths(_Other) ->
    {error, badarg}.

-spec verify_paths([binary() | list()], map()) -> ok | {error, term()}.
verify_paths(Paths, #{files := ExpectedFiles} = Expected) when is_list(ExpectedFiles) ->
    case describe_paths(Paths) of
        {ok, Expected} ->
            ok;
        {ok, Current} ->
            {error, {source_changed, Expected, Current}};
        {error, _Reason} = Error ->
            Error
    end;
verify_paths(_Paths, _Expected) ->
    {error, invalid_source_identity}.

describe_paths([], _Ordinal, Acc) ->
    {ok, #{files => lists:reverse(Acc)}};
describe_paths([Path0 | Rest], Ordinal, Acc) ->
    case normalize_path(Path0) of
        {ok, Path} ->
            case hash_file(Path) of
                {ok, Bytes, Digest} ->
                    Descriptor = #{
                        ordinal => Ordinal,
                        bytes => Bytes,
                        sha256 => ecai_index_job_codec:id_hex(Digest)
                    },
                    describe_paths(Rest, Ordinal + 1, [Descriptor | Acc]);
                {error, Reason} ->
                    {error, {source_file_read_failed, path_binary(Path), Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

hash_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                hash_file_loop(Fd, crypto:hash_init(sha256), 0)
            after
                _ = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

hash_file_loop(Fd, Context, ByteCount) ->
    case file:read(Fd, ?READ_SIZE) of
        eof ->
            {ok, ByteCount, crypto:hash_final(Context)};
        {ok, Chunk} ->
            hash_file_loop(
                Fd,
                crypto:hash_update(Context, Chunk),
                ByteCount + byte_size(Chunk)
            );
        {error, Reason} ->
            {error, Reason}
    end.

normalize_path(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List) -> {ok, List};
        _Invalid -> {error, invalid_path}
    end;
normalize_path(List) when is_list(List), List =/= [] ->
    {ok, List};
normalize_path(_Other) ->
    {error, invalid_path}.

path_binary(Path) ->
    try unicode:characters_to_binary(Path) of
        Bin when is_binary(Bin) -> Bin
    catch
        _Class:_Reason -> iolist_to_binary(io_lib:format("~p", [Path]))
    end.
