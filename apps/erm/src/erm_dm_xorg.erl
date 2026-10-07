%%%-------------------------------------------------------------------
%%% Xorg lifecycle without startx/xinit shell wrappers.
%%%-------------------------------------------------------------------
-module(erm_dm_xorg).

-export([start_user_display/0, start_greeter_display/0]).

start_user_display() -> start(display_number(), "erm-x11.auth").
start_greeter_display() -> start(display_number(), "erm-greeter-x11.auth").

start(N, AuthName) ->
    case {os:find_executable("Xorg"), os:find_executable("xauth")} of
        {false, _} -> {error, xorg_not_found};
        {_, false} -> {error, xauth_not_found};
        {Xorg, Xauth} ->
            Display = ":" ++ integer_to_list(N),
            case runtime_dir() of
                {ok, Runtime} ->
                    XA = filename:join(Runtime, AuthName),
                    ok = ensure_private_file(XA),
                    Cookie = hex_cookie(crypto:strong_rand_bytes(16)),
                    case run(Xauth, ["-f", XA, "add", Display, ".", Cookie], 3000) of
                        {ok, _} ->
                            Args = [Display, "-auth", XA, "-nolisten", "tcp", "-keeptty" | vt_args()],
                            Port = open_port({spawn_executable, Xorg}, [binary, exit_status, stderr_to_stdout, {args, Args}]),
                            case wait_socket(N, Port, 10000) of
                                ok -> {ok, #{port => Port, display => list_to_binary(Display), xauthority => list_to_binary(XA)}};
                                Error -> catch port_close(Port), file:delete(XA), Error
                            end;
                        Error -> file:delete(XA), Error
                    end;
                Error -> Error
            end
    end.

runtime_dir() ->
    case os:getenv("XDG_RUNTIME_DIR") of
        false -> {error, xdg_runtime_dir_missing};
        Dir -> case filelib:is_dir(Dir) of true -> {ok, Dir}; false -> {error, invalid_xdg_runtime_dir} end
    end.

ensure_private_file(Path) ->
    case file:write_file(Path, <<>>, [write, binary, raw]) of
        ok -> file:change_mode(Path, 8#600);
        Error -> Error
    end.

vt_args() ->
    case os:getenv("XDG_VTNR") of
        false -> [];
        V -> ["vt" ++ V]
    end.

display_number() ->
    Config = application:get_env(erm, display_manager, []),
    proplists:get_value(display_number, Config, 0).

wait_socket(N, Port, Remaining) when Remaining =< 0 -> {error, xorg_start_timeout};
wait_socket(N, Port, Remaining) ->
    receive
        {Port, {exit_status, Status}} -> {error, {xorg_exit, Status}};
        {Port, {data, _}} -> wait_socket(N, Port, Remaining)
    after 50 ->
        Sock = filename:join("/tmp/.X11-unix", "X" ++ integer_to_list(N)),
        case file:read_link_info(Sock) of
            {ok, _} -> ok;
            _ -> wait_socket(N, Port, Remaining - 50)
        end
    end.

run(Exec, Args, Timeout) -> collect(open_port({spawn_executable, Exec}, [binary, exit_status, stderr_to_stdout, {args, Args}]), <<>>, Timeout).
collect(P, A, T) -> receive {P,{data,D}} -> collect(P,<<A/binary,D/binary>>,T); {P,{exit_status,0}} -> {ok,A}; {P,{exit_status,S}} -> {error,{exit_status,S}} after T -> catch port_close(P), {error,timeout} end.
hex_cookie(Bin) -> lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
