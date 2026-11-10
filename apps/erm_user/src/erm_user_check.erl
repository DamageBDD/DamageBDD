%% Fixed host-side grant check without starting the desktop, Damage, or a
%% distributed node. Only the authenticated public status result is printed.
-module(erm_user_check).
-export([main/0]).
main() ->
    try run() catch _:_ -> fail(check_failed) end.

run() ->
    application:ensure_all_started(crypto),
    case load_configuration() of
        ok ->
            Options = maps:from_list(application:get_all_env(erm_user)),
            case erm_user_bridge:request(status, Options) of
                {ok, Result} ->
                    io:format("~s~n", [jsx:encode(Result)]),
                    halt(0);
                {error, Reason} -> fail(Reason)
            end;
        {error, Reason} -> fail(Reason)
    end.

load_configuration() ->
    Path = case os:getenv("ERM_USER_CONFIG") of
        false -> filename:join([erm_user_config:config_home(), "erm", "user.config"]);
        P -> P
    end,
    erm_user_config:load_user_config(Path).

%% Client/configuration errors are local fixed atoms, never peer-supplied
%% strings. The check has no diagnostic option that reveals the bearer.
fail(Reason) ->
    Safe = case Reason of
        unauthorized -> unauthorized;
        forbidden -> forbidden;
        unavailable -> unavailable;
        timeout -> timeout;
        unsafe_credential -> unsafe_credential;
        invalid_credential -> invalid_credential;
        credential_unreadable -> credential_unreadable;
        unsafe_socket_directory -> unsafe_socket_directory;
        unsafe_socket_path -> unsafe_socket_path;
        untrusted_socket -> untrusted_socket;
        unknown_bridge_server_user -> unknown_bridge_server_user;
        invalid_bridge_configuration -> invalid_bridge_configuration;
        unsafe_file_permissions -> unsafe_file_permissions;
        unsafe_file -> unsafe_file;
        unsafe_user_path -> unsafe_user_path;
        forbidden_user_config_application -> forbidden_user_config_application;
        invalid_user_config -> invalid_user_config;
        user_config_unreadable -> user_config_unreadable;
        _ -> check_failed
    end,
    io:format(standard_error, "Damage bridge check failed: ~p~n", [Safe]),
    halt(1).
