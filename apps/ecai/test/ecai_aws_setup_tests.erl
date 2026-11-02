-module(ecai_aws_setup_tests).
-include_lib("eunit/include/eunit.hrl").

fingerprint_test() ->
    ?assertEqual(ecai_aws_setup:fingerprint(#{a => 1, b => 2}), ecai_aws_setup:fingerprint(#{b => 2, a => 1})),
    ?assertNotEqual(ecai_aws_setup:fingerprint(absent), ecai_aws_setup:fingerprint(#{})),
    ?assertEqual(64, byte_size(ecai_aws_setup:fingerprint(#{a => 1}))).

proxy_transport_test() ->
    Prior = application:get_env(ecai, aws_setup_trusted_proxy_ips),
    try
        application:set_env(ecai, aws_setup_trusted_proxy_ips, [{127,0,0,1}]),
        ?assert(ecai_aws_setup_http:secure_transport(<<"https">>, {10,0,0,9}, <<>>)),
        ?assert(ecai_aws_setup_http:secure_transport(<<"http">>, {127,0,0,1}, <<"https">>)),
        ?assertNot(ecai_aws_setup_http:secure_transport(<<"http">>, {10,0,0,9}, <<"https">>)),
        ?assertNot(ecai_aws_setup_http:secure_transport(<<"http">>, {127,0,0,1}, <<"https,http">>)),
        ?assertNot(ecai_aws_setup_http:secure_transport(<<"http">>, {127,0,0,1}, <<>>))
    after restore(aws_setup_trusted_proxy_ips, Prior) end.

owner_policy_test() ->
    Enabled = application:get_env(ecai, aws_setup_enabled),
    Accounts = application:get_env(ecai, aws_setup_accounts),
    try
        application:set_env(ecai, aws_setup_enabled, false),
        ?assertNot(ecai_aws_setup_config:allowed(<<"owner">>)),
        application:set_env(ecai, aws_setup_enabled, true),
        application:set_env(ecai, aws_setup_accounts, [<<"owner">>]),
        ?assert(ecai_aws_setup_config:allowed(<<"owner">>)),
        ?assertNot(ecai_aws_setup_config:allowed(<<"other">>))
    after restore(aws_setup_enabled, Enabled), restore(aws_setup_accounts, Accounts) end.

sensitive_status_test() ->
    Secret = <<"FAKE_TEST_SECRET">>,
    Report = #{state => Secret, message => Secret, reason => Secret, log => [Secret]},
    Out = ecai_aws_setup_session:format_status(Report),
    ?assertEqual(nomatch, binary:match(term_to_binary(Out), Secret)).

recovery_preserves_at_most_once_probe_fence_test() ->
    O = #{<<"status">> => <<"deploying">>, <<"busy">> => true,
          <<"credential_session_active">> => true, <<"last_error">> => null,
          <<"probe">> => #{<<"probe_id">> => <<"probe">>, <<"status">> => <<"SUBMITTING">>}},
    R = ecai_aws_setup:recovered(O),
    ?assertEqual(false, maps:get(<<"busy">>, R)),
    ?assertEqual(false, maps:get(<<"credential_session_active">>, R)),
    ?assertEqual(<<"reconcile_required">>, maps:get(<<"status">>, R)),
    ?assertEqual(<<"UNKNOWN">>, maps:get(<<"status">>, maps:get(<<"probe">>, R))).

public_records_hide_internal_binding_data_test() ->
    O = #{<<"owner">> => <<"owner">>, <<"key_hash">> => <<"key">>, <<"input_hash">> => <<"hash">>,
          <<"expected_provider">> => <<"private-cas-value">>, <<"imported_provider">> => <<"private">>,
          <<"plan">> => #{<<"template">> => #{}, <<"plan_sha256">> => <<"hash">>}},
    Public = ecai_aws_setup:public(O, false),
    ?assertNot(maps:is_key(<<"owner">>, Public)),
    ?assertNot(maps:is_key(<<"expected_provider">>, Public)),
    ?assertNot(maps:is_key(<<"template">>, maps:get(<<"plan">>, Public))),
    ?assert(maps:is_key(<<"template">>, maps:get(<<"plan">>, ecai_aws_setup:public(O, true)))).

provider_import_compare_and_swap_test_() ->
    {timeout, 20, fun() ->
        %% Isolated EUnit run: do not stop or overwrite a live application's store.
        ?assertEqual(undefined, whereis(ecai_compute_settings)),
        Dir = filename:join("/tmp", "ecai-aws-cas-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Path = filename:join(Dir, "settings.dets"),
        {ok, Pid} = ecai_compute_settings:start_link(#{path => Path}),
        try
            Owner = <<"owner">>,
            {ok, #{<<"external_id">> := Ext}} = ecai_compute_settings:prepare_provider(Owner, <<"aws_batch">>),
            Config = #{<<"role_arn">> => <<"arn:aws:iam::123456789012:role/Test">>, <<"region">> => <<"us-east-1">>,
                <<"job_queue">> => <<"test-queue">>, <<"job_definition">> => <<"test-job:1">>, <<"bucket">> => <<"ecai-test-bucket">>},
            Empty = ecai_aws_setup:fingerprint(absent),
            {ok, Saved} = ecai_compute_settings:import_aws_provider(Owner, Empty, Config, Ext),
            ?assertEqual(Ext, maps:get(<<"external_id">>, Saved)),
            ?assertEqual({error, provider_changed_since_plan}, ecai_compute_settings:import_aws_provider(Owner, Empty, Config, Ext)),
            ?assertEqual({ok, unchanged}, ecai_compute_settings:remove_aws_provider(Owner, Empty)),
            ?assertEqual({ok, removed}, ecai_compute_settings:remove_aws_provider(Owner, ecai_aws_setup:fingerprint(Saved))),
            {ok, Snapshot} = ecai_compute_settings:snapshot(Owner),
            ?assertEqual(false, maps:get(<<"remote_enabled">>, maps:get(<<"budget">>, Snapshot))),
            ?assertEqual(false, maps:get(<<"enabled">>, maps:get(<<"mint">>, Snapshot)))
        after gen_server:stop(Pid), file:del_dir_r(Dir) end
    end}.
restore(Key, undefined) -> application:unset_env(ecai, Key);
restore(Key, {ok, Value}) -> application:set_env(ecai, Key, Value).
