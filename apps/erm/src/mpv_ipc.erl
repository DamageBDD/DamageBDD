%%%-------------------------------------------------------------------
%%% mpv_ipc.erl — minimal JSON IPC client for MPV
%%%-------------------------------------------------------------------
-module(mpv_ipc).
-include_lib("erm.hrl").
-export([
    ensure_started/0,
    connect/1,
    send/1,
    load_file/1,
    load_list/1,
    playlist_next/0,
    playlist_prev/0,
    toggle_pause/0,
    set_volume/1,
    seek_percent/1
]).

-define(TCP_OPTS, [binary, {active, false}, {packet, 0}]).
-define(IPC_DEFAULT, "/tmp/mpv.sock").

ipc_path() ->
    getenv_default("MPV_IPC", "/tmp/mpv.sock").

getenv_default(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
ensure_started() ->
    erm_mpv_proc:ensure_started(ipc_path()).

connect(Path) ->
    case gen_tcp:connect({local, Path}, 0, ?TCP_OPTS) of
        {ok, Sock} -> {ok, Sock};
        {error, _} = E -> E
    end.

send(Payload0) ->
    Payload = iolist_to_binary(Payload0),
    Path = ipc_path(),
    try
        case gen_tcp:connect({local, Path}, 0, [binary, {active, false}]) of
            {ok, Sock} ->
                try
                    case gen_tcp:send(Sock, Payload) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            {error, {mpv_ipc_send_failed, Path, Reason}}
                    end
                after
                    gen_tcp:close(Sock)
                end;
            {error, Reason} ->
                {error, {mpv_ipc_connect_failed, Path, Reason}}
        end
    of
        Reply ->
            Reply
    catch
        error:Reason0:Stack0 ->
            {error, {exception, error, Reason0, Stack0}};
        exit:Reason0:Stack0 ->
            {error, {exception, exit, Reason0, Stack0}};
        throw:Reason0:Stack0 ->
            {error, {exception, throw, Reason0, Stack0}}
    end.

cmd(Map) -> jsx:encode(Map).

load_file(File) ->
    command([<<"loadfile">>, File, <<"replace">>]).

load_list(File) ->
    command([<<"loadlist">>, File, <<"replace">>]).

command(Args0) ->
    Args = [json_arg(A) || A <- Args0],
    Json = jsx:encode(#{<<"command">> => Args}),
    send([Json, <<"\n">>]).

json_arg(A) when is_binary(A) ->
    A;
json_arg(A) when is_list(A) ->
    unicode:characters_to_binary(A);
json_arg(A) when is_integer(A); is_float(A) ->
    A;
json_arg(true) ->
    true;
json_arg(false) ->
    false;
json_arg(null) ->
    null;
json_arg(A) when is_atom(A) ->
    atom_to_binary(A, utf8).

playlist_next() -> send(cmd(#{"command" => ["playlist-next", "weak"]})).
playlist_prev() -> send(cmd(#{"command" => ["playlist-prev", "weak"]})).

toggle_pause() -> send(cmd(#{"command" => ["cycle", "pause"]})).
set_volume(V) -> send(cmd(#{"command" => ["set", "volume", V]})).
seek_percent(P) -> send(cmd(#{"command" => ["set", "percent-pos", P]})).
