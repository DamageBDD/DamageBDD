%% Standalone OTP/EUnit regressions: synthetic damage application and real
%% compilation/code loading. No mocks, network services, secrets or payments.
-module(damage_hotcode_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, steps_hotcode_fixture_a).
-define(B, steps_hotcode_fixture_b).
-define(JOURNAL, {damage_release_overrides, overrides}).

hardening_test_() ->
    [{Name, {timeout, 60, fun() -> with_fixture(Test) end}} || {Name, Test} <- [
        {"explicit allowlist and protected core", fun policy/1},
        {"prepare never replaces operator edits", fun prepare_preserves_edit/1},
        {"concurrent writers keep all entries", fun concurrent_writers/1},
        {"readers cannot observe a partial managed operation", fun snapshot_lock/1},
        {"runtime hash uses the supplied snapshot only", fun pure_snapshot_hash/1},
        {"missing registry integrity is not pristine", fun corrupt_journal/1},
        {"interrupted writer remains uncertain", fun interrupted_writer/1},
        {"post-load interruption preserves actual old-code hash", fun interrupted_after_load/1},
        {"rollback uses captured bytes despite changed file/code path", fun exact_rollback/1},
        {"same semantic code still restores the original BEAM", fun same_code_rollback/1},
        {"rollback retries only purge lingering old code", fun rollback_pending/1},
        {"both active generations remain in provenance", fun old_generations/1},
        {"on_load is refused without executing it", fun reject_on_load/1},
        {"module name mismatch leaves code unchanged", fun name_mismatch/1},
        {"legacy entries cannot silently disappear", fun legacy_entry/1}
    ]].

policy(_F) ->
    application:unset_env(damage, operator_hotcode),
    ?assertEqual({error, hotcode_disabled}, damage_hotcode:allowed(?A)),
    enable([?A]),
    ?assertEqual(ok, damage_hotcode:allowed(?A)),
    ?assertEqual({error, {hotcode_module_not_allowed, ?B}}, damage_hotcode:allowed(?B)),
    Core = [damage, damage_auth, damage_context, damage_build_info,
            damage_hotcode, damage_release, damage_release_overrides,
            steps_utils, steps_hotcode],
    enable(Core ++ [?A]),
    [?assertEqual({error, {protected_hotcode_module, M}}, damage_hotcode:allowed(M)) || M <- Core],
    ?assertMatch({error, {module_not_in_damage_application, _}}, damage_hotcode:allowed(lists)),
    application:set_env(damage, operator_hotcode, #{enabled => true}),
    ?assertEqual({error, invalid_operator_hotcode_config}, damage_hotcode:allowed(?A)).

prepare_preserves_edit(_F) ->
    {ok, copied, Path} = damage_hotcode:prepare(?A),
    Edit = source(?A, changed),
    ok = file:write_file(Path, Edit),
    ?assertEqual({ok, exists, Path}, damage_hotcode:prepare(?A)),
    ?assertEqual({ok, Edit}, file:read_file(Path)),
    {ok, Meta} = damage_hotcode:reload(?A),
    ?assertEqual(changed, ?A:value()),
    ?assertEqual(sha256(Edit), maps:get(source_sha256, Meta)),
    %% The strict runner inspects abstract code at code:which(Module).
    ?assertMatch({ok, {?A, [{abstract_code, {raw_abstract_v1, _}}]}},
                 beam_lib:chunks(code:which(?A), [abstract_code])),
    ?assertMatch({error, {overrides_still_loaded, _}}, damage_release_overrides:clear()),
    ?assertEqual({error, {override_still_loaded, ?A}}, damage_release_overrides:remove(?A)),
    %% Revocation must prevent new loads but not prevent undoing existing ones.
    enable([]),
    ?assertMatch({error, {hotcode_module_not_allowed, ?A}}, damage_hotcode:reload(?A)),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)),
    ?assertEqual(base, ?A:value()),
    ?assertEqual([], damage_release_overrides:list()).

concurrent_writers(F) ->
    Parent = self(),
    Workers = [spawn_worker(fun() ->
        receive go -> ok end,
        M = case N rem 2 of 0 -> ?A; _ -> ?B end,
        ok = damage_release_overrides:record(meta(F, M)),
        Parent ! {done, self()}
    end) || N <- lists:seq(1, 8)],
    [Pid ! go || Pid <- Workers],
    [receive {done, Pid} -> ok after 15000 -> error(writer_timeout) end || Pid <- Workers],
    ?assertEqual(2, length(damage_release_overrides:list())),
    Snapshot = damage_release_overrides:snapshot(),
    ?assertEqual(recorded, maps:get(runtime_integrity_status, Snapshot)),
    ?assert(lists:all(fun(M) ->
        not maps:is_key(base_beam, M) andalso not maps:is_key(base_filename, M)
    end, maps:get(overrides, Snapshot))).

snapshot_lock(F) ->
    Parent = self(),
    Writer = spawn_worker(fun() ->
        damage_release_overrides:with_lock(fun() ->
            ok = damage_release_overrides:record(meta(F, ?A)),
            Parent ! {locked, self()},
            receive commit -> ok end,
            ok = damage_release_overrides:record(meta(F, ?B))
        end)
    end),
    receive {locked, Writer} -> ok after 2000 -> error(writer_not_ready) end,
    Reader = spawn_worker(fun() ->
        Parent ! {reading, self()},
        Parent ! {snapshot, self(), damage_release_overrides:snapshot()}
    end),
    receive {reading, Reader} -> ok after 2000 -> error(reader_not_ready) end,
    receive {snapshot, Reader, _} -> error(partial_snapshot_visible) after 40 -> ok end,
    Writer ! commit,
    receive
        {snapshot, Reader, S} -> ?assertEqual(2, length(maps:get(overrides, S)))
    after 5000 -> error(reader_timeout)
    end.

pure_snapshot_hash(F) ->
    ok = damage_release_overrides:record(meta(F, ?A)),
    Info = damage_release:info(),
    ?assertEqual(recorded, maps:get(runtime_integrity_status, Info)),
    Hash = maps:get(runtime_code_hash, Info),
    ?assertNotEqual(<<"unknown">>, Hash),
    ok = damage_release_overrides:record(meta(F, ?B)),
    ?assertEqual(Hash, damage_release_overrides:runtime_code_hash(Info)),
    NewInfo = damage_release:info(),
    ?assertNotEqual(Hash, maps:get(runtime_code_hash, NewInfo)),
    ?assertEqual(2, length(maps:get(overrides, NewInfo))),
    Reverse = NewInfo#{overrides := lists:reverse(maps:get(overrides, NewInfo))},
    ?assertEqual(maps:get(runtime_code_hash, NewInfo), damage_release_overrides:runtime_code_hash(Reverse)).

corrupt_journal(_F) ->
    Saved = persistent_term:get(?JOURNAL, #{}),
    persistent_term:put(?JOURNAL, invalid_test_state),
    try
        Info = damage_release:info(),
        ?assertEqual(null, maps:get(runtime_modified, Info)),
        ?assertEqual(unavailable, maps:get(runtime_integrity_status, Info)),
        ?assertEqual(<<"unknown">>, maps:get(runtime_code_hash, Info))
    after persistent_term:put(?JOURNAL, Saved) end.

interrupted_writer(F) ->
    Parent = self(),
    Writer = spawn_worker(fun() ->
        damage_release_overrides:with_lock(fun() ->
            ok = damage_release_overrides:record((meta(F, ?A))#{state => loading}),
            Parent ! {pending, self()},
            receive never -> ok end
        end)
    end),
    receive {pending, Writer} -> ok after 2000 -> error(writer_timeout) end,
    stop_worker(Writer),
    Info = damage_release:info(),
    ?assertEqual(true, maps:get(runtime_modified, Info)),
    ?assertEqual(uncertain, maps:get(runtime_integrity_status, Info)),
    ?assertEqual(<<"unknown">>, maps:get(runtime_code_hash, Info)),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)).

interrupted_after_load(F) ->
    Beam = compile_source(?A, source(?A, interrupted), maps:get(root, F)),
    {ok, {?A, RawMd5}} = beam_lib:md5(Beam),
    CandidateMd5 = string:lowercase(binary:encode_hex(RawMd5)),
    Entry = (meta(F, ?A))#{state => loading, beam_sha256 => sha256(Beam),
                          candidate_module_md5 => CandidateMd5},
    Path = filename:join(maps:get(root, F), "candidate.beam"),
    ok = file:write_file(Path, Beam),
    Parent = self(),
    Writer = spawn_worker(fun() ->
        damage_release_overrides:with_lock(fun() ->
            ok = damage_release_overrides:record(Entry),
            ok = code:atomic_load([{?A, Path, Beam}]),
            Parent ! {loaded, self()},
            receive never -> ok end
        end)
    end),
    receive {loaded, Writer} -> ok after 2000 -> error(load_timeout) end,
    stop_worker(Writer),
    ?assertEqual(uncertain, maps:get(runtime_integrity_status, damage_release:info())),
    Parked = park(?A),
    ?assertEqual({error, rollback_loaded_but_override_still_in_use}, damage_hotcode:rollback(?A)),
    [Public] = damage_hotcode:status(),
    ?assertEqual(sha256(Beam), maps:get(old_beam_sha256, Public)),
    ?assertEqual(base, ?A:value()),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)).

exact_rollback(F) ->
    edit(?A, override),
    {ok, _} = damage_hotcode:reload(?A),
    ?assertEqual(override, ?A:value()),
    %% Replace the on-disk base and prepend a decoy to the code path. Neither
    %% may determine what rollback loads after capture_base/1 has run.
    Decoy = compile_source(?A, source(?A, decoy), maps:get(root, F)),
    BasePath = maps:get(?A, maps:get(paths, F)),
    ok = file:write_file(BasePath, Decoy),
    DecoyDir = filename:join(maps:get(root, F), "decoy"),
    ok = file:make_dir(DecoyDir),
    ok = file:write_file(filename:join(DecoyDir, atom_to_list(?A) ++ ".beam"), Decoy),
    true = code:add_patha(DecoyDir),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)),
    ?assertEqual(base, ?A:value()),
    ?assertEqual([], damage_hotcode:status()).

same_code_rollback(F) ->
    edit(?A, base),
    {ok, _} = damage_hotcode:reload(?A),
    BasePath = maps:get(?A, maps:get(paths, F)),
    ?assertNotEqual(BasePath, code:which(?A)),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)),
    ?assertEqual(BasePath, code:which(?A)),
    ?assertEqual([], damage_hotcode:status()).

rollback_pending(F) ->
    edit(?A, override),
    {ok, Loaded} = damage_hotcode:reload(?A),
    Parked = park(?A),
    ?assertEqual({error, rollback_loaded_but_override_still_in_use}, damage_hotcode:rollback(?A)),
    ?assert(is_process_alive(Parked)),
    ?assertEqual(base, ?A:value()),
    [Meta] = damage_hotcode:status(),
    ?assertEqual(rollback_pending, maps:get(state, Meta)),
    ?assertEqual(sha256(maps:get(?A, maps:get(beams, F))), maps:get(loaded_beam_sha256, Meta)),
    ?assertEqual(maps:get(beam_sha256, Loaded), maps:get(old_beam_sha256, Meta)),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)),
    ?assertNot(erlang:check_old_code(?A)),
    ?assertEqual([], damage_hotcode:status()).

old_generations(_F) ->
    edit(?A, first),
    {ok, First} = damage_hotcode:reload(?A),
    Parked = park(?A),
    edit(?A, second),
    {ok, Second} = damage_hotcode:reload(?A),
    ?assertEqual(second, ?A:value()),
    ?assertEqual(maps:get(beam_sha256, First), maps:get(old_beam_sha256, Second)),
    ?assertNotEqual(maps:get(beam_sha256, First), maps:get(beam_sha256, Second)),
    edit(?A, third),
    ?assertEqual({error, old_code_still_in_use}, damage_hotcode:reload(?A)),
    ?assertEqual(second, ?A:value()),
    ?assert(is_process_alive(Parked)),
    stop_worker(Parked),
    ?assertMatch({ok, _}, damage_hotcode:rollback(?A)).

reject_on_load(F) ->
    Path = damage_hotcode:source_path(?A),
    Src = iolist_to_binary(["-module(", atom_to_list(?A), ").\n",
        "-export([value/0]).\n-on_load(init/0).\n",
        "init() -> persistent_term:put({?MODULE, test_on_load}, true), ok.\n",
        "value() -> forbidden.\n"]),
    ok = file:write_file(Path, Src),
    ?assertMatch({error, {unsupported_hotcode_attributes, ?A, _}}, damage_hotcode:reload(?A)),
    ?assertEqual(false, persistent_term:get({?A, test_on_load}, false)),
    ?assertEqual(base, ?A:value()),
    ?assertEqual([], damage_hotcode:status()),
    ?assertEqual(sha256(maps:get(?A, maps:get(beams, F))),
        sha256(element(2, code:get_object_code(?A)))).

name_mismatch(_F) ->
    ok = file:write_file(damage_hotcode:source_path(?A), source(?B, wrong_module)),
    ?assertMatch({error, _}, damage_hotcode:reload(?A)),
    ?assertEqual(base, ?A:value()),
    ?assertEqual(base, ?B:value()),
    ?assertEqual([], damage_hotcode:status()).

legacy_entry(_F) ->
    persistent_term:put(?JOURNAL, #{?A => #{module => ?A, beam_sha256 => <<"legacy">>}}),
    ?assertEqual({error, {base_beam_unavailable, ?A}}, damage_hotcode:rollback(?A)),
    ?assertEqual(uncertain, maps:get(runtime_integrity_status, damage_release:info())),
    %% Test-only teardown: this fixture never loaded an override in this test.
    persistent_term:erase(?JOURNAL).

%% Run on an isolated test node: never stop an actual running Damage application.
with_fixture(Fun) ->
    ?assertNot(lists:keymember(damage, 1, application:which_applications())),
    ?assertEqual([], damage_release_overrides:list()),
    SavedApp = application:get_all_key(damage),
    SavedPath = code:get_path(),
    SavedJournal = persistent_term:get(?JOURNAL, #{}),
    SavedWorkers = erlang:put(hotcode_test_workers, []),
    Temp = case os:getenv("TMPDIR") of false -> "/tmp"; TempValue -> TempValue end,
    Root = filename:join(Temp, "damage-hotcode-test-" ++
        binary_to_list(string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(12))))),
    AppRoot = filename:join(Root, "damage-0.0.0"),
    Ebin = filename:join(AppRoot, "ebin"),
    SrcDir = filename:join(AppRoot, "src"),
    Operator = filename:join([Root, "overrides", "src"]),
    Keys = [operator_hotcode, operator_source_dir, release_provenance_file],
    SavedEnv = [{K, application:get_env(damage, K)} || K <- Keys],
    [ok = filelib:ensure_dir(filename:join(D, "unused")) || D <- [Ebin, SrcDir, Operator]],
    case SavedApp of {ok, _} -> ok = application:unload(damage); _ -> ok end,
    try
        true = code:replace_path(damage, Ebin),
        Core = [damage, damage_auth, damage_context, damage_build_info, damage_hotcode,
                damage_release, damage_release_overrides, steps_hotcode, steps_utils],
        ok = application:load({application, damage, [{vsn, "0.0.0"},
            {description, "hotcode test fixture"}, {modules, [?A, ?B | Core]},
            {registered, []}, {applications, [kernel, stdlib]}]}),
        application:set_env(damage, operator_source_dir, Operator),
        application:set_env(damage, release_provenance_file, filename:join(Root, "absent.install")),
        enable([?A, ?B]),
        Beams = maps:from_list([{M, compile_source(M, source(M, base), SrcDir)} || M <- [?A, ?B]]),
        Paths = maps:from_list([{M, filename:join(Ebin, atom_to_list(M) ++ ".beam")} || M <- [?A, ?B]]),
        [begin
            ok = file:write_file(maps:get(M, Paths), maps:get(M, Beams)),
            {module, M} = code:load_binary(M, maps:get(M, Paths), maps:get(M, Beams))
        end || M <- [?A, ?B]],
        ?assertEqual(SrcDir, code:lib_dir(damage, src)),
        Fun(#{root => Root, beams => Beams, paths => Paths})
    after
        [stop_worker(P) || P <- erlang:get(hotcode_test_workers)],
        %% Test-owned modules only; clean both generations before restoring state.
        [begin code:soft_purge(M), code:delete(M), code:soft_purge(M) end || M <- [?A, ?B]],
        persistent_term:put(?JOURNAL, SavedJournal),
        application:unload(damage),
        true = code:set_path(SavedPath),
        case SavedApp of {ok, Props} -> application:load({application, damage, Props}); _ -> ok end,
        [restore_env(K, V) || {K, V} <- SavedEnv],
        erlang:put(hotcode_test_workers, SavedWorkers),
        file:del_dir_r(Root)
    end.

enable(Modules) ->
    application:set_env(damage, operator_hotcode, [{enabled, true}, {allowed_modules, Modules}]).
restore_env(K, undefined) -> application:unset_env(damage, K);
restore_env(K, {ok, V}) -> application:set_env(damage, K, V).

source(Module, Value) ->
    iolist_to_binary(io_lib:format(
        "-module(~p).\n-export([value/0, park/1]).\nvalue() -> ~p.\n"
        "park(Parent) -> Parent ! {parked, self()}, receive stop -> ok end.\n", [Module, Value])).

compile_source(Module, Source, Dir) ->
    Path = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
    ok = file:write_file(Path, Source),
    {ok, Module, Beam} = compile:noenv_file(Path, [binary, debug_info]),
    Beam.

edit(M, Value) -> file:write_file(damage_hotcode:source_path(M), source(M, Value)).
sha256(B) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, B))).

meta(F, M) ->
    Beam = maps:get(M, maps:get(beams, F)),
    Md5 = string:lowercase(binary:encode_hex(M:module_info(md5))),
    #{module => M, state => active, base_beam => Beam,
      base_filename => maps:get(M, maps:get(paths, F)), base_module_md5 => Md5,
      loaded_module_md5 => Md5, base_beam_sha256 => sha256(Beam),
      loaded_beam_sha256 => sha256(Beam), beam_sha256 => sha256(Beam),
      source_sha256 => sha256(source(M, base)), loaded_at => 1}.

spawn_worker(Fun) ->
    Pid = spawn(Fun),
    erlang:put(hotcode_test_workers, [Pid | erlang:get(hotcode_test_workers)]),
    Pid.
stop_worker(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> error(worker_did_not_stop) end.
park(M) ->
    Parent = self(),
    P = spawn_worker(fun() -> M:park(Parent) end),
    receive {parked, P} -> P after 2000 -> error(park_timeout) end.
