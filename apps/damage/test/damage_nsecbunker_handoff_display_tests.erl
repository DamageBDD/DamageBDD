-module(damage_nsecbunker_handoff_display_tests).
-include_lib("eunit/include/eunit.hrl").

aws_text_and_allowlist_test() ->
    Aws = #{region => "ap-southeast-2", secret_id => "/example/vault-passphrase",
        expected_role_name => "damage-node-prod", expected_account_id => "123456789012",
        passphrase => <<"DO_NOT_INCLUDE">>, credentials => #{access_key => <<"PRIVATE">>}},
    Public = damage_nsecbunker_handoff:public_aws(Aws),
    ?assertEqual(#{region => <<"ap-southeast-2">>, secret_id => <<"/example/vault-passphrase">>,
        expected_role_name => <<"damage-node-prod">>, expected_account_id => <<"123456789012">>}, Public),
    ?assertEqual(Public, damage_nsecbunker_handoff:public_aws(Public)).

invalid_text_does_not_break_report_test_() ->
    [?_assertEqual(#{region => <<"invalid_text">>},
        damage_nsecbunker_handoff:public_aws(#{region => V})) ||
        V <- [[16#d800], <<255>>, {unexpected, value}, 123]].

relay_limit_and_subscription_test_() ->
    Relays = [<<"wss://relay", (integer_to_binary(N))/binary, ".example">> || N <- lists:seq(1,7)],
    Cases = [{[],true,failed,no_relays}, {lists:sublist(Relays,6),true,passed,subscribed},
        {Relays,true,failed,too_many_relays}, {Relays,false,failed,too_many_relays},
        {[<<"ws://relay.example">>],true,failed,invalid_relay},
        {[<<"wss://user:secret@relay.example">>],true,failed,invalid_relay},
        {[hd(Relays)],false,failed,not_subscribed}],
    [?_assertMatch(#{status := Status, reason := Reason, max_relays := 6},
        damage_nsecbunker_handoff_checks:relay_control(Rs,Subscribed)) ||
        {Rs,Subscribed,Status,Reason} <- Cases].

relay_count_is_actionable_test() ->
    R = damage_nsecbunker_handoff_checks:relay_control(lists:duplicate(7,<<"wss://relay.example">>),true),
    ?assertEqual(7,maps:get(configured_count,R)),
    ?assertMatch(<<"7 relays configured;",_/binary>>,maps:get(next_action,R)).

missing_evidence_is_not_checked_test_() ->
    [?_assertEqual(not_checked,task(Id,#{})) || Id <-
        [current_controls,live_signing,cold_restart,backup_restore,version_promotion]].

failed_attempts_are_failed_test_() ->
    E=evidence(),
    [?_assertEqual(failed,task(Id,E#{Key => (maps:get(Key,E))#{status=>failed}})) ||
        {Id,Key} <- pairs()].

expired_attempts_are_stale_test_() ->
    E=evidence(),
    [?_assertEqual(stale,task(Id,E#{Key => (maps:get(Key,E))#{completed_at=>-100000}})) ||
        {Id,Key} <- pairs()].

missing_dependency_is_blocked_test() ->
    E=maps:remove(verify,evidence()),
    ?assertEqual(blocked,task(cold_restart,E)),
    ?assertEqual(blocked,task(backup_restore,E)),
    ?assertEqual(blocked,task(version_promotion,E)),
    ?assertEqual(blocked,task(version_promotion,maps:remove(recovery,evidence()))).

preflight_refusal_is_blocked_test_() ->
    E=evidence(),
    [?_assertEqual(blocked,task(Id,E#{Key => (maps:get(Key,E))#{
        status=>failed,reason=>prerequisites_failed}})) || {Id,Key} <- pairs()].

mismatched_evidence_needs_verification_test() ->
    E=evidence(), V=maps:get(verify,E),
    ?assertEqual(verification_required,task(live_signing,E#{verify=>V#{fingerprint=><<"old">>}})),
    P=maps:get(pending,E),
    ?assertEqual(verification_required,task(version_promotion,E#{pending=>P#{recovery=>#{}}})).

acceptance_remains_fail_closed_test() ->
    E=evidence(), A=#{report_sha256=><<"hash">>},
    ?assertEqual(accepted,damage_nsecbunker_handoff:closure(E,A,<<"f">>,1000)),
    ?assertEqual(awaiting_acceptance,damage_nsecbunker_handoff:closure(E,undefined,<<"f">>,1000)),
    lists:foreach(fun({_,Key}) ->
        ?assertEqual(outstanding,damage_nsecbunker_handoff:closure(maps:remove(Key,E),A,<<"f">>,1000))
    end,pairs()),
    ?assertEqual(outstanding,damage_nsecbunker_handoff:closure(E,A,<<"changed">>,1000)),
    ?assertEqual(outstanding,damage_nsecbunker_handoff:closure(E,A,<<"f">>,1100)).

task(Id,E) ->
    [T]=[T || T <- damage_nsecbunker_handoff:closure_tasks(E,undefined,<<"f">>,1000),maps:get(id,T)=:=Id],
    maps:get(status,T).
pairs() -> [{current_controls,health},{live_signing,verify},{cold_restart,restart},
    {backup_restore,recovery},{version_promotion,pending}].
evidence() ->
    Base=#{status=>passed,started_at=>900,completed_at=>950,fingerprint=><<"f">>,
        target=><<"t">>,runtime_instance=><<"pid">>,active_secret_version=><<"new">>},
    #{health=>Base,verify=>Base#{sha256=><<"hash">>,exchanges=>[#{status=>passed}],
        policy_checks=>[#{status=>passed},#{status=>passed}]}, restart=>Base,
        pending=>Base#{completed_at=>920,recovery=>#{secret_provenance=>#{
            version_id=><<"new">>,baseline_version_id=><<"old">>}}},
        recovery=>Base#{started_at=>930,recovery=>#{backup_restored=>true,wrong_unlock_rejected=>true,
            metadata_restore=>#{restored=>true},secret_provenance=>#{version_id=><<"new">>}}}}.
