%% Ciphertext-only immutable segments. No plaintext temporary files, DETS,
%% public manifest, shared hot cache, on-chain headers or public ingest WAL.
-module(ecai_private_store).
-include_lib("kernel/include/file.hrl").
-export([append/5, segments/2, read/3, assert_public/1, valid_batch_id/1]).

-define(MARKER, ".ecai-private-v1").
-define(MAX_SEGMENTS, 1024).

-spec append(map(), binary(), binary(), term(), map()) -> ok.
append(Config, PublicKey, BatchId, Segment, Context) ->
    ecai_private_policy:guard(valid_batch_id(BatchId)),
    Dir = directory(Config),
    %% Single local filesystem owner. Multi-node/shared-volume writers need an
    %% external lease; global locks on this node are not distributed consensus.
    Lock = {{?MODULE, Dir}, self()},
    case global:trans(Lock, fun() ->
        check_writer(Config),
        ensure_directory(Dir),
        ensure_marker(Dir, Config, PublicKey, create),
        Existing = [N || N <- directory_entries(Dir), is_segment_name(N)],
        case length(Existing) < ?MAX_SEGMENTS of
            true -> ok;
            false -> ecai_private_policy:fail(private_segment_limit)
        end,
        Path = segment_path(Dir, BatchId),
        case file:read_link_info(Path) of
            {error, enoent} -> ok;
            {ok, _} -> ecai_private_policy:fail(batch_already_exists);
            _ -> ecai_private_policy:fail(private_storage_unavailable)
        end,
        Bytes = ecai_private_crypto:seal(Segment, PublicKey, Context),
        check_writer(Config),
        immutable_write(Path, Bytes)
    end, [node()]) of
        aborted -> ecai_private_policy:fail(private_storage_busy);
        Result -> Result
    end.

-spec segments(map(), binary()) -> [{binary(), file:filename()}].
segments(Config, PublicKey) ->
    Dir = directory(Config),
    require_directory(Dir),
    ensure_marker(Dir, Config, PublicKey, existing),
    Names = directory_entries(Dir),
    SegmentNames = [N || N <- Names, is_segment_name(N)],
    case length(SegmentNames) =< ?MAX_SEGMENTS of
        true -> ok;
        false -> ecai_private_policy:fail(private_segment_limit)
    end,
    %% Do not silently ignore foreign plaintext files or a corrupt filename.
    lists:foreach(fun(N) ->
        case N =:= ?MARKER orelse is_segment_name(N) orelse
             lists:prefix(".pending-", N) of
            true -> ok;
            false -> ecai_private_policy:fail(private_directory_contaminated)
        end
    end, Names),
    [{list_to_binary(filename:rootname(N, ".ecp")), filename:join(Dir, N)}
     || N <- lists:sort(SegmentNames)].

-spec read(file:filename(), binary(), map()) -> term().
read(Path, PrivateKey, Context) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size, mode = Mode}}
          when Size =< 33554436, Mode band 8#077 =:= 0 ->
            case file:read_file(Path) of
                {ok, Bytes} -> ecai_private_crypto:open(Bytes, PrivateKey, Context);
                _ -> ecai_private_policy:fail(private_storage_unavailable)
            end;
        _ -> ecai_private_policy:fail(private_storage_unavailable)
    end.

%% Used by legacy public writers/readers. Even an uninitialised configured
%% private directory is reserved. A deleted marker does not permit downgrade
%% while private segment files remain. No recursive migration is performed.
-spec assert_public(file:filename_all()) -> ok.
assert_public(BaseDir) ->
    Dir = canonical_path(path_list(BaseDir)),
    Corpora = application:get_env(ecai, private_corpora, #{}),
    Reserved = lists:any(fun(C) ->
        Root = canonical_path(path_list(maps:get(base_dir, C))),
        lists:prefix(filename:split(Root), filename:split(Dir))
    end, maps:values(Corpora)),
    HasMarker = ancestor_marker(Dir),
    HasSegments = case file:list_dir(Dir) of
        {ok, Names} -> lists:any(fun is_segment_name/1, Names);
        {error, enoent} -> false;
        _ -> true
    end,
    case Reserved orelse HasMarker orelse HasSegments of
        true -> erlang:error(private_index_requires_authorized_api);
        false -> ok
    end.

valid_batch_id(B) when is_binary(B), byte_size(B) =:= 32 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                       (C >= $a andalso C =< $f) end, binary_to_list(B));
valid_batch_id(_) -> false.

is_segment_name(Name) ->
    filename:extension(Name) =:= ".ecp" andalso
        valid_batch_id(list_to_binary(filename:rootname(Name, ".ecp"))).

segment_path(Dir, Id) -> filename:join(Dir, binary_to_list(Id) ++ ".ecp").
directory(Config) ->
    Dir = path_list(maps:get(base_dir, Config)),
    ecai_private_policy:guard(filename:pathtype(Dir) =:= absolute),
    ecai_private_policy:guard(not lists:member("..", filename:split(Dir))),
    filename:absname(Dir).
path_list(Bin) when is_binary(Bin) -> binary_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List.

ensure_directory(Dir) ->
    case file:read_link_info(Dir) of
        {error, enoent} ->
            %% The configured parent and its ancestors must be operator-owned.
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            ok = file:change_mode(Dir, 8#700),
            require_directory(Dir);
        _ -> require_directory(Dir)
    end.
require_directory(Dir) ->
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory, mode = Mode}}
          when Mode band 8#777 =:= 8#700 -> ok;
        {error, enoent} -> ecai_private_policy:fail(private_index_not_initialized);
        _ -> ecai_private_policy:fail(private_directory_permissions)
    end.

directory_entries(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> Names;
        _ -> ecai_private_policy:fail(private_storage_unavailable)
    end.

ensure_marker(Dir, Config, PublicKey, Mode) ->
    Scope = ecai_private_crypto:scope(Config, PublicKey),
    Hash = crypto:hash(sha256, term_to_binary(Scope, [deterministic])),
    Expected = <<"ECAI-PRIVATE-INDEX", 0, 1, Hash/binary>>,
    Path = filename:join(Dir, ?MARKER),
    case file:read_link_info(Path) of
        {error, enoent} when Mode =:= create ->
            case directory_entries(Dir) of
                [] -> immutable_write(Path, Expected);
                _ -> ecai_private_policy:fail(private_requires_empty_directory)
            end;
        {ok, #file_info{type = regular, size = Size, mode = FileMode}}
          when Size =:= byte_size(Expected), FileMode band 8#077 =:= 0 ->
            case file:read_file(Path) of
                {ok, Expected} -> ok;
                _ -> ecai_private_policy:fail(private_scope_or_key_mismatch)
            end;
        {error, enoent} -> ecai_private_policy:fail(private_index_not_initialized);
        _ -> ecai_private_policy:fail(private_scope_or_key_mismatch)
    end.

immutable_write(Path, Bytes) ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Tmp = filename:join(filename:dirname(Path), ".pending-" ++ Suffix),
    {ok, FD} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:change_mode(Tmp, 8#600),
        ok = file:write(FD, Bytes),
        ok = file:sync(FD),
        ok = file:close(FD),
        %% Hard-link publication is atomic AND refuses replacement of an
        %% existing immutable name, unlike rename/2 on Unix. Same filesystem.
        case file:make_link(Tmp, Path) of
            ok -> ok;
            {error, eexist} -> ecai_private_policy:fail(batch_already_exists);
            _ -> ecai_private_policy:fail(private_storage_unavailable)
        end
    after
        _ = file:close(FD),
        _ = file:delete(Tmp)
    end.

canonical_path(Path) ->
    Parts = filename:split(filename:absname(Path)),
    filename:join(lists:reverse(lists:foldl(fun
        (".", Acc) -> Acc;
        ("..", [Last | Rest]) when Last =/= "/" -> Rest;
        ("..", Acc) -> Acc;
        (Part, Acc) -> [Part | Acc]
    end, [], Parts))).

ancestor_marker(Dir) ->
    case file:read_link_info(filename:join(Dir, ?MARKER)) of
        {error, enoent} ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of true -> false; false -> ancestor_marker(Parent) end;
        _ -> true
    end.

check_writer(Config) ->
    Current = ecai_private_policy:resolve(maps:get(corpus, Config),
                                        maps:get(principal, Config), write),
    IdentityFields = [owner, corpus, base_dir, key_id, key_name],
    case maps:with(IdentityFields, Current) =:= maps:with(IdentityFields, Config) of
        true -> ok;
        false -> ecai_private_policy:fail(private_configuration_changed)
    end.
