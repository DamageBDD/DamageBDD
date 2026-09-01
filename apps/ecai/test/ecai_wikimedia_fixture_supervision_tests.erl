-module(ecai_wikimedia_fixture_supervision_tests).
-behaviour(supervisor).

-export([init/1]).

-include_lib("eunit/include/eunit.hrl").

managed_child_restarts_under_supervisor_test_() ->
    {timeout, 30, fun managed_child_restarts_under_supervisor_test/0}.

managed_child_restarts_under_supervisor_test() ->
    with_tmp(fun(BaseDir) ->
        FixtureDir = filename:join(BaseDir, "fixtures"),
        RuntimeDir = filename:join(BaseDir, "runtime"),
        ok = copy_fixture_files(fixture_dir(), FixtureDir),
        Port = free_port(),
        Opts = #{
            listener_ref => ecai_wikimedia_fixture_http_supervision_test,
            ip => {127, 0, 0, 1},
            port => Port,
            public_host => <<"127.0.0.1">>,
            fixture_dir => FixtureDir,
            runtime_dir => RuntimeDir,
            allow_non_loopback => false
        },
        {ok, SupPid} = supervisor:start_link(?MODULE, []),
        unlink(SupPid),
        try
            ok = ecai_wikimedia_fixture_server:start_supervised(
                SupPid,
                Opts
            ),
            Child1 = child_pid(SupPid),
            ?assert(is_pid(Child1)),
            ?assertEqual(
                true,
                maps:get(
                    ready,
                    ecai_wikimedia_fixture_server:status(Child1)
                )
            ),

            %% An abnormal, graceful gen_server stop runs terminate/2, closes
            %% the listener, and lets the permanent child restart cleanly.
            ok = gen_server:stop(Child1, fixture_test_crash, 5000),
            Child2 = wait_for_restarted_child(SupPid, Child1, 100),
            ?assert(Child2 =/= Child1),
            ?assertEqual(
                true,
                maps:get(
                    ready,
                    ecai_wikimedia_fixture_server:status(Child2)
                )
            )
        after
            _ = supervisor:terminate_child(
                SupPid,
                ecai_wikimedia_fixture_server
            ),
            _ = supervisor:delete_child(
                SupPid,
                ecai_wikimedia_fixture_server
            ),
            exit(SupPid, kill)
        end
    end).

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.

child_pid(SupPid) ->
    case
        lists:keyfind(
            ecai_wikimedia_fixture_server,
            1,
            supervisor:which_children(SupPid)
        )
    of
        {ecai_wikimedia_fixture_server, Pid, worker, _Modules} when
            is_pid(Pid)
        ->
            Pid;
        Other ->
            erlang:error({fixture_child_not_running, Other})
    end.

wait_for_restarted_child(_SupPid, _OldPid, 0) ->
    erlang:error(fixture_child_restart_timeout);
wait_for_restarted_child(SupPid, OldPid, Attempts) ->
    Result =
        try child_pid(SupPid) of
            Pid -> {ok, Pid}
        catch
            error:_Reason -> not_ready
        end,
    case Result of
        {ok, Pid0} when is_pid(Pid0), Pid0 =/= OldPid ->
            Pid0;
        _ ->
            timer:sleep(20),
            wait_for_restarted_child(SupPid, OldPid, Attempts - 1)
    end.

copy_fixture_files(SourceDir, DestinationDir) ->
    ok = filelib:ensure_dir(filename:join(DestinationDir, "x")),
    Names = [
        "pageviews-202606-user.bz2",
        "enwiki_content-20260720-00000.json.bz2"
    ],
    lists:foreach(
        fun(Name) ->
            {ok, _Bytes} = file:copy(
                filename:join(SourceDir, Name),
                filename:join(DestinationDir, Name)
            )
        end,
        Names
    ),
    ok.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true}
    ]),
    {ok, {_Address, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

fixture_dir() ->
    case code:priv_dir(ecai) of
        {error, bad_name} ->
            filename:join(["apps", "ecai", "priv", "wikimedia-fixtures"]);
        PrivDir ->
            filename:join(PrivDir, "wikimedia-fixtures")
    end.

with_tmp(Fun) ->
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Dir = filename:join(temp_dir(), "ecai-fixture-supervision-" ++ Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try
        Fun(Dir)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    lists:foreach(
                        fun(Name) -> remove_tree(filename:join(Path, Name)) end,
                        Names
                    );
                {error, _Reason0} ->
                    ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _Info} ->
            _ = file:delete(Path),
            ok;
        {error, _Reason1} ->
            ok
    end.
