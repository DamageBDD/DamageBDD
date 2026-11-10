%% Evaluated inside the rebar3 shell VM before applications start.
%% A release console/remote_console does not execute this script.
main(_) ->
    %% Desktop ERM runs in its own per-user development VM. Keep code on the
    %% umbrella path, but suppress embedded desktop workers in this VM even if
    %% a legacy caller explicitly starts the erm application later.
    persistent_term:put({erm, damage_dev_shell}, true),
    ok = application:set_env(erm, enabled, false, [{persistent, true}]),
    {ok, Root} = file:get_cwd(),
    persistent_term:put({damage_reload, shell_root}, filename:absname(Root)),
    ok.
