-module(ecai_patch_retry_cluster_tests).

-include_lib("eunit/include/eunit.hrl").

%% Pure classification tests: no processes, network, timing or application env.
atom_and_binary_node_labels_test() ->
    lists:foreach(fun(Node) ->
        lists:foreach(fun(Reason) ->
            assert_cluster_result(true, [{Node, Reason}])
        end, [gun_not_started, timeout, noproc, econnrefused])
    end, [node0, <<"node-a">>]).

tagged_no_eligible_errors_keep_their_tags_test() ->
    Reasons = [
        no_eligible_ollama_node,
        {no_eligible_ollama_node, []},
        {no_eligible_ollama_node, patch, cooldown},
        no_eligible_inference_node,
        {no_eligible_inference_node, []},
        {no_eligible_inference_node, patch, any, undefined},
        {inference_queue_timeout, patch, any, undefined}
    ],
    lists:foreach(fun(Reason) ->
        %% Test each reason on its own. A second transient entry must not
        %% mask a broken branch through lists:any/2.
        ?assert(ecai_patch_retry:is_retryable(Reason)),
        assert_cluster_result(true, [Reason]),
        lists:foreach(fun(Node) ->
            assert_cluster_result(true, [{Node, Reason}])
        end, [node0, <<"node-a">>])
    end, Reasons).

supported_reason_wrappers_remain_retryable_test() ->
    Reasons = [
        {error, {await_response_failed, timeout}},
        {ollama_request_failed, {await_body_failed, closed}},
        {inference_pool_exit, noproc},
        {inference_pool_exception, exit, shutdown},
        {inference_failed, {no_eligible_inference_node, []}}
    ],
    lists:foreach(fun(Reason) ->
        assert_cluster_result(true, [{node0, Reason}])
    end, Reasons).

nested_recognized_cluster_errors_test() ->
    Inner = {ollama_cluster_failed, chat, [{node1, timeout}]},
    assert_cluster_result(true, [
        {node0, {inference_failed, Inner}}
    ]),
    assert_cluster_result(true, [
        {<<"provider-a">>, {error, Inner}}
    ]).

permanent_reason_metadata_does_not_enable_retry_test() ->
    Reasons = [
        invalid_model_response,
        {invalid_patch, timeout},
        {invalid_model_response, shutdown},
        {http_status, 401, timeout},
        {unknown_error, patch, [timeout]}
    ],
    lists:foreach(fun(Reason) ->
        ?assertNot(ecai_patch_retry:is_retryable(Reason)),
        lists:foreach(fun(Node) ->
            assert_cluster_result(false, [{Node, Reason}])
        end, [node0, <<"node-a">>])
    end, Reasons),
    %% An unknown multi-field tuple is not a container to scan for atoms.
    assert_cluster_result(false, [{unknown_error, patch, timeout}]).

node_label_is_not_itself_an_error_test() ->
    lists:foreach(fun(Node) ->
        assert_cluster_result(false, [{Node, invalid_model_response}])
    end, [timeout, shutdown, gun_not_started, <<"timeout">>]).

mixed_cluster_uses_any_transient_outcome_test() ->
    Permanent = {node0, invalid_model_response},
    Transient = {node1, {no_eligible_inference_node, []}},
    assert_cluster_result(true, [Permanent, Transient]),
    assert_cluster_result(true, [Transient, Permanent]),
    assert_cluster_result(false, [Permanent]),
    assert_cluster_result(false, []).

public_boundary_does_not_unwrap_arbitrary_atom_pairs_test() ->
    ?assertNot(ecai_patch_retry:is_retryable({node0, timeout})),
    ?assertNot(ecai_patch_retry:is_retryable({invalid_patch, timeout})),
    %% Preserve the existing explicitly supported binary-provider boundary.
    ?assert(ecai_patch_retry:is_retryable({<<"provider-a">>, timeout})).

assert_cluster_result(Expected, Entries) ->
    %% Existing two-field, role-bearing and extended cluster representations.
    Errors = [
        {ollama_cluster_failed, Entries},
        {ollama_cluster_failed, patch, Entries},
        {inference_cluster_failed, Entries},
        {inference_cluster_failed, patch, Entries},
        {inference_cluster_failed, patch, provider, Entries}
    ],
    lists:foreach(fun(Error) ->
        ?assertEqual({Expected, Error},
            {ecai_patch_retry:is_retryable(Error), Error})
    end, Errors).
