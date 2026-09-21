%% Staged submission orchestration only: external operations use process-local
%% TEST-only fakes. No AE node, signing service or production secrets is touched.
%% Wallet cryptography itself is exercised by damage_ae_wallet_tests.
-module(damage_ae_payfor_tests).
-include_lib("eunit/include/eunit.hrl").
-export([log/2]).

-define(PAYER, <<"ak_21SBPc3yHP7bpQDvD1KMKzZZEgLtSXpDsK97LTjVwjiskra6Ka">>).
-define(USER, <<"ak_adaN7iK8L5nanM5tmNdGTYy9aqcn84ZwJNpK8A8w4zPrt7Uya">>).
-define(TX_HASH, <<"th_public_disposable_test_fixture">>).
-define(SECRET, <<"PAYFOR-SECRET-SENTINEL-NEVER-LOG-OR-RETURN">>).

payfor_test_() ->
    {setup, fun() -> {module, damage_ae} = code:ensure_loaded(damage_ae), ok end,
     fun(_) -> ok end,
     {inorder, [fun binary_and_charlist_payers_reach_both_builds/0,
      fun payer_spellings_share_a_lock/0,
      fun keypair_loading_normalizes_and_scrubs/0,
      fun preparation_failures_do_not_submit_or_leak/0,
      fun post_failures_remain_uncertain_and_redacted/0,
      fun confirmation_failures_remain_uncertain_and_redacted/0,
      fun fixed_codes_do_not_serialize_arbitrary_terms/0,
      fun successful_staged_call_preserves_result/0,
      fun malformed_keypairs_are_not_echoed/0]}}.

binary_and_charlist_payers_reach_both_builds() ->
    lists:foreach(fun(Payer) ->
        with_backend(fun fake/2, fun() ->
            ?assertEqual({ok, <<"tx_signed_fixture">>}, prepare(Payer)),
            Calls = calls(),
            PayerBuilds = [Args || {paying_for, Args} <- Calls],
            ?assertEqual(2, length(PayerBuilds)),
            [[InitialAddress, 7, 1000, _], [FinalAddress, 7, 52000, _]] = PayerBuilds,
            ?assertEqual(?PAYER, InitialAddress),
            ?assertEqual(?PAYER, FinalAddress),
            ?assertEqual([[?USER], [?PAYER]], [A || {next_nonce, A} <- Calls]),
            ?assertEqual([], [C || {post_tx, _} = C <- Calls])
        end)
    end, [?PAYER, binary_to_list(?PAYER)]).

payer_spellings_share_a_lock() ->
    ?assertEqual(damage_ae:payfor_submission_lock_id(?PAYER),
                 damage_ae:payfor_submission_lock_id(binary_to_list(?PAYER))).

keypair_loading_normalizes_and_scrubs() ->
    with_backend(fun
        (node_keypair, []) ->
            (keypair())#{public_key => binary_to_list(?PAYER), mnemonic => ?SECRET};
        (Name, Args) -> fake(Name, Args)
    end, fun() ->
        {ok, KP} = damage_ae:safe_node_keypair(),
        ?assertEqual(keypair(), KP),
        assert_no_secret(KP)
    end),
    {Result, Events} = captured(fun() ->
        with_backend(fun(node_keypair, []) -> erlang:error({badmatch, ?SECRET}) end,
            fun damage_ae:safe_node_keypair/0)
    end),
    ?assertEqual({error, {node_keypair_failed, error, <<"badmatch">>}}, Result),
    assert_no_secret({Result, Events}).

preparation_failures_do_not_submit_or_leak() ->
    lists:foreach(fun(Class) ->
        {Result, Events} = captured(fun() ->
            with_backend(fun
                (prepare_contract, _) -> raise_fixture(Class);
                (Name, Args) -> fake(Name, Args)
            end, fun() ->
                Reply = safe_call(),
                ?assertMatch({not_submitted, {prepare_payfor_user_tx_failed, Class, _}}, Reply),
                ?assertEqual([], [C || {post_tx, _} = C <- calls()]),
                Reply
            end)
        end),
        assert_no_secret({Result, Events})
    end, [error, throw, exit]).

post_failures_remain_uncertain_and_redacted() ->
    lists:foreach(fun(Class) ->
        {Result, Events} = captured(fun() ->
            with_backend(fun(post_tx, _) -> raise_fixture(Class) end,
                fun() -> damage_ae:post_payfor_user_tx(<<"tx_fixture">>) end)
        end),
        ?assertMatch({uncertain, undefined, {post_tx_crashed, Class, _}}, Result),
        assert_no_secret({Result, Events})
    end, [error, throw, exit]),
    %% Returned backend failures are just as sensitive as thrown exceptions.
    lists:foreach(fun(BackendReply) ->
        with_backend(fun(post_tx, _) -> BackendReply end, fun() ->
            Reply = damage_ae:post_payfor_user_tx(<<"tx_fixture">>),
            ?assertMatch({uncertain, undefined, _}, Reply),
            assert_no_secret(Reply)
        end)
    end, [{error, #{private_key => ?SECRET}}, {unexpected, ?SECRET}]).

confirmation_failures_remain_uncertain_and_redacted() ->
    lists:foreach(fun(Class) ->
        {Result, Events} = captured(fun() ->
            with_backend(fun(wait_tx, _) -> raise_fixture(Class) end,
                fun() -> damage_ae:confirm_payfor_user_tx(?TX_HASH) end)
        end),
        ?assertMatch({uncertain, ?TX_HASH, {wait_tx_failed, Class, _}}, Result),
        assert_no_secret({Result, Events})
    end, [error, throw, exit]).

fixed_codes_do_not_serialize_arbitrary_terms() ->
    %% Includes an atom and charlist, not just a binary secret. A formatter or
    %% "redact known map keys" implementation would miss these shapes.
    SecretAtom = 'PAYFOR-SECRET-SENTINEL-NEVER-LOG-OR-RETURN',
    Inputs = [?SECRET, binary_to_list(?SECRET), SecretAtom,
              #{unrecognized_field => ?SECRET}, {error, ?SECRET}],
    lists:foreach(fun(Input) ->
        ?assertEqual(<<"redacted">>, damage_ae:compact_payfor_error(Input)),
        assert_no_secret(damage_ae:finish_payfor_submission({aborted, Input})),
        assert_no_secret(damage_ae:finish_payfor_submission({unexpected, Input}))
    end, Inputs),
    ?assertEqual(<<"badmatch">>, damage_ae:compact_payfor_error({badmatch, ?SECRET})),
    ?assertEqual(<<"timeout">>, damage_ae:compact_payfor_error({timeout, ?SECRET})).

successful_staged_call_preserves_result() ->
    with_backend(fun fake/2, fun() ->
        ?assertEqual({confirmed, ?TX_HASH, #{return_type => ok}}, safe_call()),
        ?assertEqual(1, length([C || {post_tx, _} = C <- calls()])),
        ?assertEqual(1, length([C || {wait_tx, _} = C <- calls()]))
    end).

malformed_keypairs_are_not_echoed() ->
    Bad = #{private_key => ?SECRET},
    Reply = damage_ae:contract_call_payfor_user_safe(Bad, ignored, ignored, ignored, []),
    ?assertEqual({not_submitted, {keypair_required, <<"redacted">>}}, Reply),
    assert_no_secret(Reply).

prepare(Payer) ->
    damage_ae:prepare_payfor_user_signed_tx(
        ?USER, <<1:512>>, <<"ct_fixture">>, "fixture.aes", "call", [],
        (keypair())#{public_key => Payer}).
safe_call() ->
    damage_ae:contract_call_payfor_user_safe(
        #{public_key => ?USER, private_key => <<1:512>>},
        <<"ct_fixture">>, "fixture.aes", "call", []).
keypair() -> #{public_key => ?PAYER, private_key => <<0:512>>}.

fake(node_keypair, []) -> keypair();
fake(next_nonce, [Address]) when is_binary(Address) -> {ok, 7};
fake(min_fee, []) -> 1000;
fake(min_gas, []) -> 50000;
fake(min_gas_price, []) -> 2;
fake(prepare_contract, [_]) -> {ok, fixture_aci};
fake(contract_call, [Address, _, _, _, _, _, _, _, _, _]) when is_binary(Address) ->
    {ok, <<"tx_inner_fixture">>};
fake(sign, [Private, _]) when byte_size(Private) =:= 64 -> <<"sg_fixture">>;
fake(attach_signature, [_, _]) -> <<"tx_signed_fixture">>;
fake(decode, [<<"tx_paying_fixture">>]) -> {transaction, <<0:800>>};
fake(decode, [_]) -> {transaction, <<0:80>>};
fake(paying_for, [Address, _, _, _]) when is_binary(Address) -> {ok, <<"tx_paying_fixture">>};
fake(paying_for_gas, [_, _]) -> 26000;
fake(post_tx, [_]) -> {ok, #{"tx_hash" => ?TX_HASH}};
fake(wait_tx, [_]) -> #{return_type => ok}.

raise_fixture(error) -> erlang:error({badmatch, ?SECRET});
raise_fixture(throw) -> throw({secret_payload, ?SECRET});
raise_fixture(exit) -> exit({secret_payload, ?SECRET}).

with_backend(Backend, Fun) ->
    OldCalls = put({?MODULE, calls}, []),
    Old = put({damage_ae, test_payfor_backend}, fun(Name, Args) ->
        put({?MODULE, calls}, [{Name, Args} | get({?MODULE, calls})]),
        Backend(Name, Args)
    end),
    try Fun()
    after
        restore({damage_ae, test_payfor_backend}, Old),
        restore({?MODULE, calls}, OldCalls)
    end.
calls() -> lists:reverse(get({?MODULE, calls})).
restore(Key, undefined) -> erase(Key), ok;
restore(Key, Value) -> put(Key, Value), ok.

captured(Fun) ->
    Ref = make_ref(),
    Handler = damage_payfor_test_capture,
    ok = logger:add_handler(Handler, ?MODULE,
        #{level => all, config => #{owner => self(), reference => Ref}}),
    try
        Result = Fun(),
        Events = receive
            {Ref, First} -> collect(Ref, [First])
        after 1000 -> error(missing_payfor_error_log)
        end,
        {Result, Events}
    after logger:remove_handler(Handler) end.
collect(Ref, Acc) ->
    receive {Ref, Event} -> collect(Ref, [Event | Acc])
    after 0 -> lists:reverse(Acc)
    end.
log(Event, #{config := #{owner := Owner, reference := Ref}}) ->
    Owner ! {Ref, Event}, ok.
assert_no_secret(Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), ?SECRET)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~tp", [Term])), ?SECRET)).
