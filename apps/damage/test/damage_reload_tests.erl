-module(damage_reload_tests).
-include_lib("eunit/include/eunit.hrl").

release_default_disabled_test() ->
    ?assertEqual(disabled, damage_reload_config:normalize([], undefined)),
    ?assertEqual(disabled, damage_reload_config:normalize([{enabled, dev}], undefined)),
    ?assertEqual(disabled, damage_reload_config:normalize([{enabled, false}], "/tmp")),
    ?assertMatch({error, _}, damage_reload_config:normalize(#{enabled => true}, undefined)),
    ?assertMatch(
        {error, _}, damage_reload_config:normalize([{enabled, true}, {enabled, false}], undefined)
    ),
    ?assertMatch({error, _}, damage_reload_config:normalize([{enable, true}], undefined)).

source_allowlist_required_test() ->
    with_dir(fun(Dir) ->
        Base = [{enabled, true}, {mode, sources}, {source_dirs, [Dir]}],
        ?assertMatch({error, _}, damage_reload_config:normalize(Base, undefined)),
        ?assertMatch(
            {ok, _},
            damage_reload_config:normalize(Base ++ [{modules, [reload_fixture_a]}], undefined)
        ),
        ?assertMatch(
            {error, _},
            damage_reload_config:normalize(Base ++ [{modules, [damage_reload]}], undefined)
        ),
        ?assertMatch(
            {error, _},
            damage_reload_config:normalize(
                Base ++ [{modules, [reload_fixture_a]}, {retry_ms, 0}], undefined
            )
        )
    end).

path_components_test() ->
    ?assert(damage_reload_config:within("/tmp/src/a.erl", "/tmp/src")),
    ?assertNot(damage_reload_config:within("/tmp/src-extra/a.erl", "/tmp/src")),
    ?assertError({absolute_path_required, "src"}, damage_reload_config:path("src")).

symlink_parent_resolution_test() ->
    with_dir(fun(Dir) ->
        Outside = filename:join(Dir, "outside"),
        Root = filename:join(Dir, "root"),
        Child = filename:join(Outside, "child"),
        ok = file:make_dir(Outside),
        ok = file:make_dir(Root),
        ok = file:make_dir(Child),
        Link = filename:join(Root, "link"),
        ok = file:make_symlink(Child, Link),
        ?assertEqual(Outside, damage_reload_config:path(Link ++ "/.."))
    end).

compile_failure_retains_entire_batch_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a, reload_fixture_b]),
        write_module(Dir, reload_fixture_a, 1),
        write_module(Dir, reload_fixture_b, 1),
        {candidate, Fp, Objects} = damage_reload_build:prepare(Cfg, undefined, none, true),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, Objects)),
        write_module(Dir, reload_fixture_a, 2),
        ok = file:write_file(filename:join(Dir, "reload_fixture_b.erl"), <<"not erlang!\n">>),
        ?assertMatch({failed, _, _}, damage_reload_build:prepare(Cfg, Fp, none, false)),
        ?assertEqual(1, reload_fixture_a:value()),
        ?assertEqual(1, reload_fixture_b:value())
    end).

header_change_recompiles_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a]),
        Header = filename:join(Dir, "value.hrl"),
        Source = filename:join(Dir, "reload_fixture_a.erl"),
        ok = file:write_file(Header, <<"-define(VALUE, 1).\n">>),
        ok = file:write_file(
            Source,
            <<"-module(reload_fixture_a).\n-include(\"value.hrl\").\n-export([value/0]).\nvalue() -> ?VALUE.\n">>
        ),
        {candidate, Fp1, O1} = damage_reload_build:prepare(Cfg, undefined, none, true),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O1)),
        ok = file:write_file(Header, <<"-define(VALUE, 2).\n">>),
        {candidate, Fp2, O2} = damage_reload_build:prepare(Cfg, Fp1, none, false),
        ?assertNotEqual(Fp1, Fp2),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O2)),
        ?assertEqual(2, reload_fixture_a:value()),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.beam")))
    end).

on_load_is_not_executed_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a, reload_fixture_b]),
        write_module(Dir, reload_fixture_a, 1),
        write_module(Dir, reload_fixture_b, 1),
        {candidate, Fp, O1} = damage_reload_build:prepare(Cfg, undefined, none, true),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O1)),
        write_module(Dir, reload_fixture_a, 2),
        ok = file:write_file(
            filename:join(Dir, "reload_fixture_b.erl"),
            <<
                "-module(reload_fixture_b).\n-on_load(init/0).\n-export([value/0]).\n"
                "init() -> persistent_term:put(reload_fixture_on_load, ran), ok.\nvalue() -> 2.\n"
            >>
        ),
        {candidate, _, O2} = damage_reload_build:prepare(Cfg, Fp, none, false),
        ?assertMatch({error, _}, damage_reload_build:publish(Cfg, O2)),
        ?assertEqual(not_run, persistent_term:get(reload_fixture_on_load, not_run)),
        ?assertEqual(1, reload_fixture_a:value()),
        ?assertEqual(1, reload_fixture_b:value())
    end).

busy_old_code_defers_atomic_batch_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a, reload_fixture_b]),
        write_module(Dir, reload_fixture_a, 1),
        write_module(Dir, reload_fixture_b, 1),
        {candidate, _, O1} = damage_reload_build:prepare(Cfg, undefined, none, true),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O1)),
        Parent = self(),
        {Pid, Mon} = spawn_monitor(fun() -> reload_fixture_a:hold(Parent) end),
        receive
            {holding, Pid} -> ok
        after 1000 -> error(fixture_did_not_start)
        end,
        try
            write_module(Dir, reload_fixture_a, 2),
            {candidate, _, O2} = damage_reload_build:prepare(Cfg, undefined, none, true),
            ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O2)),
            write_module(Dir, reload_fixture_a, 3),
            write_module(Dir, reload_fixture_b, 2),
            {candidate, Fp3, O3} = damage_reload_build:prepare(Cfg, undefined, none, true),
            ?assertMatch({deferred, [reload_fixture_a]}, damage_reload_build:publish(Cfg, O3)),
            ?assert(is_process_alive(Pid)),
            ?assertEqual(2, reload_fixture_a:value()),
            ?assertEqual(1, reload_fixture_b:value()),
            Pid ! stop,
            receive
                {'DOWN', Mon, process, Pid, normal} -> ok
            after 1000 -> error(fixture_did_not_stop)
            end,
            ?assertEqual(
                {candidate, Fp3, O3}, damage_reload_build:prepare(Cfg, Fp3, {Fp3, O3}, false)
            ),
            ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O3)),
            ?assertEqual(3, reload_fixture_a:value()),
            ?assertEqual(2, reload_fixture_b:value())
        after
            Pid ! stop,
            receive
                {'DOWN', Mon, process, Pid, _} -> ok
            after 20 -> ok
            end
        end
    end).

newer_edit_supersedes_deferred_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a]),
        write_module(Dir, reload_fixture_a, 1),
        {candidate, Fp1, O1} = damage_reload_build:prepare(Cfg, undefined, none, true),
        write_module(Dir, reload_fixture_a, 2),
        {candidate, Fp2, O2} = damage_reload_build:prepare(Cfg, Fp1, {Fp1, O1}, false),
        ?assertNotEqual(Fp1, Fp2),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O2)),
        ?assertEqual(2, reload_fixture_a:value())
    end).

unlisted_module_cannot_be_published_test() ->
    with_dir(fun(Dir) ->
        Both = config(Dir, [reload_fixture_a, reload_fixture_b]),
        OnlyA = config(Dir, [reload_fixture_a]),
        write_module(Dir, reload_fixture_a, 1),
        write_module(Dir, reload_fixture_b, 1),
        {candidate, _, Objects} = damage_reload_build:prepare(Both, undefined, none, true),
        ?assertMatch({error, _}, damage_reload_build:publish(OnlyA, Objects)),
        ?assertEqual(false, code:is_loaded(reload_fixture_a)),
        ?assertEqual(false, code:is_loaded(reload_fixture_b))
    end).

missing_source_does_not_unload_test() ->
    with_dir(fun(Dir) ->
        Cfg = config(Dir, [reload_fixture_a]),
        write_module(Dir, reload_fixture_a, 1),
        {candidate, Fp, O} = damage_reload_build:prepare(Cfg, undefined, none, true),
        ?assertMatch({ok, _}, damage_reload_build:publish(Cfg, O)),
        ok = file:delete(filename:join(Dir, "reload_fixture_a.erl")),
        ?assertMatch({failed, _, _}, damage_reload_build:prepare(Cfg, Fp, none, false)),
        ?assertEqual(1, reload_fixture_a:value())
    end).

config(Dir, Modules) ->
    {ok, Cfg} = damage_reload_config:normalize(
        [
            {enabled, true},
            {mode, sources},
            {source_dirs, [Dir]},
            {include_dirs, [Dir]},
            {modules, Modules},
            {reuse_compile_opts, false}
        ],
        undefined
    ),
    Cfg.

write_module(Dir, M, Value) ->
    Body = io_lib:format(
        "-module(~p).\n-export([value/0, hold/1]).\nvalue() -> ~p.\n"
        "hold(P) -> P ! {holding, self()}, wait().\n"
        "wait() -> receive stop -> ok; _ -> wait() end.\n",
        [M, Value]
    ),
    ok = file:write_file(filename:join(Dir, atom_to_list(M) ++ ".erl"), Body).

with_dir(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    Dir = filename:join(
        "/tmp",
        "damage-reload-test-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = file:make_dir(Dir),
    try
        Fun(Dir)
    after
        lists:foreach(
            fun(M) ->
                true = code:soft_purge(M),
                _ = code:delete(M),
                true = code:soft_purge(M)
            end,
            [reload_fixture_a, reload_fixture_b]
        ),
        persistent_term:erase(reload_fixture_on_load),
        ok = file:del_dir_r(Dir)
    end.
