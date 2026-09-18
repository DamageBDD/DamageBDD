%% Real BEAM loading on an isolated test node. Never run on an operator node.
%% No module mocks, public services, chain transactions, or private keys.
-module(damage_hotcode_generation_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, steps_hotcode_generation_fixture).
-define(JOURNAL, {damage_release_overrides, overrides}).
-define(WORKERS, {?MODULE, workers}).

%% The normal project EUnit run may load/start the real Damage application.
%% Only the isolated runner enables this synthetic-application fixture.
generation_identity_test_() ->
    case application:get_env(?MODULE, isolated_node, false) of
        true -> generation_cases();
        false -> []
    end.

generation_cases() ->
    {inorder, [{Name, {timeout, 60, fun() -> with_fixture(Test) end}} || {Name, Test} <- [
        {"reload records private loaded filenames", fun normal_reload/1},
        {"same-MD5 interruption before atomic_load retains A's old hash", fun before_load/1},
        {"same-MD5 interruption after atomic_load retains B's old hash", fun after_load/1},
        {"interrupted rollback recovers the old generation", fun after_base_load/1},
        {"different filename with identical code MD5 is untracked", fun untracked_filename/1},
        {"missing loaded filename is uncertain", fun missing_filename/1},
        {"conflicting hashes for one filename and MD5 are uncertain", fun conflicting_hashes/1},
        {"duplicate references to the same BEAM are not ambiguous", fun identical_candidate/1},
        {"invalid hash for a matching identity is uncertain", fun malformed_hash/1},
        {"rollback retry does not create another generation", fun repeat_rollback/1}
    ]]}.

normal_reload(_F) ->
    {A, PathA, _BeamA} = load_a(),
    ?assertEqual({file, PathA}, code:is_loaded(?M)),
    ?assertEqual(PathA, maps:get(loaded_filename, A)),
    ?assertNot(maps:is_key(candidate_filename, A)),
    S = damage_release_overrides:snapshot(),
    ?assertEqual(recorded, maps:get(runtime_integrity_status, S)),
    [Public] = maps:get(overrides, S),
    [?assertNot(maps:is_key(K, Public)) || K <-
        [base_filename, loaded_filename, candidate_filename, base_beam]],
    ?assertMatch({ok, _}, damage_hotcode:rollback(?M)),
    ?assertEqual([], damage_hotcode:status()).

before_load(F) -> same_md5_interruption(F, before_load).
after_load(F) -> same_md5_interruption(F, after_load).

same_md5_interruption(F, Phase) ->
    {A, PathA, BeamA} = load_a(),
    BeamB = metadata_variant(BeamA, candidate_b),
    PathB = cache_fixture(F, BeamB),
    ?assertNotEqual(PathA, PathB),
    Loading = loading_entry(A, PathB, BeamB),
    interrupted(fun() ->
        ok = damage_release_overrides:record(Loading),
        case Phase of
            before_load -> ok;
            after_load -> ok = code:atomic_load([{?M, PathB, BeamB}])
        end
    end),
    assert_uncertain(),
    {ExpectedPath, ExpectedSha} = case Phase of
        before_load -> {PathA, sha256(BeamA)};
        after_load -> {PathB, sha256(BeamB)}
    end,
    ?assertEqual({file, ExpectedPath}, code:is_loaded(?M)),
    %% Pin the current override so it remains old code after restoring the base.
    Parked = park(),
    assert_pending_rollback(F, ExpectedSha),
    ?assert(is_process_alive(Parked)),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?M)),
    ?assertNot(erlang:check_old_code(?M)),
    ?assertEqual([], damage_hotcode:status()).

after_base_load(F) ->
    {A, PathA, BeamA} = load_a(),
    Parked = park(),
    interrupted(fun() ->
        true = code:soft_purge(?M),
        ok = damage_release_overrides:record(A#{state => rolling_back,
            loaded_filename => PathA, loaded_beam_sha256 => sha256(BeamA)}),
        ok = code:atomic_load([{?M, maps:get(base_path, F), maps:get(base_beam, F)}])
    end),
    assert_uncertain(),
    assert_pending_rollback(F, sha256(BeamA)),
    ?assert(is_process_alive(Parked)),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?M)).

untracked_filename(F) ->
    {A, _PathA, BeamA} = load_a(),
    BeamB = metadata_variant(BeamA, untracked_b),
    PathB = cache_fixture(F, BeamB),
    true = code:soft_purge(?M),
    ok = code:atomic_load([{?M, PathB, BeamB}]),
    true = code:soft_purge(?M),
    assert_uncertain(),
    ?assertEqual({error, {untracked_current_code, ?M}}, damage_hotcode:rollback(?M)),
    ?assertEqual({error, {untracked_current_code, ?M}}, damage_hotcode:reload(?M)),
    ?assertEqual({file, PathB}, code:is_loaded(?M)),
    ?assertEqual({ok, A}, damage_release_overrides:get(?M)).

missing_filename(_F) ->
    {A, PathA, _BeamA} = load_a(),
    Legacy = maps:remove(loaded_filename, A),
    ok = damage_release_overrides:record(Legacy),
    assert_uncertain(),
    ?assertEqual({error, {untracked_current_code, ?M}}, damage_hotcode:rollback(?M)),
    ?assertEqual({error, {override_still_loaded, ?M}}, damage_release_overrides:remove(?M)),
    ?assertEqual({file, PathA}, code:is_loaded(?M)),
    ?assertEqual({ok, Legacy}, damage_release_overrides:get(?M)).

conflicting_hashes(_F) ->
    {A, PathA, BeamA} = load_a(),
    BeamB = metadata_variant(BeamA, conflicting_b),
    %% Corrupt marker: different full-BEAM hashes claim the SAME path and MD5.
    %% Do not silently pick one, even if a single alias looks plausible.
    Conflicted = (loading_entry(A, PathA, BeamB))#{state => active},
    ok = damage_release_overrides:record(Conflicted),
    assert_uncertain(),
    ?assertEqual({error, {ambiguous_current_generation, ?M}}, damage_hotcode:rollback(?M)),
    ?assertEqual({error, {ambiguous_current_generation, ?M}}, damage_hotcode:reload(?M)),
    ?assertEqual({file, PathA}, code:is_loaded(?M)),
    ?assertEqual({ok, Conflicted}, damage_release_overrides:get(?M)).

identical_candidate(_F) ->
    {A, PathA, BeamA} = load_a(),
    %% A no-op candidate can legitimately repeat the same path, MD5 and digest.
    Repeated = loading_entry(A, PathA, BeamA),
    ok = damage_release_overrides:record(Repeated),
    assert_uncertain(),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?M)),
    ?assertEqual([], damage_hotcode:status()).

malformed_hash(_F) ->
    {A, PathA, _BeamA} = load_a(),
    Bad = A#{loaded_beam_sha256 => binary:copy(<<"z">>, 64)},
    ok = damage_release_overrides:record(Bad),
    assert_uncertain(),
    ?assertEqual({error, {ambiguous_current_generation, ?M}}, damage_hotcode:rollback(?M)),
    ?assertEqual({file, PathA}, code:is_loaded(?M)).

repeat_rollback(F) ->
    {_A, _PathA, BeamA} = load_a(),
    Parked = park(),
    assert_pending_rollback(F, sha256(BeamA)),
    assert_pending_rollback(F, sha256(BeamA)),
    ?assert(is_process_alive(Parked)),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?M)),
    ?assertEqual(base, ?M:value()).

assert_pending_rollback(F, OldSha) ->
    ?assertEqual({error, rollback_loaded_but_override_still_in_use}, damage_hotcode:rollback(?M)),
    ?assertEqual(base, ?M:value()),
    ?assertEqual({file, maps:get(base_path, F)}, code:is_loaded(?M)),
    {ok, Journal} = damage_release_overrides:get(?M),
    ?assertEqual(maps:get(base_path, F), maps:get(loaded_filename, Journal)),
    ?assertEqual(OldSha, maps:get(old_beam_sha256, Journal)),
    S = damage_release_overrides:snapshot(),
    ?assertEqual(recorded, maps:get(runtime_integrity_status, S)),
    [Public] = maps:get(overrides, S),
    ?assertEqual(rollback_pending, maps:get(state, Public)),
    ?assertEqual(OldSha, maps:get(old_beam_sha256, Public)),
    ?assertEqual(sha256(maps:get(base_beam, F)), maps:get(loaded_beam_sha256, Public)),
    ?assertNotEqual(<<"unknown">>, damage_release_overrides:runtime_code_hash(S)).

assert_uncertain() ->
    S = damage_release_overrides:snapshot(),
    ?assertEqual(true, maps:get(runtime_modified, S)),
    ?assertEqual(uncertain, maps:get(runtime_integrity_status, S)),
    ?assertEqual(<<"unknown">>, damage_release_overrides:runtime_code_hash(S)).

load_a() ->
    {ok, copied, Source} = damage_hotcode:prepare(?M),
    ok = file:write_file(Source, source(override_a)),
    {ok, _} = damage_hotcode:reload(?M),
    {ok, A} = damage_release_overrides:get(?M),
    {file, PathA} = code:is_loaded(?M),
    {ok, BeamA} = file:read_file(PathA),
    ?assertEqual(sha256(BeamA), maps:get(loaded_beam_sha256, A)),
    {A, PathA, BeamA}.

%% Modify only the compilation-info chunk, not executable code. Do not depend on
%% timestamps/compiler randomness to produce different BEAMs with equal code MD5.
metadata_variant(BeamA, Label) ->
    {ok, ?M, Chunks} = beam_lib:all_chunks(BeamA),
    ?assert(lists:keymember("CInf", 1, Chunks)),
    Info = term_to_binary([{source, "generation-test.erl"}, {generation_test, Label}]),
    {ok, BeamB} = beam_lib:build_module(lists:keyreplace("CInf", 1, Chunks, {"CInf", Info})),
    ?assertEqual(beam_lib:md5(BeamA), beam_lib:md5(BeamB)),
    ?assertNotEqual(sha256(BeamA), sha256(BeamB)),
    BeamB.

loading_entry(A, Path, Beam) ->
    {ok, {?M, Md5}} = beam_lib:md5(Beam),
    A#{state => loading, candidate_filename => Path,
       candidate_module_md5 => hex(Md5), beam_sha256 => sha256(Beam)}.

cache_fixture(F, Beam) ->
    Path = filename:join([maps:get(root, F), "overrides", "beams",
        binary_to_list(sha256(Beam)), atom_to_list(?M) ++ ".beam"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Beam),
    Path.

%% Stop a writer precisely after publishing a transition marker (and optionally
%% loading code), before the success record. No production fault-injection hook.
interrupted(Operation) ->
    Parent = self(),
    Writer = spawn_worker(fun() ->
        damage_release_overrides:with_lock(fun() ->
            ok = Operation(),
            Parent ! {at_transition, self()},
            receive never -> ok end
        end)
    end),
    Ref = monitor(process, Writer),
    receive
        {at_transition, Writer} ->
            exit(Writer, kill),
            receive {'DOWN', Ref, process, Writer, killed} -> ok
            after 5000 -> error(writer_did_not_stop) end;
        {'DOWN', Ref, process, Writer, Why} -> error({transition_failed, Why})
    after 10000 ->
        demonitor(Ref, [flush]),
        error(transition_timeout)
    end.

with_fixture(Test) ->
    %% Require a fresh node so the test cannot unload real application state.
    ?assertEqual(undefined, application:get_all_key(damage)),
    ?assertEqual(undefined, whereis(damage_sup)),
    ?assertEqual(false, code:is_loaded(?M)),
    ?assertEqual([], damage_release_overrides:list()),
    SavedPath = code:get_path(),
    SavedJournal = persistent_term:get(?JOURNAL, #{}),
    SavedWorkers = put(?WORKERS, []),
    EnvKeys = [operator_hotcode, operator_source_dir],
    SavedEnv = [{K, application:get_env(damage, K)} || K <- EnvKeys],
    Temp = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Root = filename:join(Temp, "damage-generation-test-" ++ binary_to_list(hex(crypto:strong_rand_bytes(12)))),
    App = filename:join(Root, "damage-0.0.0"),
    Ebin = filename:join(App, "ebin"),
    Src = filename:join(App, "src"),
    Operator = filename:join([Root, "overrides", "src"]),
    [ok = filelib:ensure_dir(filename:join(D, "unused")) || D <- [Ebin, Src, Operator]],
    try
        true = code:replace_path(damage, Ebin),
        ok = application:load({application, damage, [{vsn, "0.0.0"},
            {description, "isolated generation test"}, {modules, [?M]},
            {registered, []}, {applications, [kernel, stdlib]}]}),
        ok = application:set_env(damage, operator_source_dir, Operator),
        ok = application:set_env(damage, operator_hotcode,
            [{enabled, true}, {allowed_modules, [?M]}]),
        Source = filename:join(Src, atom_to_list(?M) ++ ".erl"),
        ok = file:write_file(Source, source(base)),
        {ok, ?M, BaseBeam} = compile:noenv_file(Source, [binary, debug_info]),
        BasePath = filename:join(Ebin, atom_to_list(?M) ++ ".beam"),
        ok = file:write_file(BasePath, BaseBeam),
        {module, ?M} = code:load_binary(?M, BasePath, BaseBeam),
        ?assertEqual(Src, code:lib_dir(damage, src)),
        Test(#{root => Root, base_beam => BaseBeam, base_path => BasePath})
    after
        [stop_worker(P) || P <- get(?WORKERS)],
        %% Destructive cleanup is limited to our single test-owned module.
        code:soft_purge(?M), code:delete(?M), code:soft_purge(?M),
        persistent_term:put(?JOURNAL, SavedJournal),
        application:unload(damage),
        true = code:set_path(SavedPath),
        [restore_env(K, V) || {K, V} <- SavedEnv],
        put(?WORKERS, SavedWorkers),
        file:del_dir_r(Root)
    end.

source(Value) ->
    iolist_to_binary(io_lib:format(
        "-module(~p).\n-export([value/0, park/1]).\nvalue() -> ~p.\n"
        "park(Parent) -> Parent ! {parked, self()}, receive stop -> value() end.\n", [?M, Value])).

restore_env(K, undefined) -> application:unset_env(damage, K);
restore_env(K, {ok, V}) -> application:set_env(damage, K, V).
spawn_worker(Fun) ->
    Pid = spawn(Fun),
    put(?WORKERS, [Pid | get(?WORKERS)]),
    Pid.
stop_worker(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> error(worker_did_not_stop) end.
park() ->
    Parent = self(),
    Pid = spawn_worker(fun() -> ?M:park(Parent) end),
    receive {parked, Pid} -> Pid after 5000 -> error(park_timeout) end.
sha256(B) -> hex(crypto:hash(sha256, B)).
hex(B) -> string:lowercase(binary:encode_hex(B)).
