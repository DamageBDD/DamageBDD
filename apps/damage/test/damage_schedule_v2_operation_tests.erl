-module(damage_schedule_v2_operation_tests).
-include_lib("eunit/include/eunit.hrl").

identity_is_owner_scoped_test() ->
    Spec = #{feature => <<"Feature: A">>, lock_amount => 100},
    {ok, Id, Digest} = damage_schedule_v2_operation:identity(<<"ak_a">>, create, Spec),
    ?assertEqual({ok, Id, Digest}, damage_schedule_v2_operation:identity(<<"ak_a">>, create, Spec)),
    {ok, Other, _} = damage_schedule_v2_operation:identity(<<"ak_b">>, create, Spec),
    ?assertNotEqual(Id, Other).

explicit_key_binds_payload_test() ->
    Spec = #{request_id => <<"request-1">>, feature => <<"A">>},
    {ok, Id, Digest} = damage_schedule_v2_operation:identity(<<"ak_a">>, create, Spec),
    {ok, Id, OtherDigest} = damage_schedule_v2_operation:identity(<<"ak_a">>, create, Spec#{feature => <<"B">>}),
    ?assertNotEqual(Digest, OtherDigest).

invalid_keys_test_() ->
    [?_assertEqual({error, invalid_request_id},
        damage_schedule_v2_operation:identity(<<"ak_a">>, create, #{request_id => Key}))
        || Key <- [<<>>, binary:copy(<<"a">>, 129), 42, undefined]].

preparation_error_is_terminal_test() ->
    Failed = damage_schedule_v2_operation:failure(op(preparing), {invalid_cron, private_detail}),
    ?assertEqual(failed, maps:get(status, Failed)),
    ?assertEqual(<<"invalid_cron">>, maps:get(error, Failed)),
    ?assertNot(damage_schedule_v2_operation:blocks_owner(Failed)).

write_timeout_remains_unknown_test() ->
    Error = {error, {tx_poll_timeout, #{tx_hash => <<"th_123ABC">>, last_result => private_data}}},
    Failed = damage_schedule_v2_operation:failure(op(fund_schedule), Error),
    ?assertEqual(reconciliation_required, maps:get(status, Failed)),
    ?assertEqual(<<"th_123ABC">>, maps:get(tx_hash, Failed)),
    ?assertEqual(<<"confirmation_timeout">>, maps:get(error, Failed)),
    ?assert(damage_schedule_v2_operation:blocks_owner(Failed)),
    ?assertNot(maps:is_key(last_result, Failed)).

recovery_never_retries_writes_test_() ->
    [?_assertEqual(reconciliation_required, maps:get(status,
        damage_schedule_v2_operation:recover(op(Stage))))
        || Stage <- [ensuring_vault, create_schedule, approve_allowance, fund_schedule]].

public_metadata_is_redacted_test() ->
    Public = damage_schedule_v2_operation:public((op(fund_schedule))#{
        request_hash => <<"hash">>, private_key => <<"SECRET">>, signed_tx => <<"tx_secret">>,
        feature => <<"private feature">>}),
    [?assertNot(maps:is_key(Key, Public)) || Key <- [owner, request_hash, private_key, signed_tx, feature]],
    ?assertEqual(<<"sop_1">>, maps:get(operation_id, Public)).

op(Stage) -> #{operation_id => <<"sop_1">>, owner => <<"ak_a">>, status => running, stage => Stage}.
