%% Distribution is only an optional local C-node transport, never the Damage
%% control channel. The launcher supplies a private -home for OTP cookie lookup,
%% while leaving OS HOME/XDG pointed at the user's real desktop directories.
-module(erm_user_distribution).
-include_lib("kernel/include/file.hrl").
-export([start/0]).
start() when node() =/= nonode@nohost -> {error, preexisting_distribution_forbidden};
start() ->
    case private_cookie_home() of
        {ok, Home} -> start_private(Home);
        Error -> Error
    end.

private_cookie_home() ->
    case {os:getenv("ERM_USER_COOKIE_HOME"), init:get_argument(home)} of
        {Home, {ok, [[Home]]}} when is_list(Home), Home =/= [] ->
            case {erm_user_config:safe_user_path(Home), file:read_link_info(Home)} of
                {ok, {ok, #file_info{type = directory, uid = Owner, mode = Mode}}} ->
                    case Owner =:= erm_user_config:uid() andalso Mode band 8#077 =:= 0 of
                        true -> {ok, Home};
                        false -> {error, unsafe_private_cookie_home}
                    end;
                _ -> {error, unsafe_private_cookie_home}
            end;
        _ -> {error, launch_with_erm_user_wrapper_for_private_distribution}
    end.

start_private(Home) ->
    CookiePath = filename:join(Home, ".erlang.cookie"),
    %% Use a fresh directory per runtime. Refuse any existing cookie instead of
    %% inheriting the system service or another user's distribution authority.
    case file:open(CookiePath, [write, exclusive, raw, binary]) of
        {ok, F} ->
            Result = try
                ok = file:change_mode(CookiePath, 8#600),
                ok = file:write(F, hex(crypto:strong_rand_bytes(32))),
                file:sync(F)
            catch _:_ -> {error, cookie_creation_failed}
            after file:close(F) end,
            case Result of
                ok -> start_kernel();
                _ -> {error, private_distribution_unavailable}
            end;
        _ -> {error, unsafe_private_cookie_file}
    end.

start_kernel() ->
    application:set_env(kernel, inet_dist_use_interface, {127, 0, 0, 1}),
    application:set_env(kernel, dist_auto_connect, never),
    %% Exactly one locally generated node-name atom per VM, never peer input.
    Name = list_to_atom("erm_user_" ++ integer_to_list(erm_user_config:uid())),
    case ensure_local_epmd() of
        ok ->
            case net_kernel:start([Name, shortnames]) of
                {ok, _Pid} -> ok;
                _ -> {error, private_distribution_unavailable}
            end;
        Error -> Error
    end.

ensure_local_epmd() ->
    Epmd = filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "bin", "epmd"]),
    case filelib:is_regular(Epmd) of
        true ->
            Port = open_port({spawn_executable, Epmd},
                [binary, exit_status, stderr_to_stdout,
                 {args, ["-daemon", "-address", "127.0.0.1"]}]),
            wait_epmd(Port, erlang:monotonic_time(millisecond) + 2000);
        false -> {error, bundled_epmd_unavailable}
    end.
wait_epmd(Port, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, _}} -> {error, local_epmd_unavailable};
        {Port, {data, _}} -> wait_epmd(Port, Deadline)
    after Remaining ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        {error, local_epmd_timeout}
    end.
hex(B) -> list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= B])).
