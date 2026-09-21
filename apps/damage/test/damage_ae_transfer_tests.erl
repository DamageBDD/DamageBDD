-module(damage_ae_transfer_tests).
-include_lib("eunit/include/eunit.hrl").
-define(AE, damage_ae).

same_final_bytes_are_simulated_and_returned_test() ->
    Ref = make_ref(),
    put(Ref, 0),
    Final = <<"tx_exact-final-transaction">>,
    Prepare = fun() -> put(Ref, get(Ref) + 1), Final end,
    DryRun = fun(Tx) -> ?assertEqual(Final, Tx), ok end,
    try
        ?assertEqual({ok, Final}, ?AE:checked_contract_tx(Prepare, DryRun)),
        ?assertEqual(1, get(Ref))
    after erase(Ref) end.

charlist_tx_normalized_before_dry_run_test() ->
    ?assertEqual({ok, <<"tx_final">>},
        ?AE:checked_contract_tx(fun() -> "tx_final" end,
                               fun(Tx) -> ?assertEqual(<<"tx_final">>, Tx), ok end)).

failed_preflight_does_not_return_signable_tx_test() ->
    Rejection = {error, #{status => rejected, stage => preflight, reason => contract_reverted}},
    ?assertEqual(Rejection,
        ?AE:checked_contract_tx(fun() -> <<"tx_final">> end, fun(_) -> Rejection end)).

prepare_and_dry_exceptions_do_not_leak_terms_test() ->
    ?assertEqual({error, transaction_prepare_failed},
        ?AE:checked_contract_tx(fun() -> error({secret, <<"PRIVATE">>}) end,
                               fun(_) -> error(must_not_run) end)),
    ?assertEqual({error, transaction_preflight_unavailable},
        ?AE:checked_contract_tx(fun() -> <<"tx_final">> end,
                               fun(_) -> error({secret, <<"PRIVATE">>}) end)).

missing_preflight_return_type_fails_closed_test() ->
    ?assertEqual({error, transaction_preflight_unavailable},
        ?AE:tracked_dry_reply({ok, #{<<"results">> => [#{<<"call_obj">> => #{}}]}})).

mixed_key_preflight_results_test() ->
    ?assertEqual(ok, ?AE:tracked_dry_reply({ok, #{<<"results">> => [#{
        <<"result">> => <<"ok">>, <<"call_obj">> => #{<<"return_type">> => <<"ok">>}}]}})),
    ?assertEqual(ok, ?AE:tracked_dry_reply({ok, #{results => [#{
        result => ok, call_obj => #{return_type => ok}}]}})),
    ?assertMatch({error, #{status := rejected, reason := contract_reverted}},
        ?AE:tracked_dry_reply({ok, #{"results" => [#{"call_obj" => #{
            "return_type" => "revert", <<"return_type">> => <<"ok">>,
            "return_value" => <<"RAW SECRET">>}}]}})).

preflight_transaction_rejection_test() ->
    ?assertEqual({error, #{status => rejected, stage => preflight, reason => transaction_rejected}},
        ?AE:tracked_dry_reply({ok, #{"results" => [#{"result" => "error", "reason" => <<"RAW">>}]}})).

reject_multiple_dry_results_test() ->
    One = #{"call_obj" => #{"return_type" => "ok"}},
    ?assertEqual({error, transaction_preflight_unavailable},
        ?AE:tracked_dry_reply({ok, #{"results" => [One, One]}})).

confirmation_timeout_retains_hash_test() ->
    Hash = <<"th_known">>,
    ?assertEqual({ok, #{status => submitted, tx_hash => Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {ok, #{"tx_hash" => Hash}} end,
            fun(H) -> ?assertEqual(Hash, H), {error, read_timeout} end)).

confirmation_crash_retains_hash_test() ->
    Hash = <<"th_known">>,
    ?assertEqual({ok, #{status => submitted, tx_hash => Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {ok, #{tx_hash => Hash}} end,
            fun(_) -> exit({timeout_error, secret_term}) end)).

broadcast_timeout_is_unknown_and_never_retried_test() ->
    Ref = make_ref(), put(Ref, 0), Hash = <<"th_local">>,
    Post = fun(_) -> put(Ref, get(Ref) + 1), exit(timeout) end,
    try
        ?assertMatch({ok, #{status := submission_unknown, tx_hash := Hash}},
            ?AE:tracked_submit(<<"tx_signed">>, Hash, Post, fun(_) -> {error, read_timeout} end)),
        ?assertEqual(1, get(Ref))
    after erase(Ref) end.

lost_ack_but_mined_receipt_is_confirmed_test() ->
    Hash = <<"th_local">>,
    ?assertMatch({ok, #{status := confirmed, tx_hash := Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {error, timeout} end,
            fun(_) -> {ok, confirmed} end)).

unexpected_ack_hash_never_changes_polled_hash_test() ->
    Hash = <<"th_local">>,
    ?assertMatch({ok, #{status := submission_unknown, tx_hash := Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {ok, #{<<"tx_hash">> => <<"th_someone_else">>}} end,
            fun(H) -> ?assertEqual(Hash, H), {error, read_timeout} end)).

mined_revert_is_rejected_not_submitted_test() ->
    Hash = <<"th_local">>,
    ?assertEqual({error, #{status => rejected, stage => execution,
                          reason => contract_reverted, tx_hash => Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {ok, #{"tx_hash" => "th_local"}} end,
            fun(_) -> {ok, {rejected, contract_reverted}} end)).

receipt_requires_positive_height_and_known_return_type_test() ->
    ?assertEqual(confirmed, ?AE:tracked_mined_reply({ok, #{<<"call_info">> => #{
        <<"height">> => 1, <<"return_type">> => <<"ok">>}}})),
    ?assertEqual(not_ready, ?AE:tracked_mined_reply({ok, #{"call_info" => #{
        "height" => -1, "return_type" => "ok"}}})),
    ?assertEqual(not_ready, ?AE:tracked_mined_reply({ok, #{"call_info" => #{
        "height" => 10}}})),
    ?assertEqual({rejected, contract_error}, ?AE:tracked_mined_reply({ok, #{call_info => #{
        height => 10, return_type => error}}})).

builder_error_never_reaches_preflight_test() ->
    ?assertEqual({error, transaction_prepare_failed},
        ?AE:checked_contract_tx(fun() -> {error, unavailable} end,
                               fun(_) -> error(must_not_run) end)).

estimator_revert_is_a_preflight_rejection_test() ->
    ?assertEqual({error, #{status => rejected, stage => preflight, reason => contract_reverted}},
        ?AE:checked_contract_tx(fun() ->
            {error, {contract_gas_estimation_rejected, contract_call_tx,
                     {dry_run_revert, <<"PRIVATE CONTRACT DETAIL">>}}}
        end, fun(_) -> error(must_not_run) end)).

disabled_or_unsupported_dry_run_fails_closed_test() ->
    lists:foreach(fun(Reason) ->
        ?assertEqual({error, transaction_preflight_unavailable},
            ?AE:tracked_dry_reply({error, {dry_run_unsupported, Reason}}))
    end, [disabled_by_config, cached_endpoint_unavailable]).

runtime_preflight_error_is_rejected_test() ->
    ?assertEqual({error, #{status => rejected, stage => preflight, reason => contract_error}},
        ?AE:tracked_dry_reply({ok, #{results => [#{result => ok,
            call_obj => #{return_type => error, return_value => <<"PRIVATE DETAIL">>}}]}})).

signing_key_account_mismatch_rejected_test() ->
    Owner = aeser_api_encoder:encode(account_pubkey, <<1:256>>),
    WrongPrivate = <<0:256, 2:256>>,
    ?assertEqual({error, invalid_signing_keypair},
        ?AE:tracked_keypair(#{public_key => Owner, private_key => WrongPrivate})),
    %% The key is rejected before any node checkout, transaction build or write.
    ?assertEqual({error, invalid_signing_keypair},
        ?AE:contract_call_tracked(#{public_key => Owner, private_key => WrongPrivate},
                                 <<"ct_unused">>, "unused.aes", "transfer", [])).

signing_key_normalization_and_field_stripping_test() ->
    PublicBytes = <<1:256>>,
    Public = aeser_api_encoder:encode(account_pubkey, PublicBytes),
    %% Shape-validation fixture only, not a private key used to sign a tx.
    Private = <<0:256, PublicBytes/binary>>,
    ?assertEqual({ok, #{public_key => Public, private_key => Private}},
        ?AE:tracked_keypair(#{public_key => binary_to_list(Public),
                             private_key => Private, unrelated => ignored})).

invalid_signing_key_sizes_fail_closed_test() ->
    lists:foreach(fun(Private) ->
        ?assertEqual({error, invalid_signing_keypair},
            ?AE:tracked_keypair(#{public_key => <<"ak_unused">>, private_key => Private}))
    end, [none, undefined, <<>>, <<0:256>>, <<0:504>>, <<0:520>>]).

tracked_scope_retains_existing_pinned_session_test() ->
    SessionKey = {damage_ae, tx_session},
    Existing = get(SessionKey),
    Session = #{node_id => test_pinned_node, conn_pid => self()},
    put(SessionKey, Session),
    try
        ?assertEqual(Session, ?AE:tracked_locked(<<"ak_session_fixture">>,
                                                fun() -> get(SessionKey) end)),
        ?assertEqual(Session, get(SessionKey))
    after
        case Existing of undefined -> erase(SessionKey); _ -> put(SessionKey, Existing) end
    end.

shared_nonce_lock_serializes_tracked_and_legacy_paths_test_() ->
    {timeout, 10, fun shared_nonce_lock_serializes_tracked_and_legacy_paths/0}.

shared_nonce_lock_serializes_tracked_and_legacy_paths() ->
    Parent = self(), Ref = make_ref(), Account = <<"ak_shared_lock_fixture">>,
    {First, FirstMonitor} = spawn_monitor(fun() ->
        %% This is the existing direct-call/deployment/PayingFor lock namespace.
        ?AE:with_account_nonce_locks([Account], fun() ->
            Parent ! {Ref, first_locked},
            receive {Ref, release} -> ok end
        end)
    end),
    try
        receive {Ref, first_locked} -> ok after 2000 -> error(first_lock_timeout) end,
        {Second, SecondMonitor} = spawn_monitor(fun() ->
            put({damage_ae, tx_session}, #{node_id => test_pinned_node}),
            Parent ! {Ref, attempting},
            Result = ?AE:tracked_locked(Account, fun() -> Parent ! {Ref, second_locked}, ok end),
            Parent ! {Ref, result, Result}
        end),
        try
            receive {Ref, attempting} -> ok after 2000 -> error(second_start_timeout) end,
            receive {Ref, second_locked} -> error(overlapping_account_submissions)
            after 40 -> ok end,
            First ! {Ref, release},
            receive {Ref, second_locked} -> ok after 5000 -> error(second_lock_timeout) end,
            receive {Ref, result, Result} -> ?assertEqual(ok, Result)
            after 1000 -> error(second_result_timeout) end
        after
            exit(Second, kill), erlang:demonitor(SecondMonitor, [flush])
        end
    after
        exit(First, kill), erlang:demonitor(FirstMonitor, [flush])
    end.

nonce_error_does_not_automatically_rebroadcast_test() ->
    Ref = make_ref(), put(Ref, 0), Hash = <<"th_local">>,
    Post = fun(_) ->
        put(Ref, get(Ref) + 1),
        {error, {tx_rejected, #{http_status => 400, error_code => <<"nonce_too_low">>}}}
    end,
    try
        ?assertMatch({ok, #{status := submission_unknown, tx_hash := Hash}},
            ?AE:tracked_submit(<<"tx_signed">>, Hash, Post, fun(_) -> {error, timeout} end)),
        ?assertEqual(1, get(Ref))
    after erase(Ref) end.

already_known_ack_retains_local_hash_test() ->
    Hash = <<"th_local">>,
    ?assertEqual({ok, #{status => submitted, tx_hash => Hash}},
        ?AE:tracked_submit(<<"tx_signed">>, Hash,
            fun(_) -> {ok, #{"tx_hash" => Hash, already_known => true}} end,
            fun(_) -> {error, timeout} end)).

%% A hashing utility vector only; these are not bytes of a broadcast transaction.
%% Expected digest: Blake2b with an output length of 32, not truncated Blake2b-512.
signed_envelope_hash_vector_test() ->
    SignedBytes = <<"tracked-transfer-test-vector">>,
    Encoded = aeser_api_encoder:encode(transaction, SignedBytes),
    ExpectedDigest = <<16#ac,16#91,16#9e,16#0d,16#fd,16#9d,16#9b,16#3a,16#27,16#c7,16#ad,16#3e,16#11,16#49,16#d9,16#6a,16#17,16#eb,16#45,16#e2,16#e9,16#1d,16#15,16#2c,16#d7,16#1a,16#b2,16#1c,16#aa,16#79,16#15,16#a5>>,
    ?assertEqual(aeser_api_encoder:encode(tx_hash, ExpectedDigest), ?AE:tracked_tx_hash(Encoded)).

%% Remaining review regressions: submission evidence and legacy safe path.
explicit_nonce_rejection_uses_one_probe_test() ->
    Hash = <<"th_local">>, Ref = make_ref(), put(Ref, 0),
    Post = fun(_) ->
        put(Ref, get(Ref) + 1),
        {error, {tx_rejected, #{http_status => 400, error_code => <<"nonce_too_high">>,
                               reason => <<"SECRET">>, headers => [secret]}}}
    end,
    try
        ?assertEqual({ok, #{status => submission_unknown, tx_hash => Hash,
            submission => #{stage => submission, status => node_rejected,
                            error_code => <<"nonce_too_high">>, http_status => 400}}},
            ?AE:tracked_submit(<<"tx_signed">>, Hash, Post,
                #{once => fun(H) -> ?assertEqual(Hash, H), {error, not_found} end,
                  wait => fun(_) -> error(full_wait_must_not_run) end})),
        ?assertEqual(1, get(Ref))
    after erase(Ref) end.

%% Use counters, not exceptions alone, to detect an unexpected observer call:
%% production intentionally catches observer failures and preserves uncertainty.
observer_selection_test_() ->
    [?_test(assert_observer_mode(Status, Code, Expected)) ||
        {Status, Code, Expected} <- [
            {400, <<"nonce_too_low">>, once},
            {400, nonce_already_used, once},
            {400, "account_nonce_too_high", once},
            {400, <<"unknown_private_reason">>, wait},
            {401, <<"nonce_too_low">>, wait},
            {403, <<"nonce_too_low">>, wait},
            {429, <<"nonce_too_low">>, wait},
            {500, <<"nonce_too_low">>, wait},
            {503, <<"nonce_too_low">>, wait},
            {<<"400">>, <<"nonce_too_low">>, wait}]].

assert_observer_mode(Status, Code, Expected) ->
    Ref = make_ref(), put(Ref, []),
    Observer = fun(Mode) -> fun(_) -> put(Ref, [Mode | get(Ref)]), not_ready end end,
    try
        ?assertMatch({ok, #{status := submission_unknown, tx_hash := <<"th_local">>}},
            ?AE:tracked_submit(<<"tx_signed">>, <<"th_local">>,
                fun(_) -> {error, {tx_rejected, #{http_status => Status, error_code => Code}}} end,
                #{once => Observer(once), wait => Observer(wait)})),
        ?assertEqual([Expected], get(Ref))
    after erase(Ref) end.

mined_receipt_overrides_local_node_rejection_test() ->
    Hash = <<"th_local">>,
    {ok, Outcome} = ?AE:tracked_submit(<<"tx_signed">>, Hash,
        fun(_) -> {error, {tx_rejected, #{http_status => 400, error_code => <<"nonce_too_low">>}}} end,
        #{once => fun(H) -> ?assertEqual(Hash, H), {ok, confirmed} end}),
    ?assertEqual(confirmed, maps:get(status, Outcome)),
    ?assertEqual(Hash, maps:get(tx_hash, Outcome)),
    ?assertEqual(node_rejected, maps:get(status, maps:get(submission, Outcome))).

mined_revert_retains_submission_evidence_test() ->
    {error, Outcome} = ?AE:tracked_submit(<<"tx_signed">>, <<"th_local">>,
        fun(_) -> {error, {tx_rejected, #{http_status => 400, error_code => <<"nonce_too_low">>}}} end,
        #{once => fun(_) -> {ok, {rejected, contract_reverted}} end}),
    ?assertMatch(#{status := rejected, stage := execution, tx_hash := <<"th_local">>,
        reason := contract_reverted, submission := #{status := node_rejected}}, Outcome).

submission_metadata_is_allowlisted_test() ->
    {Outcome, wait} = ?AE:tracked_submission(<<"th_local">>,
        {error, {tx_rejected, #{http_status => 503, error_code => <<"SECRET-CODE">>,
            response => #{password => <<"SECRET">>}, headers => [secret], reason => <<"SECRET">>}}}),
    ?assertEqual(#{stage => submission, status => http_error,
                  http_status => 503, error_code => <<"unknown_error">>},
                 maps:get(submission, Outcome)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Outcome), <<"SECRET">>)).

malformed_error_code_is_not_echoed_test_() ->
    [?_test(begin
        {O, wait} = ?AE:tracked_submission(<<"th_local">>,
            {error, {tx_rejected, #{http_status => 400, error_code => Code}}}),
        ?assertEqual(<<"unknown_error">>, maps:get(error_code, maps:get(submission, O)))
    end) || Code <- [#{private_key => <<"SECRET">>}, [<<"SECRET">>],
                    lists:duplicate(65, $a), <<255>>, 42, undefined]].

safe_prepare_failure_never_submits_test() ->
    Ref = make_ref(), put(Ref, 0),
    Submit = fun(_, _) -> put(Ref, get(Ref) + 1) end,
    try
        ?assertEqual({not_submitted, payfor_prepare_failed},
            ?AE:safe_payfor_attempt(fun() -> error({private_key, <<"SECRET">>}) end, Submit)),
        ?assertEqual({not_submitted, payfor_prepare_failed},
            ?AE:safe_payfor_attempt(fun() -> {error, bad_fee} end, Submit)),
        ?assertEqual(0, get(Ref))
    after erase(Ref) end.

safe_submit_exception_retains_precomputed_hash_test() ->
    ?assertEqual({uncertain, <<"th_local">>, payfor_submission_outcome_unknown},
        ?AE:safe_payfor_attempt(fun() -> {ok, <<"tx_signed">>, <<"th_local">>} end,
            fun(_, _) -> exit({private_key, <<"SECRET">>}) end)).

safe_returned_wait_error_is_not_confirmed_test() ->
    ?assertMatch({uncertain, <<"th_local">>, #{status := submitted}},
        ?AE:safe_payfor_submit(<<"tx_signed">>, <<"th_local">>,
            fun(_) -> {ok, #{tx_hash => <<"th_local">>}} end,
            fun(_) -> {error, {tx_poll_timeout, #{}}} end)).

safe_lost_ack_can_still_confirm_test() ->
    Call = #{height => 1, return_type => ok},
    ?assertEqual({confirmed, <<"th_local">>, Call},
        ?AE:safe_payfor_submit(<<"tx_signed">>, <<"th_local">>,
            fun(_) -> exit(timeout) end, fun(_) -> Call end)).

safe_nonce_rejection_uses_short_probe_test() ->
    Ref = make_ref(), put(Ref, []),
    try
        ?assertMatch({uncertain, <<"th_local">>, #{submission := #{status := node_rejected}}},
            ?AE:safe_payfor_submit(<<"tx_signed">>, <<"th_local">>,
                fun(_) -> {error, {tx_rejected, #{http_status => 400,
                                                error_code => <<"nonce_too_low">>}}} end,
                #{once => fun(_) -> put(Ref, [once | get(Ref)]), {error, not_found} end,
                  wait => fun(_) -> put(Ref, [wait | get(Ref)]), not_ready end})),
        ?assertEqual([once], get(Ref))
    after erase(Ref) end.

safe_receipt_requires_terminal_mined_result_test() ->
    lists:foreach(fun(Call) -> ?assertEqual(error, ?AE:safe_payfor_receipt(Call)) end,
        [{error, timeout}, #{}, #{height => -1, return_type => ok},
         #{height => 1}, #{height => 1, return_type => unknown}]),
    lists:foreach(fun(Type) ->
        Call = #{height => 1, return_type => Type},
        ?assertEqual({ok, Call}, ?AE:safe_payfor_receipt(Call))
    end, [ok, revert, error]).

safe_scope_does_not_relabel_operation_error_test() ->
    %% A returned operation error is not evidence of a pre-submission session failure.
    with_fixture_session(fun() ->
        ?assertEqual({error, already_attempted},
            ?AE:safe_payfor_locked([<<"ak_safe_error_fixture">>],
                                  fun() -> {error, already_attempted} end))
    end).

safe_scope_exception_is_uncertain_test() ->
    with_fixture_session(fun() ->
        ?assertEqual({uncertain, undefined, payfor_scope_failed},
            ?AE:safe_payfor_locked([<<"ak_safe_exception_fixture">>],
                                  fun() -> error(after_write) end))
    end).

safe_path_holds_both_shared_locks_at_every_stage_test_() ->
    {timeout, 10, fun safe_path_holds_both_shared_locks_at_every_stage/0}.

safe_path_holds_both_shared_locks_at_every_stage() ->
    Parent = self(), Ref = make_ref(),
    Caller = <<"ak_safe_signer_fixture">>, Payer = <<"ak_safe_payer_fixture">>,
    Call = #{height => 1, return_type => ok},
    Phase = fun(Stage) ->
        Parent ! {Ref, Stage, get({damage_ae, tx_session})},
        receive {Ref, continue, Stage} -> ok after 2000 -> error(stage_timeout) end
    end,
    {Pid, Mon} = spawn_monitor(fun() ->
        with_fixture_session(fun() ->
            R = ?AE:safe_payfor_locked([Payer, Caller, Caller], fun() ->
                ?AE:safe_payfor_attempt(
                    fun() -> Phase(prepare), {ok, <<"tx_signed">>, <<"th_local">>} end,
                    fun(S, H) -> ?AE:safe_payfor_submit(S, H,
                        fun(_) -> Phase(post), {ok, #{tx_hash => H}} end,
                        fun(_) -> Phase(receipt), Call end)
                    end)
            end),
            Parent ! {Ref, done, R}
        end)
    end),
    try
        lists:foreach(fun(Stage) ->
            receive
                {Ref, Stage, Session} ->
                    ?assertEqual(fixture_node, maps:get(node_id, Session))
            after 2000 -> error({stage_missing, Stage}) end,
            %% Synchronous zero-retry probes prove namespace identity without
            %% assuming how long a competing worker takes to get scheduled.
            ?assertEqual(false, probe_shared_lock(Caller)),
            ?assertEqual(false, probe_shared_lock(Payer)),
            Pid ! {Ref, continue, Stage}
        end, [prepare, post, receipt]),
        receive {Ref, done, Result} -> ?assertEqual({confirmed, <<"th_local">>, Call}, Result)
        after 2000 -> error(missing_result) end,
        ?assertEqual(true, probe_shared_lock(Caller)),
        ?assertEqual(true, probe_shared_lock(Payer))
    after exit(Pid, kill), erlang:demonitor(Mon, [flush]) end.

probe_shared_lock(Account) ->
    Id = {{damage_ae, tx_nonce, Account}, self()},
    case global:set_lock(Id, [node()], 0) of
        true -> global:del_lock(Id, [node()]), true;
        false -> false
    end.

with_fixture_session(F) ->
    Key = {damage_ae, tx_session}, Existing = get(Key),
    put(Key, #{node_id => fixture_node, conn_pid => self()}),
    try F()
    after
        case Existing of undefined -> erase(Key); _ -> put(Key, Existing) end
    end.


safe_account_only_error_compatibility_test() ->
    ?assertEqual({not_submitted, {keypair_required, <<"ak_fixture">>}},
        ?AE:contract_call_payfor_user_safe(<<"ak_fixture">>, ignored, ignored, ignored, [])),
    ?assertEqual({not_submitted, keypair_required},
        ?AE:contract_call_payfor_user_safe(#{private_key => <<"SECRET">>},
                                         ignored, ignored, ignored, [])).
