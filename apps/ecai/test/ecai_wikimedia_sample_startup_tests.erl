%% Run in an isolated EUnit VM, not in a production node shell.
-module(ecai_wikimedia_sample_startup_tests).
-behaviour(supervisor).
-export([init/1]).
-include_lib("eunit/include/eunit.hrl").

registered_options_child_spec_test() ->
    Opts = #{port => 0},
    Spec = ecai_wikimedia_fixture_server:child_spec(Opts),
    ?assertEqual({ecai_wikimedia_fixture_server, start_link_registered, [Opts]},
        maps:get(start, Spec)),
    ?assertEqual(permanent, maps:get(restart, Spec)).

cold_sample_and_restart_test_() ->
    {timeout, 45, fun cold_sample_and_restart/0}.

cold_sample_and_restart() ->
    ?assertEqual(undefined, whereis(ecai_sup)),
    ?assertEqual(undefined, whereis(ecai_wikimedia_fixture_server)),
    Dir = filename:join(temp_dir(), "ecai-sample-startup-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    Keys = [wikimedia_fixture_runtime_dir, wikimedia_fixture_dir,
        wikimedia_fixture_ip, wikimedia_fixture_public_host],
    Previous = [{K, application:get_env(ecai, K)} || K <- Keys],
    ok = application:set_env(ecai, wikimedia_fixture_runtime_dir, Dir),
    ok = application:set_env(ecai, wikimedia_fixture_dir, fixture_dir()),
    ok = application:set_env(ecai, wikimedia_fixture_ip, {127, 0, 0, 1}),
    ok = application:set_env(ecai, wikimedia_fixture_public_host, <<"127.0.0.1">>),
    {ok, Sup} = supervisor:start_link({local, ecai_sup}, ?MODULE, []),
    unlink(Sup),
    try
        %% This is the exact cold preset path that previously returned
        %% {wikimedia_fixture_catalog_unavailable, not_running}.
        {ok, Path, Catalog} = ecai_wikimedia_sample:catalog(),
        ?assert(filelib:is_regular(Path)),
        ?assert(is_map(Catalog)),
        First = whereis(ecai_wikimedia_fixture_server),
        ?assert(is_pid(First)),
        ?assertMatch({ok, _}, ecai_wikimedia_fixture_server:catalog_path()),
        ?assertMatch(#{ready := true}, ecai_wikimedia_fixture_server:status()),
        ?assertMatch({ok, #{ready := true}}, ecai_wikimedia_sample:status()),
        ?assertEqual(ok, ecai_wikimedia_sample:ensure_started()),
        ?assertEqual(First, whereis(ecai_wikimedia_fixture_server)),
        %% Concurrent browser catalog/status requests must not share .tmp paths.
        Parent = self(),
        Refs = [begin
            Ref = make_ref(),
            spawn(fun() -> Parent ! {Ref, ecai_wikimedia_sample:catalog()} end),
            Ref
        end || _ <- lists:seq(1, 5)],
        lists:foreach(fun(Ref) ->
            receive {Ref, Result} -> ?assertMatch({ok, _, _}, Result)
            after 10000 -> erlang:error(catalog_call_timeout)
            end
        end, Refs),
        ok = gen_server:stop(First, fixture_restart_test, 5000),
        Second = await_restart(First, 200),
        ?assert(Second =/= First),
        ?assertMatch({ok, _, _}, ecai_wikimedia_sample:catalog()),
        ?assertMatch({ecai_wikimedia_fixture_server, Second, worker, _},
            lists:keyfind(ecai_wikimedia_fixture_server, 1, supervisor:which_children(Sup)))
    after
        ok = gen_server:stop(Sup),
        lists:foreach(fun
            ({K, {ok, V}}) -> application:set_env(ecai, K, V);
            ({K, undefined}) -> application:unset_env(ecai, K)
        end, Previous),
        _ = file:del_dir_r(Dir)
    end.

init([]) -> {ok, {{one_for_one, 5, 10}, []}}.
await_restart(_Old, 0) -> erlang:error(fixture_restart_timeout);
await_restart(Old, Attempts) ->
    case whereis(ecai_wikimedia_fixture_server) of
        Pid when is_pid(Pid), Pid =/= Old ->
            %% A synchronous status call also waits for init/1 to finish.
            #{ready := true} = ecai_wikimedia_fixture_server:status(Pid),
            Pid;
        _ -> timer:sleep(20), await_restart(Old, Attempts - 1)
    end.
fixture_dir() ->
    case code:priv_dir(ecai) of
        {error, bad_name} -> filename:absname("apps/ecai/priv/wikimedia-fixtures");
        Priv -> filename:join(Priv, "wikimedia-fixtures")
    end.
temp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end.
