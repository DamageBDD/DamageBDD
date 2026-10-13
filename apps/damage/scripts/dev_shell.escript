%% Evaluated inside the rebar3 shell VM before applications start.
%% A release console/remote_console does not execute this script.
main(_) ->
    {ok, Root} = file:get_cwd(),
    persistent_term:put({damage_reload, shell_root}, filename:absname(Root)),
    ok.
