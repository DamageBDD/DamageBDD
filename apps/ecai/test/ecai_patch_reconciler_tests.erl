-module(ecai_patch_reconciler_tests).

-include_lib("eunit/include/eunit.hrl").

active_worker_keys_test() ->
    Children = [
        {{ecai_patch_worker, <<"fp1">>, <<"v1">>}, self(), worker, [ecai_patch_worker]},
        {{ecai_patch_worker, <<"dead">>, <<"v2">>}, undefined, worker, [ecai_patch_worker]},
        {other_child, self(), worker, [other]}
    ],
    Active = ecai_patch_reconciler:active_worker_keys(Children),
    ?assert(maps:is_key({<<"fp1">>, <<"v1">>}, Active)),
    ?assertNot(maps:is_key({<<"dead">>, <<"v2">>}, Active)).

stale_running_without_worker_is_recovered_test() ->
    Repair = #{status => running, fingerprint => <<"fp">>, finding_version => <<"v">>,
               updated_at_ms => 1000},
    ?assert(ecai_patch_reconciler:should_recover(
        Repair, {<<"fp">>, <<"v">>}, #{}, {5000, 1000})).

active_running_is_not_recovered_test() ->
    Key = {<<"fp">>, <<"v">>},
    Repair = #{status => running, fingerprint => <<"fp">>, finding_version => <<"v">>,
               updated_at_ms => 1000},
    ?assertNot(ecai_patch_reconciler:should_recover(
        Repair, Key, #{Key => true}, {5000, 1000})).

recent_running_is_not_recovered_test() ->
    Repair = #{status => running, fingerprint => <<"fp">>, finding_version => <<"v">>,
               updated_at_ms => 4500},
    ?assertNot(ecai_patch_reconciler:should_recover(
        Repair, {<<"fp">>, <<"v">>}, #{}, {5000, 1000})).

queued_is_not_recovered_test() ->
    Repair = #{status => queued, fingerprint => <<"fp">>, finding_version => <<"v">>,
               updated_at_ms => 1000},
    ?assertNot(ecai_patch_reconciler:should_recover(
        Repair, {<<"fp">>, <<"v">>}, #{}, {5000, 1000})).
