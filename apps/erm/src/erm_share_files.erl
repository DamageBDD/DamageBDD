%% Local, bounded file boundary for the share inbox. No sender-chosen writes.
-module(erm_share_files).
-include_lib("kernel/include/file.hrl").
-export([directory/1, read/3, write/2, hex/1, utf8/1]).

directory(Path) ->
    P = filename:absname(Path),
    ok = filelib:ensure_dir(filename:join(P, "placeholder")),
    ok = no_links(P),
    {ok, #file_info{type = directory}} = file:read_link_info(P),
    ok = file:change_mode(P, 8#700),
    P.

read(Path, Roots, Max) ->
    try
        P = filename:absname(Path),
        true = lists:any(fun(R) -> beneath(P, filename:absname(R)) end, Roots),
        ok = no_links(P),
        {ok, Before = #file_info{type = regular, size = Size}} = file:read_link_info(P),
        true = Size =< Max,
        {ok, F} = file:open(P, [read, binary, raw]),
        try
            {ok, Opened} = file:read_file_info(F),
            true = same(Before, Opened),
            Bytes = case file:read(F, Max + 1) of {ok, B} -> B; eof -> <<>> end,
            true = byte_size(Bytes) =:= Size,
            {ok, After} = file:read_file_info(F),
            true = same(Before, After),
            {ok, Bytes}
        after file:close(F) end
    catch _:_ -> {error, unsafe_or_changed_file} end.

write(Path, Bytes) ->
    Temp = Path ++ ".pending-" ++ binary_to_list(hex(crypto:strong_rand_bytes(8))),
    try
        {ok, F} = file:open(Temp, [write, binary, raw, exclusive]),
        try
            ok = file:change_mode(Temp, 8#600),
            ok = file:write(F, Bytes),
            ok = file:sync(F)
        after file:close(F) end,
        ok = file:rename(Temp, Path)
    catch Class:Reason:Stack ->
        _ = file:delete(Temp),
        erlang:raise(Class, Reason, Stack)
    end.

beneath(P, R) ->
    PP = filename:split(P), RR = filename:split(R),
    not lists:member("..", PP) andalso length(PP) > length(RR) andalso lists:prefix(RR, PP).

no_links(P) -> no_links(filename:split(P), "").
no_links([], _) -> ok;
no_links([".." | _], _) -> error(parent_path);
no_links([H | T], Acc) ->
    Next = case Acc of "" -> H; _ -> filename:join(Acc, H) end,
    case file:read_link_info(Next) of
        {ok, #file_info{type = symlink}} -> error(symlink);
        {ok, _} -> no_links(T, Next);
        _ -> error(missing_path)
    end.

same(A, B) ->
    A#file_info.type =:= B#file_info.type andalso
    A#file_info.inode =:= B#file_info.inode andalso
    A#file_info.major_device =:= B#file_info.major_device andalso
    A#file_info.size =:= B#file_info.size andalso
    A#file_info.mtime =:= B#file_info.mtime andalso
    A#file_info.ctime =:= B#file_info.ctime.

hex(B) -> << <<(digit(X bsr 4)), (digit(X band 15))>> || <<X>> <= B >>.
digit(N) when N < 10 -> $0 + N;
digit(N) -> $a + N - 10.
utf8(B) when is_binary(B) ->
    is_binary(unicode:characters_to_binary(B)) andalso binary:match(B, <<0>>) =:= nomatch;
utf8(_) -> false.
