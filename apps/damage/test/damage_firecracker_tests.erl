-module(damage_firecracker_tests).
-include_lib("eunit/include/eunit.hrl").

firecracker_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> fun success/0 end,
        fun(_) -> fun invalid_requests/0 end,
        fun(_) -> fun capacity_and_cancel/0 end,
        fun(_) -> fun owner_death/0 end,
        fun(_) -> fun cancellation_ownership/0 end,
        fun(_) -> fun worker_errors/0 end,
        fun(_) -> fun shutdown/0 end,
        fun(_) -> fun bdd_steps/0 end
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    Runner = filename:absname("apps/damage/test/firecracker/fake_runner.py"),
    Python = os:find_executable("python3"),
    application:set_env(damage, firecracker, [
        {enabled, true}, {launcher, Python}, {launcher_args, [Runner]},
        {profiles, [<<"shell">>]}, {max_jobs, 1}, {timeout_ms, 1000},
        {max_timeout_ms, 1000}, {max_result_bytes, 4096}
    ]),
    {ok, P} = damage_firecracker:start_link(),
    unlink(P), P.
cleanup(P) ->
    case is_process_alive(P) of true -> gen_server:stop(P); false -> ok end,
    application:unset_env(damage, firecracker),
    flush().
flush() -> receive {damage_firecracker, _, _} -> flush() after 0 -> ok end.

success() ->
    Script = <<"echo '$(touch /never-on-host)'\n">>,
    {ok, R} = damage_firecracker:run(<<"shell">>, Script),
    ?assertEqual(Script, maps:get(output, R)),
    ?assertEqual(0, maps:get(exit_code, R)),
    ?assertMatch(#{running := 0}, damage_firecracker:status()).
invalid_requests() ->
    lists:foreach(fun({Profile, Script, Opts}) ->
        ?assertEqual({error, invalid_job}, damage_firecracker:submit(Profile, Script, Opts))
    end, [
        {<<"../shell">>, <<"x">>, #{}}, {<<"unknown">>, <<"x">>, #{}},
        {<<"shell">>, <<>>, #{}}, {<<"shell">>, <<0>>, #{}},
        {<<"shell">>, binary:copy(<<"x">>, 65537), #{}},
        {<<"shell">>, <<"x">>, #{timeout_ms => 1001}},
        {<<"shell">>, <<"x">>, #{timeout_ms => -1}},
        {<<"shell">>, <<"x">>, #{rootfs => <<"/etc/shadow">>}}
    ]).
capacity_and_cancel() ->
    {ok, Id} = damage_firecracker:submit(<<"shell">>, <<"wait">>, #{}),
    ?assertEqual({error, busy}, damage_firecracker:submit(<<"shell">>, <<"x">>, #{})),
    ?assertEqual(ok, damage_firecracker:cancel(Id)),
    receive {damage_firecracker, Id, {error, cancelled}} -> ok after 2000 -> ?assert(false) end,
    ?assertMatch(#{running := 0}, damage_firecracker:status()).
owner_death() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Id} = damage_firecracker:submit(<<"shell">>, <<"wait">>, #{}),
        Parent ! {started, Id}, receive die -> ok end
    end),
    receive {started, _} -> ok after 1000 -> ?assert(false) end,
    exit(Owner, kill),
    await_empty(100).
cancellation_ownership() ->
    {ok, Id} = damage_firecracker:submit(<<"shell">>, <<"wait">>, #{}),
    Parent = self(),
    spawn(fun() -> Parent ! {other_cancel, damage_firecracker:cancel(Id)} end),
    receive {other_cancel, Result} -> ?assertEqual({error, not_owner}, Result)
    after 1000 -> ?assert(false) end,
    ?assertEqual(ok, damage_firecracker:cancel(Id)),
    receive {damage_firecracker, Id, _} -> ok after 2000 -> ?assert(false) end.
worker_errors() ->
    ?assertEqual({error, invalid_response}, damage_firecracker:run(<<"shell">>, <<"invalid">>)),
    ?assertEqual({error, launcher_failed}, damage_firecracker:run(<<"shell">>, <<"crash">>)),
    ?assertEqual({error, response_too_large}, damage_firecracker:run(<<"shell">>, <<"oversize">>)),
    ?assertMatch(#{running := 0}, damage_firecracker:status()).
shutdown() ->
    Parent = self(),
    spawn(fun() -> Parent ! {run_returned, damage_firecracker:run(<<"shell">>, <<"wait">>)} end),
    await_running(100),
    gen_server:stop(damage_firecracker),
    receive {run_returned, Result} -> ?assertEqual({error, unavailable}, Result)
    after 2000 -> ?assert(false) end.
bdd_steps() ->
    application:set_env(damage, node_admins, [<<"admin">>]),
    Admin = #{public_key => <<"admin">>},
    User = #{public_key => <<"user">>, roles => [node_admin]},
    try
        ?assert(steps_utils:step_module_allowed(steps_firecracker, Admin)),
        ?assertNot(steps_utils:step_module_allowed(steps_firecracker, User)),
        ?assertThrow(unauthorized, steps_firecracker:step([], User, <<"When">>, 1,
            ["I run a Firecracker script with profile", <<"shell">>], <<"x">>)),
        C = steps_firecracker:step([], Admin, <<"When">>, 1,
            ["I run a Firecracker script with profile", <<"shell">>], <<"hello">>),
        ?assertEqual(C, steps_firecracker:step([], C, <<"Then">>, 2,
            ["the Firecracker exit code should be", <<"0">>], <<>>)),
        ?assertEqual(C, steps_firecracker:step([], C, <<"Then">>, 3,
            ["the Firecracker output should contain", <<"hello">>], <<>>)),
        ?assertMatch(#{fail := _}, steps_firecracker:step([], C, <<"Then">>, 4,
            ["the Firecracker exit code should be", <<"7">>], <<>>))
    after application:unset_env(damage, node_admins) end.
await_empty(0) -> ?assert(false);
await_empty(N) ->
    case damage_firecracker:status() of
        #{running := 0} -> ok;
        _ -> timer:sleep(10), await_empty(N-1)
    end.
await_running(0) -> ?assert(false);
await_running(N) ->
    case damage_firecracker:status() of
        #{running := 1} -> ok;
        _ -> timer:sleep(10), await_running(N-1)
    end.

disabled_test() ->
    application:unset_env(damage, firecracker),
    ?assertEqual(ignore, damage_firecracker:start_link()),
    ?assertEqual({error, disabled}, damage_firecracker:run(<<"shell">>, <<"x">>)).
