%% -------------------------------------------------------------------
%% damage_priv.erl
%% Privileged command runner with platform UI elevation.
%%  - Linux: prefers pkexec; falls back to sudo -A with zenity/kdialog/ssh-askpass
%%  - macOS: uses osascript (admin privileges dialog)
%%  - Windows: noop (return {error, unsupported}) — adjust if needed
%% -------------------------------------------------------------------
-module(damage_priv).
-include_lib("kernel/include/logger.hrl").
-export([sudo_ui/1, permission_denied/1]).

%% @doc Run a shell command with UI elevation, returning exec:run/2 result.
sudo_ui(Cmd) when is_list(Cmd) ->
    case os:type() of
        {unix, linux} -> linux_elevate(Cmd);
        {unix, darwin} -> macos_elevate(Cmd);
        {win32, _} -> {error, unsupported};
        _ -> {error, unsupported}
    end.

%% @doc True if stderr/stdout contains a clear “permission denied” marker
permission_denied(Out) when is_binary(Out) -> permission_denied(binary_to_list(Out));
permission_denied(Out) when is_list(Out) ->
    Lower = string:lowercase(Out),
    lists:any(fun(P) -> lists:member(P, Lower) end,
              ["permission denied", "operation not permitted", "not permitted", "eprem"])
    orelse false.

%% ---- Linux ---------------------------------------------------------

linux_elevate(Cmd) ->
    ShCmd = lists:flatten(io_lib:format("sh -c '~s'", [escape_single_quotes(Cmd)])),
    case os:find_executable("pkexec") of
        false ->
            sudo_with_askpass(ShCmd);
        Pkexec ->
            exec:run(Pkexec ++ " " ++ ShCmd, [sync, stdout, stderr])
    end.

sudo_with_askpass(ShCmd) ->
    case find_askpass() of
        undefined ->
            ?LOG_WARNING("No pkexec/askpass UI found; cannot elevate."),
            {error, no_askpass};
        AskPass ->
            %% Use sudo -A with temporary ASKPASS script if needed
            Cmd = "env SUDO_ASKPASS=" ++ AskPass ++ " sudo -A " ++ ShCmd,
            exec:run(Cmd, [sync, stdout, stderr])
    end.

find_askpass() ->
    case os:find_executable("ssh-askpass") of
        false ->
            case os:find_executable("zenity") of
                false ->
                    case os:find_executable("kdialog") of
                        false -> build_inline_askpass();  %% last resort tiny script
                        KDia  -> make_wrapper(fun(Prompt) ->
                                   KDia ++ " --password \"" ++ Prompt ++ "\""
                                 end)
                    end;
                Zen  -> make_wrapper(fun(Prompt) ->
                           Zen ++ " --password --title=\"Authentication Required\" --text=\"" ++ Prompt ++ "\""
                         end)
            end;
        Ask -> Ask
    end.

%% Build a tiny askpass script backed by /usr/bin/tty + read -s (console prompt).
build_inline_askpass() ->
    case os:find_executable("mktemp") of
        false -> undefined;
        _ ->
            {ok, Tmp} = make_temp_script(
              "#!/bin/sh\n" ++
              "prompt=\"$1\"; export LC_ALL=C\n" ++
              "if command -v zenity >/dev/null 2>&1; then zenity --password --title=\"Authentication Required\" --text=\"$prompt\"; exit $?; fi\n" ++
              "if command -v kdialog >/dev/null 2>&1; then kdialog --password \"$prompt\"; exit $?; fi\n" ++
              "if [ -t 0 ]; then printf \"%s\" \"$prompt\" 1>&2; stty -echo; read pass; stty echo; echo \"$pass\"; exit 0; fi\n" ++
              "exit 1\n"),
            Tmp
    end.

make_wrapper(Build) ->
    PromptCmd = Build("Password for privilege escalation:"),
    make_temp_script("#!/bin/sh\n" ++ PromptCmd ++ "\n").

make_temp_script(Body) ->
    Tmp = filename:join("/tmp", "damage-askpass-" ++ integer_to_list(erlang:phash2(self())) ++ ".sh"),
    ok = file:write_file(Tmp, Body),
    ok = file:change_mode(Tmp, 8#700),
    {ok, Tmp}.

escape_single_quotes(S) ->
    %% ' -> '"'"' (classic shell escaping)
    re:replace(S, "'", "'\"'\"'", [global, {return, list}]).

%% ---- macOS ---------------------------------------------------------

macos_elevate(Cmd) ->
    case os:find_executable("osascript") of
        false -> {error, no_osascript};
        Osa ->
            Apple = "osascript -e 'do shell script " ++
                    "\"" ++ escape_applescript(Cmd) ++ "\"" ++
                    " with administrator privileges'",
            exec:run(Apple, [sync, stdout, stderr])
    end.

escape_applescript(S) ->
    %% escape \" and \\
    re:replace(S, "[\\\\\"]", "\\\\&", [global, {return, list}]).
