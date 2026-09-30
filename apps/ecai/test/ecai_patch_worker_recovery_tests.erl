-module(ecai_patch_worker_recovery_tests).

-include_lib("eunit/include/eunit.hrl").

unknown_provider_wrapper_patch_test() ->
    Patch = valid_patch(),
    Wrapped = #{
        <<"vendor_envelope">> => #{
            <<"choice_payload">> => [
                #{
                    <<"message_body">> => Patch
                }
            ]
        }
    },
    ?assertEqual(
        {ok, ecai_patch_verifier:normalize_patch(Patch)},
        ecai_patch_worker:normalize_proposal_patch(Wrapped)
    ).

unknown_provider_wrapper_without_diff_test() ->
    Wrapped = #{
        <<"vendor_envelope">> => #{
            <<"choice_payload">> => [
                #{<<"message_body">> => <<"not a patch">>}
            ]
        }
    },
    ?assertEqual(
        {error, {invalid_patch_type, map}},
        ecai_patch_worker:normalize_proposal_patch(Wrapped)
    ).

terminal_invalid_patch_drops_stale_attempt_payload_test() ->
    Stale = #{
        status => running,
        attempt => 3,
        patch => valid_patch(),
        patch_sha256 => <<"old-patch">>,
        patch_file => <<"/tmp/old.patch">>,
        verifier_output => #{status => failed},
        summary => <<"old summary">>
    },
    Repair0 = #{
        status => failed,
        attempt => 3,
        error => {invalid_patch, {invalid_patch_type, map}},
        failure_class => invalid_patch
    },
    Merged = maps:merge(Stale, Repair0),
    Clean = ecai_patch_worker:clear_stale_attempt_payload(
        Repair0, Merged
    ),
    ?assertNot(maps:is_key(patch, Clean)),
    ?assertNot(maps:is_key(patch_sha256, Clean)),
    ?assertNot(maps:is_key(patch_file, Clean)),
    ?assertNot(maps:is_key(verifier_output, Clean)),
    ?assertNot(maps:is_key(summary, Clean)),
    ?assertEqual(
        {invalid_patch, {invalid_patch_type, map}},
        maps:get(error, Clean)
    ).

terminal_verification_failure_keeps_current_payload_test() ->
    Patch = valid_patch(),
    Repair0 = #{
        status => failed,
        patch => Patch,
        patch_sha256 => <<"current">>,
        patch_file => <<"/tmp/current.patch">>,
        verifier_output => #{status => failed}
    },
    Clean = ecai_patch_worker:clear_stale_attempt_payload(
        Repair0, Repair0
    ),
    ?assertEqual(Patch, maps:get(patch, Clean)),
    ?assertEqual(
        #{status => failed},
        maps:get(verifier_output, Clean)
    ).

valid_patch() ->
    <<
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\n"
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>.

inference_provenance_is_sanitized_test() ->
    Opts = ecai_patch_worker:record_inference_attempt(
        2,
        #{
            provider => ollama,
            node_id => <<"razorjack">>,
            role => patch,
            model => <<"qwen3-coder:30b">>,
            model_digest => <<"digest">>,
            host => <<"192.168.1.185">>,
            port => 11434,
            authorization => <<"secret">>,
            api_key => <<"secret">>
        },
        #{}
    ),
    Repair = ecai_patch_worker:attach_inference_state(
        #{status => failed}, Opts
    ),
    Meta = maps:get(inference_meta, Repair),
    ?assertEqual(<<"razorjack">>, maps:get(node_id, Meta)),
    ?assertEqual(<<"qwen3-coder:30b">>, maps:get(model, Meta)),
    ?assertNot(maps:is_key(authorization, Meta)),
    ?assertNot(maps:is_key(api_key, Meta)).

inference_response_shape_is_correlated_with_node_test() ->
    Opts0 = ecai_patch_worker:record_inference_attempt(
        1,
        #{provider => ollama, node_id => <<"razorjack">>},
        #{}
    ),
    Shape = #{
        response_type => map,
        response_keys => [<<"details">>, <<"risks">>, <<"summary">>],
        patch_candidate_found => false,
        diff_binary_found => false
    },
    Opts = ecai_patch_worker:record_inference_response(Shape, Opts0),
    Repair = ecai_patch_worker:attach_inference_state(
        #{status => failed}, Opts
    ),
    [Entry] = maps:get(inference_history, Repair),
    ?assertEqual(<<"razorjack">>, maps:get(node_id, Entry)),
    ?assertEqual(Shape, maps:get(response_shape, Entry)).

inference_history_is_bounded_test() ->
    Opts = lists:foldl(
        fun(Attempt, Acc) ->
            ecai_patch_worker:record_inference_attempt(
                Attempt,
                #{
                    provider => ollama,
                    node_id => integer_to_binary(Attempt)
                },
                Acc
            )
        end,
        #{},
        lists:seq(1, 20)
    ),
    Repair = ecai_patch_worker:attach_inference_state(
        #{status => failed}, Opts
    ),
    History = maps:get(inference_history, Repair),
    ?assertEqual(16, length(History)),
    ?assertEqual(5, maps:get(attempt, hd(History))),
    ?assertEqual(20, maps:get(attempt, lists:last(History))).

verifier_retry_contract_forbids_error_object_test() ->
    Contract = ecai_patch_worker:retry_response_contract(#{
        repair_retry => #{kind => verifier_rejected_patch}
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(Contract, <<"MUST NOT return an error object">>)
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(Contract, <<"Regenerate the ENTIRE diff">>)
    ).

verification_retry_diagnostic_is_corrective_test() ->
    Diagnostic = ecai_patch_worker:verification_retry_diagnostic(
        #{
            status => failed,
            base_commit => <<"0123456789012345678901234567890123456789">>,
            steps => [#{
                step => patch_apply_check,
                result => #{
                    ok => false,
                    exit_status => 128,
                    output => <<"error: corrupt patch at line 39">>
                }
            }]
        },
        1
    ),
    Decoded = jsx:decode(Diagnostic, [return_maps]),
    ?assertEqual(
        <<"verifier_rejected_patch">>,
        maps:get(<<"retry_kind">>, Decoded)
    ),
    Instruction = maps:get(<<"retry_instruction">>, Decoded),
    ?assertNotEqual(
        nomatch,
        binary:match(Instruction, <<"Do not return an error object">>)
    ).

stale_proposal_shape_is_cleared_for_new_failure_test() ->
    OldShape = #{
        response_type => map,
        response_keys => [<<"error">>],
        patch_candidate_found => false,
        diff_binary_found => false
    },
    FreshFailure = #{
        status => failed,
        error => verification_failed
    },
    Merged = FreshFailure#{proposal_shape => OldShape},
    Clean = ecai_patch_worker:clear_stale_attempt_payload(
        FreshFailure, Merged
    ),
    ?assertNot(maps:is_key(proposal_shape, Clean)).


compact_patch_context_drops_bulk_source_bodies_test() ->
    Context = #{
        application => damage,
        module => damage_l402,
        finding => #{<<"title">> => <<"test">>},
        finding_version => <<"version">>,
        source_path => <<"apps/damage/src/damage_l402.erl">>,
        base_commit => <<"0123456789012345678901234567890123456789">>,
        source => <<"target-source">>,
        analysis => #{
            source_sha256 => <<"source-hash">>,
            analysis_sha256 => <<"analysis-hash">>,
            exports => [{verify_token, 3}],
            source => <<"must-not-leak">>,
            remote_calls => lists:duplicate(100, #{module => crypto})
        },
        module_knowledge => #{<<"notes">> => <<"large-card">>},
        global_knowledge => #{<<"notes">> => <<"large-global-card">>},
        analogous_repairs => [#{patch => <<"old-patch">>}],
        related_modules => [#{
            application => damage,
            module => helper,
            source => <<"related-source-must-not-leak">>,
            knowledge => #{<<"notes">> => <<"large">>}
        }]
    },
    Compact = ecai_patch_worker:compact_patch_context(Context),
    ?assertNot(maps:is_key(source, Compact)),
    ?assertNot(maps:is_key(module_knowledge, Compact)),
    ?assertNot(maps:is_key(global_knowledge, Compact)),
    ?assertNot(maps:is_key(analogous_repairs, Compact)),
    Analysis = maps:get(analysis, Compact),
    ?assertNot(maps:is_key(source, Analysis)),
    ?assertNot(maps:is_key(remote_calls, Analysis)),
    [Related] = maps:get(related_modules, Compact),
    ?assertEqual(helper, maps:get(module, Related)),
    ?assertNot(maps:is_key(source, Related)).

retry_source_prefers_verifier_base_source_test() ->
    Path = <<"apps/damage/src/damage_l402.erl">>,
    Context = #{source_path => Path, source => <<"context-source">>},
    Opts = #{repair_retry_sources => [#{
        path => Path,
        source => <<"verifier-base-source">>
    }]},
    ?assertEqual(
        {<<"verifier-base-source">>, verifier_failure_source},
        ecai_patch_worker:prompt_target_source(Context, Opts)
    ).

patch_prompt_places_authoritative_source_after_aux_context_test() ->
    Source = <<"-module(damage_l402).\nverify_token(A,B,C) -> ok.\n">>,
    RelatedSource = <<"THIS_RELATED_SOURCE_MUST_NOT_APPEAR">>,
    Context = #{
        application => damage,
        module => damage_l402,
        finding => #{<<"title">> => <<"test">>},
        finding_version => <<"version">>,
        source_path => <<"apps/damage/src/damage_l402.erl">>,
        base_commit => <<"0123456789012345678901234567890123456789">>,
        source => Source,
        analysis => #{source_sha256 => <<"hash">>},
        related_modules => [#{
            application => damage,
            module => helper,
            source => RelatedSource
        }]
    },
    Prompt = ecai_patch_worker:patch_prompt(Context, <<"retry-info">>, 2, #{}),
    ?assertEqual(nomatch, binary:match(Prompt, RelatedSource)),
    {AuxPos, _} = binary:match(Prompt, <<"AUXILIARY_CONTEXT_JSON:">>),
    {DiagPos, _} = binary:match(Prompt, <<"PREVIOUS_ATTEMPT_DIAGNOSTIC:">>),
    {SourcePos, _} = binary:match(Prompt, <<"AUTHORITATIVE_TARGET_SOURCE:">>),
    {ContractPos, _} = binary:match(Prompt, <<"FINAL_RESPONSE_CONTRACT:">>),
    ?assert(AuxPos < DiagPos),
    ?assert(DiagPos < SourcePos),
    ?assert(SourcePos < ContractPos),
    ?assertNotEqual(nomatch, binary:match(Prompt, Source)).

prompt_provenance_records_source_identity_test() ->
    Source = <<"exact-source\n">>,
    Context = #{source_path => <<"apps/damage/src/damage_l402.erl">>, source => Source},
    Meta = ecai_patch_worker:prompt_provenance(Context, <<"prompt">>, #{}),
    ?assertEqual(6, maps:get(prompt_bytes, Meta)),
    ?assertEqual(byte_size(Source), maps:get(prompt_source_bytes, Meta)),
    ?assertEqual(context_snapshot, maps:get(prompt_source_origin, Meta)),
    ?assertEqual(
        64,
        byte_size(maps:get(prompt_source_sha256, Meta))
    ).
