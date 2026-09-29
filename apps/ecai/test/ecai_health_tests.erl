-module(ecai_health_tests).

-include_lib("eunit/include/eunit.hrl").

working_queue_test() ->
    I = #{
        manager_active => 2,
        live_workers => 2,
        persisted_running => 2,
        durable_queued => 10,
        learner_ready => true,
        patch_free_capacity => 1,
        manager_last_error => undefined
    },
    ?assertEqual(working, ecai_health:classify_patch_queue(I)).

learning_gate_test() ->
    I = #{
        manager_active => 0,
        live_workers => 0,
        persisted_running => 0,
        durable_queued => 10,
        learner_ready => false,
        patch_free_capacity => 1,
        manager_last_error => learning_not_ready
    },
    ?assertEqual(blocked_learning, ecai_health:classify_patch_queue(I)).

inference_saturation_test() ->
    I = #{
        manager_active => 0,
        live_workers => 0,
        persisted_running => 0,
        durable_queued => 10,
        learner_ready => true,
        patch_free_capacity => 0,
        manager_last_error => undefined
    },
    ?assertEqual(blocked_inference, ecai_health:classify_patch_queue(I)).

stalled_queue_test() ->
    I = #{
        manager_active => 0,
        live_workers => 0,
        persisted_running => 0,
        durable_queued => 10,
        learner_ready => true,
        patch_free_capacity => 1,
        manager_last_error => undefined
    },
    ?assertEqual(stalled, ecai_health:classify_patch_queue(I)).

stale_running_test() ->
    I = #{
        manager_active => 0,
        live_workers => 0,
        persisted_running => 2,
        durable_queued => 0,
        learner_ready => true,
        patch_free_capacity => 1,
        manager_last_error => undefined
    },
    ?assertEqual(stale_running, ecai_health:classify_patch_queue(I)).


manager_only_queue_is_not_idle_test() ->
    I = #{
        manager_active => 0,
        live_workers => 0,
        persisted_running => 0,
        manager_queued => 4,
        durable_queued => 0,
        learner_ready => true,
        patch_free_capacity => 1,
        manager_last_error => undefined
    },
    ?assertEqual(stalled, ecai_health:classify_patch_queue(I)).

healthy_idle_overall_is_go_test() ->
    ?assertEqual(go, ecai_health:classify_overall(healthy_overall_fixture())).

healthy_working_queue_is_busy_test() ->
    D0 = healthy_overall_fixture(),
    D = D0#{patch_queue => #{state => working}},
    ?assertEqual(busy, ecai_health:classify_overall(D)).

idle_not_ready_learner_is_degraded_test() ->
    D0 = healthy_overall_fixture(),
    D = D0#{learner => #{phase => idle, ready => false}},
    ?assertEqual(degraded, ecai_health:classify_overall(D)).

validated_repairs_without_integration_job_is_degraded_test() ->
    D0 = healthy_overall_fixture(),
    D = D0#{
        integration => #{
            diagnostic_state => validated_repairs_pending_integration
        }
    },
    ?assertEqual(degraded, ecai_health:classify_overall(D)).

component_api_failure_is_degraded_test() ->
    D0 = healthy_overall_fixture(),
    D = D0#{patch_manager => #{status => error, error => timeout}},
    ?assertEqual(degraded, ecai_health:classify_overall(D)).

healthy_overall_fixture() ->
    #{
        processes => #{all_required_up => true},
        store => #{},
        learner => #{phase => idle, ready => true},
        inference_pool => #{},
        inference => #{status => healthy},
        patch_manager => #{},
        reconciler => #{},
        integration => #{diagnostic_state => waiting_for_validated_repairs},
        patch_queue => #{state => idle}
    }.
