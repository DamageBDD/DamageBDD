#!/usr/bin/env escript
%%! -noshell -noinput
%% Add or replace a local ERM capability. Only token hashes enter this file.
-mode(compile).
-include_lib("kernel/include/file.hrl").

main(Args) ->
    try
        Options = options(Args, #{}),
        Principal = text(maps:get("--id", Options)),
        Hash = text(maps:get("--sha256", Options)),
        true = byte_size(Principal) > 0 andalso byte_size(Principal) =< 128,
        true = is_hex(Hash, 64),
        Ops = [text(S) || S <- string:tokens(maps:get("--ops", Options,
            "ping,status,capabilities"), ",")],
        true = Ops =/= [] andalso lists:all(fun allowed/1, Ops),
        Path = maps:get("--grants-file", Options, "/etc/damage/erm-users.config"),
        true = filename:pathtype(Path) =:= absolute,
        Gid = list_to_integer(maps:get("--gid", Options)),
        true = Gid >= 0,
        Parent = filename:dirname(Path),
        ok = trusted_directory(Parent),
        %% Refuse concurrent writers instead of losing another user's grant.
        Lock = filename:join(Parent, ".erm-users.lock"),
        ok = file:make_dir(Lock),
        try update(Path, Principal, Hash, Ops, Gid, Parent)
        after file:del_dir(Lock) end,
        io:format("Updated ERM grant for ~ts. New requests use this grant immediately.~n", [Principal])
    catch
        _:_ ->
            io:format(standard_error,
                "Grant failed. Usage: erm_bridge_grant.escript --id USER --sha256 HEX64 "
                "--gid DAMAGE_GID [--ops ping,status,capabilities] [--grants-file PATH]~n"
                "Use an absolute grants path in an existing trusted directory; "
                "existing files must be regular and not writable by group/others. "
                "If a crashed writer left .erm-users.lock, inspect it before removing it.~n", []),
            halt(1)
    end.

update(Path, Principal, Hash, Ops, Gid, Parent) ->
        Entries = existing(Path),
        Grant = #{id => Principal, token_sha256 => Hash, operations => lists:usort(Ops)},
        Updated = [G || G <- Entries, maps:get(id, G) =/= Principal] ++ [Grant],
        true = valid_grants(Updated),
        {ok, _} = application:ensure_all_started(crypto),
        Tmp = filename:join(Parent, ".erm-users-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))) ++ ".tmp"),
        {ok, Fd} = file:open(Tmp, [write, exclusive, binary]),
        try
            try
                ok = file:change_mode(Tmp, 8#640),
                ok = file:change_group(Tmp, Gid),
                ok = file:write(Fd, io_lib:format("~tp.~n", [Updated])),
                ok = file:sync(Fd)
            after file:close(Fd) end,
            ok = file:rename(Tmp, Path)
        after file:delete(Tmp) end.

options([], O) -> O;
options([K,V|Rest], O) ->
    true = lists:member(K, ["--id", "--sha256", "--gid", "--ops", "--grants-file"]),
    false = maps:is_key(K, O),
    options(Rest, O#{K => V}).
text(S) -> unicode:characters_to_binary(S).
allowed(<<"ping">>) -> true;
allowed(<<"status">>) -> true;
allowed(<<"capabilities">>) -> true;
allowed(_) -> false.
is_hex(B, N) -> byte_size(B) =:= N andalso lists:all(fun(C) ->
    (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
end, binary_to_list(B)).

uid() ->
    {ok, Status} = file:read_file("/proc/self/status"),
    [Line] = [L || <<"Uid:", _/binary>> = L <- binary:split(Status, <<"\n">>, [global])],
    [_Real, Effective | _] = string:lexemes(binary_to_list(binary:part(Line, 4,
        byte_size(Line)-4)), " \t"),
    list_to_integer(Effective).
trusted_directory("/") -> ok;
trusted_directory(Path) ->
    ok = trusted_directory(filename:dirname(Path)),
    {ok, #file_info{type = directory, uid = Owner, mode = Mode}} = file:read_link_info(Path),
    true = Owner =:= 0 orelse Owner =:= uid(),
    true = Mode band 8#022 =:= 0 orelse (Owner =:= 0 andalso Mode band 8#1000 =/= 0),
    ok.
existing(Path) ->
    case file:read_link_info(Path) of
        {error, enoent} -> [];
        {ok, #file_info{type = regular, uid = Owner, mode = Mode, size = Size}} ->
            true = Owner =:= 0 orelse Owner =:= uid(),
            true = Mode band 8#022 =:= 0 andalso Size =< 65536,
            {ok, [Entries]} = file:consult(Path),
            true = valid_grants(Entries),
            Entries
    end.

valid_grants(Entries) when is_list(Entries), length(Entries) =< 256 ->
    Valid = lists:all(fun
        (#{id := Id, token_sha256 := Hash, operations := Ops} = G) ->
            map_size(G) =:= 3 andalso is_binary(Id) andalso byte_size(Id) > 0
                andalso byte_size(Id) =< 128 andalso is_binary(Hash)
                andalso is_hex(Hash,64) andalso is_list(Ops)
                andalso length(Ops) =< 3 andalso lists:all(fun allowed/1,Ops);
        (_) -> false
    end, Entries),
    Valid andalso length(lists:usort([maps:get(id,G) || G <- Entries])) =:= length(Entries)
        andalso length(lists:usort([maps:get(token_sha256,G) || G <- Entries])) =:= length(Entries);
valid_grants(_) -> false.
