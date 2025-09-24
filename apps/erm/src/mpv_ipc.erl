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
    playlist_next/0,
    playlist_prev/0,
    toggle_pause/0,
    set_volume/1,
    seek_percent/1
]).

-define(TCP_OPTS, [binary, {active, false}, {packet, 0}]).
-define(IPC_DEFAULT, "/tmp/mpv.sock").

ensure_started() ->
    application:ensure_all_started(inets),
    ok.

connect(Path) ->
    case gen_tcp:connect({local, Path}, 0, ?TCP_OPTS) of
        {ok, Sock} -> {ok, Sock};
        {error, _} = E -> E
    end.

send(Json) when is_list(Json) ->
    {ok, Sock} = connect(os:getenv("MPV_IPC", ?IPC_DEFAULT)),
    gen_tcp:send(Sock, Json ++ "\n"),
    _ = gen_tcp:recv(Sock, 0, 200),
    gen_tcp:close(Sock),
    ok.

cmd(Map) -> jsx:encode(Map).

load_file(Path) -> send(cmd(#{"command" => ["loadfile", Path, "replace"]})).
playlist_next() -> send(cmd(#{"command" => ["playlist-next", "weak"]})).
playlist_prev() -> send(cmd(#{"command" => ["playlist-prev", "weak"]})).

toggle_pause() -> send(cmd(#{"command" => ["cycle", "pause"]})).
set_volume(V) -> send(cmd(#{"command" => ["set", "volume", V]})).
seek_percent(P) -> send(cmd(#{"command" => ["set", "percent-pos", P]})).
