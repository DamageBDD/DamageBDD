%%%-------------------------------------------------------------------
%%% Fixed operational actions. No shell, no caller supplied command text.
%%%-------------------------------------------------------------------
-module(erm_dm_ops).

-export([logout/0, restart_erm/0, poweroff/0, reboot/0, suspend/0,
         systemctl_user/1, loginctl/1]).

logout() ->
    case os:getenv("XDG_SESSION_ID") of
        false -> {error, no_session_id};
        Id -> loginctl(["terminate-session", Id])
    end.
restart_erm() -> systemctl_user(["restart", "erm.service"]).
poweroff() -> loginctl(["poweroff"]).
reboot() -> loginctl(["reboot"]).
suspend() -> loginctl(["suspend"]).

systemctl_user(Args) -> run("systemctl", ["--user" | Args], 10000).
loginctl(Args) -> run("loginctl", Args, 10000).

run(Name, Args, Timeout) ->
    case os:find_executable(Name) of
        false -> {error, {executable_not_found, Name}};
        Exec -> collect(open_port({spawn_executable, Exec}, [binary, exit_status, stderr_to_stdout, {args, Args}]), <<>>, Timeout)
    end.

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>, Timeout);
        {Port, {exit_status, 0}} -> {ok, trim_output(Acc)};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, truncate(Acc)}}
    after Timeout -> catch port_close(Port), {error, timeout}
    end.
truncate(B) when byte_size(B) =< 1024 -> B;
truncate(B) -> binary:part(B, 0, 1024).

trim_output(B) when is_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B))).
