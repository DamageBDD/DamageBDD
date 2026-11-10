-module(ecai_aws_setup_runtime_tests).
-include_lib("eunit/include/eunit.hrl").

settings_test() ->
    with_env(fun() ->
        application:set_env(ecai, aws_setup_bootstrap_python, "/bin/sh"),
        application:set_env(ecai, aws_setup_python, auto),
        application:set_env(ecai, aws_setup_runtime_dir, "/tmp/ecai-runtime-settings-only"),
        application:set_env(ecai, aws_setup_runtime_auto_install, true),
        {ok, "/bin/sh", Managed} = ecai_aws_setup_runtime:settings(),
        ?assertEqual(<<"managed">>, maps:get(<<"mode">>, Managed)),
        ?assertEqual(<<"/tmp/ecai-runtime-settings-only">>, maps:get(<<"root">>, Managed)),
        application:set_env(ecai, aws_setup_python, "/operator/environment/bin/python"),
        {ok, _, External} = ecai_aws_setup_runtime:settings(),
        ?assertEqual(<<"external">>, maps:get(<<"mode">>, External)),
        ?assertNot(maps:is_key(<<"install">>, External)),
        application:set_env(ecai, aws_setup_runtime_timeout_seconds, 2),
        ?assertEqual({error, <<"invalid_runtime_settings">>}, ecai_aws_setup_runtime:settings())
    end).

runtime_lifecycle_test_() ->
    {timeout, 15, fun() -> with_env(fun() ->
        ?assertEqual(undefined, whereis(ecai_aws_setup_runtime)),
        Dir = filename:join("/tmp", "ecai-runtime-eunit-" ++ integer_to_list(erlang:unique_integer([positive]))),
        ok = file:make_dir(Dir),
        Helper = filename:join(Dir, "fixture-helper"),
        %% Protocol fixture only; not a package installation or SDK verification.
        %% It deliberately ignores runtime.py arguments to test OTP state changes.
        ok = file:write_file(Helper, <<"#!/bin/sh\nread -r settings\nprintf '%s\\n' '{\"phase\":\"checking\"}'\nprintf '%s\\n' '{\"phase\":\"ready\",\"ok\":true,\"mode\":\"managed\",\"python\":\"/bin/false\",\"versions\":{\"python\":\"fixture\",\"boto3\":\"fixture\"},\"reused\":true}'\n">>),
        ok = file:change_mode(Helper, 8#700),
        application:set_env(ecai, aws_setup_enabled, false),
        application:set_env(ecai, aws_setup_bootstrap_python, Helper),
        application:set_env(ecai, aws_setup_python, auto),
        application:set_env(ecai, aws_setup_runtime_dir, filename:join(Dir, "envs")),
        {ok, Pid} = ecai_aws_setup_runtime:start_link(),
        try
            wait_phase(<<"disabled">>, 100),
            ?assertEqual(false, ecai_aws_setup_runtime:python()),
            ?assertNot(filelib:is_dir(filename:join(Dir, "envs"))),
            application:set_env(ecai, aws_setup_enabled, true),
            ?assertEqual(false, ecai_aws_setup_runtime:python()),
            ecai_aws_setup_runtime:recheck(),
            wait_phase(<<"ready">>, 100),
            ?assertEqual("/bin/false", ecai_aws_setup_runtime:python()),
            ?assertNot(maps:is_key(<<"python">>, ecai_aws_setup_runtime:public())),
            application:set_env(ecai, aws_setup_runtime_auto_install, false),
            ?assertEqual(false, ecai_aws_setup_runtime:python()),
            ?assertEqual(<<"pending">>, maps:get(<<"phase">>, ecai_aws_setup_runtime:status())),
            application:set_env(ecai, aws_setup_enabled, false),
            ecai_aws_setup_runtime:recheck(),
            wait_phase(<<"disabled">>, 100)
        after gen_server:stop(Pid), file:del_dir_r(Dir) end
    end) end}.

failure_does_not_crash_node_test_() ->
    {timeout, 10, fun() -> with_env(fun() ->
        ?assertEqual(undefined, whereis(ecai_aws_setup_runtime)),
        application:set_env(ecai, aws_setup_enabled, true),
        application:set_env(ecai, aws_setup_bootstrap_python, "/definitely-not-installed/python"),
        {ok, Pid} = ecai_aws_setup_runtime:start_link(),
        try
            wait_phase(<<"failed">>, 100),
            ?assert(is_process_alive(Pid)),
            ?assertEqual(false, ecai_aws_setup_runtime:python()),
            S = ecai_aws_setup_runtime:status(),
            ?assertEqual(<<"bootstrap_python_missing">>, maps:get(<<"error">>, S)),
            ?assert(maps:get(<<"next_check_at_ms">>, S) > erlang:system_time(millisecond))
        after gen_server:stop(Pid) end
    end) end}.

wait_phase(Phase, N) when N > 0 ->
    case maps:get(<<"phase">>, ecai_aws_setup_runtime:status()) of
        Phase -> ok;
        _ -> timer:sleep(20), wait_phase(Phase, N - 1)
    end;
wait_phase(Phase, 0) -> ?assertEqual(Phase, maps:get(<<"phase">>, ecai_aws_setup_runtime:status())).

with_env(Fun) ->
    Keys = [aws_setup_enabled, aws_setup_python, aws_setup_bootstrap_python,
        aws_setup_runtime_dir, aws_setup_runtime_auto_install,
        aws_setup_runtime_timeout_seconds, aws_setup_wheelhouse],
    Previous = [{K, application:get_env(ecai, K)} || K <- Keys],
    lists:foreach(fun(K) -> application:unset_env(ecai, K) end, Keys),
    try Fun() after
        lists:foreach(fun({K, undefined}) -> application:unset_env(ecai, K);
                         ({K, {ok, V}}) -> application:set_env(ecai, K, V) end, Previous)
    end.
