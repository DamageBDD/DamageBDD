-module(damage_node_security_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

passing_fixture() ->
    #{uid => {ok, [1000, 1000, 1000, 1000]}, caps => {ok, [0, 0, 0, 0]},
      nnp => {ok, 1}, umask => {ok, 8#077}, core_limit => {ok, 0},
      core_collector => {passed, no_piped_core_collector},
      crash_suppressed => true, credential_environment_clear => true,
      cookie_argument_clear => true, keystore => {passed, private_file},
      secrets_database => {passed, private_file},
      beam_tcp => {passed, no_nonloopback_listener_observed},
      epmd_tcp => {not_applicable, no_epmd_listener_observed},
      secure_cookie_setting => true, code_reload => {ok, true},
      operator_hotcode => {ok, true}, reload_process_absent => true,
      legacy_sync_absent => true}.

status(Id, Snapshot) ->
    [Row] = [C || #{id := I} = C <- damage_node_security:assess(Snapshot), I =:= Id],
    maps:get(status, Row).

complete_baseline_test() ->
    Checks = damage_node_security:assess(passing_fixture()),
    ?assertEqual(15, length(Checks)),
    ?assertEqual(15, length(lists:usort([maps:get(id, C) || C <- Checks]))),
    ?assert(lists:all(fun(C) -> lists:member(maps:get(status, C),
        [passed, not_applicable]) end, Checks)).

missing_evidence_never_passes_test() ->
    Checks = damage_node_security:assess(#{}),
    ?assertEqual(15, length(Checks)),
    ?assert(lists:all(fun(C) -> maps:get(status, C) =:= unknown end, Checks)).

independent_failures_are_all_retained_test() ->
    S = (passing_fixture())#{uid => {ok, [0, 0, 0, 0]},
        secure_cookie_setting => false, credential_environment_clear => false},
    Checks = damage_node_security:assess(S),
    Failed = [maps:get(id, C) || C <- Checks, maps:get(status, C) =:= failed],
    ?assertEqual([process_uid, credential_environment, secure_cookie_setting], Failed),
    ?assertEqual(15, length(Checks)).

noncompliant_controls_test_() ->
    [?_assertEqual(failed, status(Id, (passing_fixture())#{Key => Value})) ||
        {Id, Key, Value} <- [
            {process_uid, uid, {ok, [1000, 1000, 0, 1000]}},
            {process_capabilities, caps, {ok, [0, 1, 0, 0]}},
            {process_capabilities, caps, {ok, [0, 0, 0, 1]}},
            {no_new_privileges, nnp, {ok, 0}},
            {private_umask, umask, {ok, 8#022}},
            {core_file_size_limit, core_limit, {ok, unlimited}},
            {beam_crash_dump_setting, crash_suppressed, false},
            {credential_environment, credential_environment_clear, false},
            {cookie_argument, cookie_argument_clear, false},
            {node_keystore, keystore, {failed, file_permissions_or_empty}},
            {secrets_database, secrets_database, {failed, required_file_missing}},
            {beam_tcp_listeners, beam_tcp, {failed, nonloopback_listener_present}},
            {epmd_tcp_listener, epmd_tcp, {failed, nonloopback_listener_present}},
            {secure_cookie_setting, secure_cookie_setting, false},
            {automatic_code_reload, code_reload, {ok, false}},
            {automatic_code_reload, operator_hotcode, {ok, false}},
            {automatic_code_reload, reload_process_absent, false},
            {automatic_code_reload, legacy_sync_absent, false}
        ]].

unknown_controls_test_() ->
    [?_assertEqual(unknown, status(Id, (passing_fixture())#{Key => Value})) ||
        {Id, Key, Value} <- [
            {process_uid, uid, unavailable},
            {process_capabilities, caps, {error, unavailable}},
            {core_collector, core_collector, {unknown, piped_collector_requires_independent_evidence}},
            {node_keystore, keystore, {unknown, storage_path_unavailable}},
            {beam_tcp_listeners, beam_tcp, {unknown, unavailable}},
            {secure_cookie_setting, secure_cookie_setting, <<"true">>},
            {automatic_code_reload, code_reload, {error, unavailable}},
            {automatic_code_reload, operator_hotcode, {error, unavailable}}
        ]].

parse_status_test() ->
    Bin = <<"Name:\tbeam.smp\nUid:\t1000\t1000\t1000\t1000\n",
        "CapEff:\t0000000000000000\nCapPrm:\t0000000000000000\n",
        "CapInh:\t0000000000000000\nCapAmb:\t0000000000000000\n",
        "NoNewPrivs:\t1\nUmask:\t0077\nUnrelated:\tSYNTHETIC_SECRET\n">>,
    M = damage_node_security:parse_status(Bin),
    ?assertEqual({ok, [1000, 1000, 1000, 1000]}, maps:get(uid, M)),
    ?assertEqual({ok, [0, 0, 0, 0]}, maps:get(caps, M)),
    ?assertEqual({ok, 1}, maps:get(nnp, M)),
    ?assertEqual({ok, 8#077}, maps:get(umask, M)),
    ?assertEqual(nomatch, binary:match(term_to_binary(M), <<"SYNTHETIC_SECRET">>)).

malformed_and_duplicate_status_test() ->
    M = damage_node_security:parse_status(<<"Uid:\t0 nope 0 0\n",
        "NoNewPrivs:\t1\nNoNewPrivs:\t0\nUmask:\t0099\n">>),
    lists:foreach(fun(K) -> ?assertMatch({error, _}, maps:get(K, M)) end,
        [uid, caps, nnp, umask]).

core_limit_parser_test() ->
    ?assertEqual({ok, 0}, damage_node_security:parse_core_limit(
        <<"Limit Soft Limit Hard Limit Units\nMax core file size  0 unlimited bytes\n">>)),
    ?assertEqual({ok, unlimited}, damage_node_security:parse_core_limit(
        <<"Max core file size unlimited unlimited bytes\n">>)),
    ?assertMatch({error, _}, damage_node_security:parse_core_limit(<<>>)).

disabled_setting_test() ->
    ?assertEqual({ok, true}, damage_node_security:disabled_setting({ok, [{enabled, false}]})),
    ?assertEqual({ok, false}, damage_node_security:disabled_setting({ok, [{enabled, dev}]})),
    lists:foreach(fun(V) -> ?assertMatch({error, _}, damage_node_security:disabled_setting(V)) end,
        [undefined, {ok, []}, {ok, #{enabled => false}},
         {ok, [{enabled, false}, {enabled, true}]}, {ok, [enabled]}]).

loopback_validation_test() ->
    lists:foreach(fun(A) -> ?assert(damage_node_security:loopback(A)) end,
        [{127, 0, 0, 1}, {127, 4, 3, 2}, {0, 0, 0, 0, 0, 0, 0, 1},
         {0, 0, 0, 0, 0, 16#ffff, 16#7f00, 1}]),
    lists:foreach(fun(A) -> ?assertNot(damage_node_security:loopback(A)) end,
        [{0, 0, 0, 0}, {10, 0, 0, 1}, {127, 0, 0, 256},
         {0, 0, 0, 0, 0, 0, 0, 0}, {16#fc00, 0, 0, 0, 0, 0, 0, 1}]).

%% Build native-order procfs words, not a little-endian-only fixture.
proc_address({A, B, C, D}) ->
    <<W:32>> = <<A, B, C, D>>,
    binary:encode_hex(<<W:32/native-unsigned-integer>>);
proc_address({A, B, C, D, E, F, G, H}) ->
    <<W1:32, W2:32, W3:32, W4:32>> = <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>,
    binary:encode_hex(<<W1:32/native-unsigned-integer, W2:32/native-unsigned-integer,
        W3:32/native-unsigned-integer, W4:32/native-unsigned-integer>>).

tcp_table(Address, State) ->
    <<"  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n",
      "0: ", Address/binary, ":BEEF 00000000:0000 ", State/binary,
      " 00000000:00000000 00:00000000 00000000 1000 0 9876\n">>.

tcp_parser_and_bindings_test() ->
    A4 = {127, 0, 0, 1}, A6 = {0, 0, 0, 0, 0, 0, 0, 1},
    ?assertEqual(A4, damage_node_security:decode_address(proc_address(A4), inet)),
    ?assertEqual(A6, damage_node_security:decode_address(proc_address(A6), inet6)),
    {ok, [L4]} = damage_node_security:parse_tcp(tcp_table(proc_address(A4), <<"0A">>), inet),
    {ok, [L6]} = damage_node_security:parse_tcp(tcp_table(proc_address(A6), <<"0A">>), inet6),
    ?assertMatch(#{inode := 9876, port := 16#beef, address := A4}, L4),
    ?assertMatch({passed, _}, damage_node_security:listener_result([L4, L6])),
    {ok, [Public]} = damage_node_security:parse_tcp(
        tcp_table(proc_address({0, 0, 0, 0}), <<"0A">>), inet),
    ?assertMatch({failed, _}, damage_node_security:listener_result([L4, Public])),
    ?assertEqual({ok, []}, damage_node_security:parse_tcp(
        tcp_table(proc_address({0, 0, 0, 0}), <<"01">>), inet)),
    ?assertMatch({error, _}, damage_node_security:parse_tcp(<<"broken">>, inet)),
    ?assertMatch({error, _}, damage_node_security:parse_tcp(
        tcp_table(<<"INVALID!">>, <<"0A">>), inet)).

redacted_findings_test() ->
    S = (passing_fixture())#{password => <<"SYNTHETIC_SECRET">>,
        private_key => <<"SYNTHETIC_SECRET">>, path => <<"/private/SYNTHETIC_SECRET">>},
    Encoded = jsx:encode(damage_node_security:assess(S)),
    ?assertEqual(nomatch, binary:match(Encoded, <<"SYNTHETIC_SECRET">>)).

bounded_collection_timeout_test() ->
    Parent = self(),
    Result = damage_node_security:bounded(fun() ->
        Parent ! {collector_pid, self()}, receive continue -> ok end
    end, 10),
    ?assertEqual({error, timeout}, Result),
    receive {collector_pid, Pid} -> ?assertNot(is_process_alive(Pid))
    after 1000 -> ?assert(false) end.

bounded_collection_exception_test() ->
    ?assertEqual({error, unavailable}, damage_node_security:bounded(
        fun() -> error({private_error, <<"SYNTHETIC_SECRET">>}) end, 1000)),
    ?assertEqual({ok, #{ok => true}}, damage_node_security:bounded(fun() -> #{ok => true} end, 1000)).

filesystem_permissions_and_symlinks_test_() ->
    case os:type() of
        {unix, _} -> {timeout, 10, fun filesystem_permissions_and_symlinks/0};
        _ -> []
    end.

filesystem_permissions_and_symlinks() ->
    with_directory(fun(Dir, Uid) ->
        File = filename:join(Dir, "fixture.key"),
        ok = file:write_file(File, <<"synthetic encrypted fixture">>),
        ok = file:change_mode(File, 8#600),
        ?assertEqual({passed, private_file}, damage_node_security:private_file(File, Uid)),
        ok = file:change_mode(File, 8#400),
        ?assertEqual({passed, private_file}, damage_node_security:private_file(File, Uid)),
        ok = file:change_mode(File, 8#640),
        ?assertMatch({failed, _}, damage_node_security:private_file(File, Uid)),
        ok = file:change_mode(File, 8#600),
        ?assertMatch({failed, _}, damage_node_security:private_file(File, Uid + 1)),
        Link = filename:join(Dir, "symlink.key"),
        ok = file:make_symlink(File, Link),
        ?assertEqual({failed, symlink_forbidden}, damage_node_security:private_file(Link, Uid)),
        Hard = filename:join(Dir, "hard.key"),
        ok = file:make_link(File, Hard),
        ?assertMatch({failed, _}, damage_node_security:private_file(File, Uid)),
        ok = file:delete(Hard),
        ParentLink = filename:join(Dir, "parent-link"),
        ok = file:make_symlink(Dir, ParentLink),
        ?assertEqual({failed, symlink_forbidden}, damage_node_security:private_file(
            filename:join(ParentLink, "fixture.key"), Uid)),
        ok = file:change_mode(Dir, 8#750),
        ?assertEqual({failed, unsafe_parent_directory}, damage_node_security:private_file(File, Uid)),
        ok = file:change_mode(Dir, 8#700),
        ?assertEqual({failed, required_file_missing}, damage_node_security:private_file(
            filename:join(Dir, "missing"), Uid)),
        ok = file:write_file(File, <<>>),
        ?assertMatch({failed, _}, damage_node_security:private_file(File, Uid))
    end).

report_is_exclusive_and_private_test() ->
    with_directory(fun(Dir, _Uid) ->
        R = #{schema_version => 1, passed => false, checks => []},
        ok = damage_node_security:write_report([{run_dir, Dir}], R),
        Path = filename:join(Dir, "node-security.json"),
        {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
        ?assertEqual(8#600, Mode band 8#777),
        {ok, Before} = file:read_file(Path),
        ?assertMatch({error, _}, damage_node_security:write_report([{run_dir, Dir}], #{passed => true})),
        ?assertEqual({ok, Before}, file:read_file(Path)),
        ?assertMatch({error, _}, damage_node_security:write_report([], R)),
        ok = file:delete(Path),
        Victim = filename:join(Dir, "unchanged"),
        ok = file:write_file(Victim, <<"do not overwrite">>),
        ok = file:make_symlink(Victim, Path),
        ?assertMatch({error, _}, damage_node_security:write_report([{run_dir, Dir}], R)),
        ?assertEqual({ok, <<"do not overwrite">>}, file:read_file(Victim))
    end).

forged_admin_and_context_report_do_not_authorize_test() ->
    Fake = <<"synthetic-node-security-not-an-account">>,
    C = #{public_key => Fake, authenticated => true, auth_mode => custodial,
        node_admin => true, node_security_report => #{passed => true}},
    ?assertEqual(false, steps_utils:is_admin(C)),
    ?assertMatch(#{fail := <<"Node administrator required">>}, damage_node_security:verify([], C)),
    ?assertMatch(#{fail := <<"Node administrator required">>}, steps_verification:step(
        [], C, <<"Then">>, 1,
        ["the running node MUST pass the local production security baseline"], [])).

%% A real parser/catalog contract test, not a second regex Gherkin parser.
feature_discovery_and_step_catalog_test() ->
    Priv = code:priv_dir(damage),
    Root = filename:join(Priv, "features/verification"),
    Path = filename:join(Root, "node-security.feature"),
    {ok, Source} = file:read_file(Path),
    Id = damage_verification_catalog:sha256(<<"node-security.feature">>),
    {ok, Entry} = damage_verification_catalog:parse(Id, Source),
    ?assertEqual(<<"Verify this node's security baseline">>, maps:get(title, Entry)),
    ?assertEqual([], maps:get(inputs, Entry)),
    {steps_verification, Beam, _} = code:get_object_code(steps_verification),
    {ok, {steps_verification, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    Steps = damage_bdd_catalog:from_forms(<<"steps_verification">>, <<"test">>, Forms),
    ?assertMatch(#{valid := true}, damage_bdd_validator:validate(Source,
        #{revision => <<"test">>, steps => Steps})),
    Old = application:get_env(damage, verification_feature_dir),
    application:set_env(damage, verification_feature_dir, Root),
    try
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual([Entry], [E || E <- Entries, maps:get(id, E) =:= Id]),
        ?assertEqual({ok, Entry}, damage_verification_catalog:get(Id))
    after restore_env(verification_feature_dir, Old) end.

restore_env(Key, undefined) -> application:unset_env(damage, Key);
restore_env(Key, {ok, Value}) -> application:set_env(damage, Key, Value).

with_directory(Fun) ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])) ++ "_" ++
        integer_to_list(erlang:system_time(microsecond)),
    Dir = filename:join("/tmp", "damage_node_security_test_" ++ Suffix),
    ok = file:make_dir(Dir),
    ok = file:change_mode(Dir, 8#700),
    {ok, #file_info{uid = Uid}} = file:read_file_info(Dir),
    try Fun(Dir, Uid)
    after ok = file:del_dir_r(Dir) end.
