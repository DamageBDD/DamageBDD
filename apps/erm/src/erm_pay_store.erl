-module(erm_pay_store).

-export([
    save_conn/1,
    load_conn/0,
    delete_conn/0,
    path/0
]).

path() ->
    case application:get_env(erm_pay, store_path) of
        {ok, Path} ->
            Path;
        undefined ->
            Home =
                case os:getenv("HOME") of
                    false -> ".";
                    H -> H
                end,
            filename:join([Home, ".config", "erm", "nwc.term"])
    end.

save_conn(Conn) when is_binary(Conn) ->
    Path = path(),
    ok = filelib:ensure_dir(Path),
    Tmp = Path ++ ".tmp",
    Data = #{version => 1, conn => Conn},
    ok = file:write_file(Tmp, term_to_binary(Data)),
    _ = file:change_mode(Tmp, 8#600),
    file:rename(Tmp, Path).

load_conn() ->
    Path = path(),
    case file:read_file(Path) of
        {ok, Bin} ->
            try binary_to_term(Bin) of
                #{version := 1, conn := Conn} when is_binary(Conn) ->
                    {ok, Conn};
                _ ->
                    {error, bad_store}
            catch
                _:_ ->
                    {error, bad_store}
            end;
        {error, enoent} ->
            {error, not_found};
        Error ->
            Error
    end.

delete_conn() ->
    case file:delete(path()) of
        ok -> ok;
        {error, enoent} -> ok;
        Error -> Error
    end.
