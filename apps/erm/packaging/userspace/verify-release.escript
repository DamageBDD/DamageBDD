#!/usr/bin/env escript
%%! -noshell
%% Verify the generated boot graph, not only the requested relx goals.
main([Root]) ->
    try
        {ok, Data} = file:read_file(filename:join([Root, "releases", "start_erl.data"])),
        [_Erts, Vsn] = string:lexemes(binary_to_list(Data), " \t\r\n"),
        Script = filename:join([Root, "releases", Vsn, "start.script"]),
        {ok, [{script, {_, _}, Instructions}]} = file:consult(Script),
        Started = lists:usort(lists:filtermap(fun started_app/1, Instructions)),
        %% Fail closed if a future dependency accidentally pulls a system
        %% service into the desktop boot graph. Review new local dependencies
        %% explicitly instead of accepting every app except today's services.
        Allowed = [kernel, stdlib, sasl, crypto, inets, ssl, asn1, public_key,
                   jsx, gproc, erlexec, cowboy, cowlib, ranch, trails,
                   cowboy_swagger, erm_user],
        [] = Started -- Allowed,
        true = lists:member(erm_user, Started),
        true = filelib:is_regular(filename:join([Root, "bin", "erm-user"])),
        io:format("ERM userspace boot graph verified; started apps: ~p~n", [Started])
    catch
        Class:Reason ->
            io:format(standard_error, "ERM userspace release verification failed: ~p:~p~n", [Class, Reason]),
            halt(1)
    end;
main(_) ->
    io:format(standard_error, "usage: verify-release.escript RELEASE_DIRECTORY~n", []),
    halt(64).

started_app({apply, {application, Start, [App | _]}})
    when Start =:= start_boot; Start =:= start -> {true, App};
started_app(_) -> false.
