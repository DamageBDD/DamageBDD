%% Shared initialization for durable relay events and dashboard accounts.
%% Never substitute an empty temporary database after a storage failure.
-module(nosternity_storage).
-include_lib("kernel/include/logger.hrl").
-export([open/3]).

open(Key, Name, Repair) ->
    File = nosternity_config:get(Key),
    case check_legacy(Key, File) of
        ok ->
            case filelib:ensure_dir(File) of
                ok ->
                    case writable_directory(filename:dirname(File)) of
                        ok -> open_dets(Key, Name, File, Repair);
                        {error, Why} -> failure(Key, File, write_directory, Why)
                    end;
                {error, Why} -> failure(Key, File, ensure_directory, Why)
            end;
        {error, Why} -> failure(Key, File, check_legacy_store, Why)
    end.

%% Changing the default must not silently hide an old account database or
%% deletion tombstones. Operators either move it while stopped or configure
%% an explicit store path. Existing new-layout databases take precedence.
check_legacy(Key, File) ->
    case application:get_env(nosternity, Key) of
        {ok, _} -> ok;
        undefined ->
            Legacy = filename:absname(filename:join(["data", "nosternity", filename:basename(File)])),
            case File =:= Legacy of
                true -> ok;
                false ->
                    case file:read_file_info(File) of
                        {error, enoent} -> legacy_absent(Legacy);
                        _ -> ok
                    end
            end
    end.

legacy_absent(Legacy) ->
    case file:read_file_info(Legacy) of
        {error, enoent} -> ok;
        {error, enotdir} -> ok;
        {ok, _} -> {error, {legacy_store_requires_migration, Legacy}};
        {error, Why} -> {error, {legacy_store_check_failed, Legacy, Why}}
    end.

%% DETS may rewrite/rename files during sync or repair. Opening an existing
%% file alone does not prove that its parent directory is writable.
writable_directory(Dir) ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Probe = filename:join(Dir, ".nosternity-write-" ++ os:getpid() ++ "-" ++ Suffix),
    case file:open(Probe, [write, exclusive, raw, binary]) of
        {ok, Handle} ->
            Closed = file:close(Handle),
            Deleted = file:delete(Probe),
            case Closed of ok -> Deleted; _ -> Closed end;
        {error, eexist} -> writable_directory(Dir);
        {error, _} = Error -> Error
    end.

open_dets(Key, Name, File, Repair) ->
    case dets:open_file(Name, [{file, File}, {type, set}, {repair, Repair}]) of
        {ok, Db} ->
            case file:change_mode(File, 8#600) of
                ok ->
                    ?LOG_INFO("Nosternity ~p opened at ~ts", [Key, File]),
                    {ok, Db, File};
                {error, Why} ->
                    dets:close(Db),
                    failure(Key, File, set_file_permissions, Why)
            end;
        {error, Why} -> failure(Key, File, open_dets, Why)
    end.

failure(Key, File, Operation, Why) ->
    Reason = {nosternity_store_unavailable, Key,
        #{file => File, directory => filename:dirname(File),
          operation => Operation, reason => Why}},
    ?LOG_ERROR("Nosternity storage initialization failed: ~p", [Reason]),
    {error, Reason}.
