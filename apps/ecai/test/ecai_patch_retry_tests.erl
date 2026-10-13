-module(ecai_patch_retry_tests).

-include_lib("eunit/include/eunit.hrl").

queue_timeout_is_retryable_test() ->
    Error = {inference_failed, {inference_queue_timeout, patch, any, undefined}},
    ?assert(ecai_patch_retry:is_retryable(Error)).

nested_ollama_timeout_is_retryable_test() ->
    Error = {ollama_failed, {inference_failed, {inference_queue_timeout, patch, any, undefined}}},
    ?assert(ecai_patch_retry:is_retryable(Error)).

semantic_patch_error_is_not_retryable_test() ->
    ?assertNot(
        ecai_patch_retry:is_retryable(
            {invalid_patch, not_git_unified_diff}
        )
    ).

backoff_is_exponential_and_capped_test() ->
    Opts = #{retry_base_ms => 1000, retry_max_ms => 5000},
    ?assertEqual(1000, ecai_patch_retry:backoff_ms(1, Opts)),
    ?assertEqual(2000, ecai_patch_retry:backoff_ms(2, Opts)),
    ?assertEqual(4000, ecai_patch_retry:backoff_ms(3, Opts)),
    ?assertEqual(5000, ecai_patch_retry:backoff_ms(4, Opts)),
    ?assertEqual(5000, ecai_patch_retry:backoff_ms(20, Opts)).

retry_wait_due_test() ->
    ?assert(
        ecai_patch_retry:due(
            #{status => retry_wait, next_retry_at_ms => 100}, 100
        )
    ),
    ?assertNot(
        ecai_patch_retry:due(
            #{status => retry_wait, next_retry_at_ms => 101}, 100
        )
    ).

cluster_no_node_is_retryable_test() ->
    Error =
        {ollama_cluster_failed, patch, [
            {node0, gun_not_started},
            {node1, {no_eligible_ollama_node, patch, cooldown}}
        ]},
    ?assert(ecai_patch_retry:is_retryable(Error)).
