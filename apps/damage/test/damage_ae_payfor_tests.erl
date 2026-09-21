%% Staged PayingFor orchestration against the current TEST-only callback seams.
%% No live node, signing operation, secrets lookup or process-dictionary backend
%% injection is used. Actual builder/cryptography integration needs separate tests.
-module(damage_ae_payfor_tests).
-include_lib("eunit/include/eunit.hrl").
-define(AE, damage_ae).
-define(HASH, <<"th_public_disposable_test_fixture">>).
-define(SIGNED, <<"tx_signed_fixture">>).
-define(SECRET, <<"PAYFOR-SECRET-SENTINEL-NEVER-LOG-OR-RETURN">>).

signing_keypair_normalizes_and_strips_fields_test() ->
    PublicBytes = <<1:256>>,
    Public = aeser_api_encoder:encode(account_pubkey, PublicBytes),
    %% Shape fixture only; never used for cryptographic signing.
    Private = <<0:256, PublicBytes/binary>>,
    lists:foreach(fun(Address) ->
        Result = ?AE:tracked_keypair(#{public_key => Address, private_key => Private,
                                      mnemonic => ?SECRET}),
        ?assertEqual({ok, #{public_key => Public, private_key => Private}}, Result),
        assert_no_secret(Result)
    end, [Public, binary_to_list(Public)]).

preparation_exceptions_never_submit_or_leak_test_() ->
    [?_test(assert_preparation_exception(Class)) || Class <- [error, throw, exit]].

assert_preparation_exception(Class) ->
    {Result, Calls} = capture_calls(fun(Record) ->
        ?AE:safe_payfor_attempt(
            fun() -> Record(prepare), raise_fixture(Class) end,
            fun(S, H) -> Record({submit, S, H}), unexpected end)
    end),
    ?assertEqual({not_submitted, payfor_prepare_failed}, Result),
    ?assertEqual([prepare], Calls),
    assert_no_secret(Result).

malformed_preparation_results_never_submit_test_() ->
    [?_test(begin
        {Result, Calls} = capture_calls(fun(Record) ->
            ?AE:safe_payfor_attempt(fun() -> Prepared end,
                fun(S, H) -> Record({submit, S, H}), unexpected end)
        end),
        ?assertEqual({not_submitted, payfor_prepare_failed}, Result),
        ?assertEqual([], Calls),
        assert_no_secret(Result)
    end) || Prepared <- [{error, #{private_key => ?SECRET}}, {unexpected, ?SECRET},
                         {ok, ?SIGNED, undefined}, {ok, not_binary, ?HASH}]].

submission_callback_exceptions_retain_hash_test_() ->
    [?_test(begin
        {Result, Calls} = capture_calls(fun(Record) ->
            ?AE:safe_payfor_attempt(fun() -> {ok, ?SIGNED, ?HASH} end,
                fun(S, H) -> Record({submit, S, H}), raise_fixture(Class) end)
        end),
        ?assertEqual({uncertain, ?HASH, payfor_submission_outcome_unknown}, Result),
        ?assertEqual([{submit, ?SIGNED, ?HASH}], Calls),
        assert_no_secret(Result)
    end) || Class <- [error, throw, exit]].

post_exceptions_are_observed_without_retry_test_() ->
    [?_test(assert_post_exception(Class)) || Class <- [error, throw, exit]].

assert_post_exception(Class) ->
    {Result, Calls} = capture_calls(fun(Record) ->
        ?AE:safe_payfor_submit(?SIGNED, ?HASH,
            fun(S) -> Record({post, S}), raise_fixture(Class) end,
            fun(H) -> Record({wait, H}), {error, #{private_key => ?SECRET}} end)
    end),
    ?assertMatch({uncertain, ?HASH, #{status := submission_unknown,
        submission := #{status := unavailable, error_code := <<"post_exception">>}}}, Result),
    ?assertEqual([{post, ?SIGNED}, {wait, ?HASH}], Calls),
    assert_no_secret(Result).

returned_post_failures_do_not_leak_test_() ->
    [?_test(begin
        {Result, Calls} = capture_calls(fun(Record) ->
            ?AE:safe_payfor_submit(?SIGNED, ?HASH,
                fun(S) -> Record({post, S}), PostReply end,
                fun(H) -> Record({wait, H}), {error, not_found} end)
        end),
        ?assertMatch({uncertain, ?HASH, #{status := submission_unknown}}, Result),
        ?assertEqual([{post, ?SIGNED}, {wait, ?HASH}], Calls),
        assert_no_secret(Result)
    end) || PostReply <- [{error, #{private_key => ?SECRET}}, {unexpected, ?SECRET},
                         {ok, #{tx_hash => ?SECRET}}]].

receipt_exceptions_remain_uncertain_test_() ->
    [?_test(begin
        {Result, Calls} = capture_calls(fun(Record) ->
            ?AE:safe_payfor_submit(?SIGNED, ?HASH,
                fun(S) -> Record({post, S}), {ok, #{tx_hash => ?HASH}} end,
                fun(H) -> Record({wait, H}), raise_fixture(Class) end)
        end),
        ?assertMatch({uncertain, ?HASH, #{status := submitted,
                                        reason := transaction_confirmation_unavailable}}, Result),
        ?assertEqual([{post, ?SIGNED}, {wait, ?HASH}], Calls),
        assert_no_secret(Result)
    end) || Class <- [error, throw, exit]].

returned_poll_error_is_not_a_confirmation_test() ->
    Result = ?AE:safe_payfor_submit(?SIGNED, ?HASH,
        fun(_) -> {ok, #{tx_hash => ?HASH}} end,
        fun(_) -> {error, {tx_poll_timeout, #{private_key => ?SECRET}}} end),
    ?assertMatch({uncertain, ?HASH, #{status := submitted}}, Result),
    assert_no_secret(Result).

terminal_receipt_preserves_staged_tuple_test_() ->
    %% 'confirmed' here means a mined receipt, including revert/VM error.
    [?_test(begin
        Call = #{height => 1, return_type => Type},
        {Result, Calls} = capture_calls(fun(Record) ->
            ?AE:safe_payfor_attempt(fun() -> Record(prepare), {ok, ?SIGNED, ?HASH} end,
                fun(S, H) ->
                    ?AE:safe_payfor_submit(S, H,
                        fun(Tx) -> Record({post, Tx}), {ok, #{tx_hash => H}} end,
                        fun(Hash) -> Record({wait, Hash}), Call end)
                end)
        end),
        ?assertEqual({confirmed, ?HASH, Call}, Result),
        ?assertEqual([prepare, {post, ?SIGNED}, {wait, ?HASH}], Calls)
    end) || Type <- [ok, revert, error]].

malformed_keypairs_are_not_echoed_test() ->
    Result = ?AE:contract_call_payfor_user_safe(
        #{private_key => ?SECRET}, ignored, ignored, ignored, []),
    ?assertEqual({not_submitted, keypair_required}, Result),
    assert_no_secret(Result).

payer_spellings_use_shared_nonce_locks_test_() ->
    {timeout, 10, fun payer_spellings_use_shared_nonce_locks/0}.

payer_spellings_use_shared_nonce_locks() ->
    Parent = self(), Ref = make_ref(),
    Caller = <<"ak_payfor_caller_fixture">>, Payer = <<"ak_payfor_payer_fixture">>,
    {Pid, Monitor} = spawn_monitor(fun() ->
        %% Only the lock/session orchestration is exercised; no node is needed.
        put({damage_ae, tx_session}, #{node_id => test_node, conn_pid => self()}),
        Result = ?AE:safe_payfor_locked([binary_to_list(Payer), Caller, Payer], fun() ->
            Parent ! {Ref, locked},
            receive {Ref, release} -> ok after 5000 -> error(release_timeout) end
        end),
        Parent ! {Ref, result, Result}
    end),
    try
        receive {Ref, locked} -> ok after 2000 -> error(lock_timeout) end,
        ?assertEqual(false, probe_lock(Caller)),
        ?assertEqual(false, probe_lock(Payer)),
        Pid ! {Ref, release},
        receive {Ref, result, Result} -> ?assertEqual(ok, Result)
        after 2000 -> error(result_timeout) end,
        ?assertEqual(true, probe_lock(Caller)),
        ?assertEqual(true, probe_lock(Payer))
    after
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush])
    end.

probe_lock(Account) ->
    Id = {{damage_ae, tx_nonce, Account}, self()},
    case global:set_lock(Id, [node()], 0) of
        true -> global:del_lock(Id, [node()]), true;
        false -> false
    end.

raise_fixture(error) -> erlang:error({badmatch, ?SECRET});
raise_fixture(throw) -> throw({secret_payload, ?SECRET});
raise_fixture(exit) -> exit({secret_payload, ?SECRET}).

capture_calls(Fun) ->
    Ref = make_ref(),
    put(Ref, []),
    Record = fun(Call) -> put(Ref, [Call | get(Ref)]), ok end,
    try
        Result = Fun(Record),
        {Result, lists:reverse(get(Ref))}
    after erase(Ref) end.

assert_no_secret(Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), ?SECRET)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~tp", [Term])), ?SECRET)).
