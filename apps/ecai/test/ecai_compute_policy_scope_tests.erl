-module(ecai_compute_policy_scope_tests).
-include_lib("eunit/include/eunit.hrl").

policy_scope_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) -> [
        ?_test(preserves_other_domain()),
        ?_test(rejects_cross_domain_fields()),
        ?_test(reservations_remain_guarded()),
        ?_test(new_account_defaults())
    ] end}.

compute(N) -> #{<<"remote_enabled">> => true, <<"monthly_cents">> => N,
    <<"per_job_cents">> => 50}.
mint(N) -> #{<<"enabled">> => true, <<"recipient">> => recipient(),
    <<"chain">> => <<"aeternity">>, <<"monthly_cents">> => N}.
recipient() -> <<"ak_12345678901234567890123456789012345">>.
snapshot(O) -> {ok, S} = ecai_compute_settings:snapshot(O), S.

preserves_other_domain() ->
    O = <<"scope-owner">>,
    {ok, _} = ecai_compute_settings:prepare_provider(O, <<"aws_batch">>),
    Before = snapshot(O),
    {ok, _} = ecai_compute_settings:put_compute_budget(O, compute(700)),
    {ok, _} = ecai_compute_settings:put_mint_policy(O, mint(90)),
    {ok, _} = ecai_compute_settings:put_compute_budget(O, compute(1100)),
    A = snapshot(O),
    ?assertEqual(maps:without([<<"monthly_cents">>], mint(90)), maps:get(<<"mint">>, A)),
    ?assertEqual(90, maps:get(<<"mint_monthly_cents">>, maps:get(<<"budget">>, A))),
    {ok, _} = ecai_compute_settings:put_mint_policy(O, mint(150)),
    B = snapshot(O),
    ?assertEqual(compute(1100), maps:without([<<"mint_monthly_cents">>], maps:get(<<"budget">>, B))),
    ?assertEqual(maps:get(<<"provider_setup">>, Before), maps:get(<<"provider_setup">>, B)).

rejects_cross_domain_fields() ->
    O = <<"reject-owner">>,
    Before = snapshot(O),
    ?assertMatch({error, _}, ecai_compute_settings:put_compute_budget(O,
        (compute(100))#{<<"mint_monthly_cents">> => 500})),
    ?assertMatch({error, _}, ecai_compute_settings:put_mint_policy(O,
        (mint(100))#{<<"remote_enabled">> => true})),
    lists:foreach(fun(Bad) ->
        ?assertMatch({error, _}, ecai_compute_settings:put_compute_budget(O,
            (compute(100))#{<<"monthly_cents">> => Bad}))
    end, [-1, 1.5, <<"100">>, 100000001]),
    ?assertMatch({error, _}, ecai_compute_settings:put_mint_policy(O,
        (mint(100))#{<<"chain">> => <<"unexpected">>})),
    ?assertMatch({error, _}, ecai_compute_settings:put_compute_budget(O, #{})),
    ?assertMatch({error, _}, ecai_compute_settings:put_mint_policy(O, null)),
    ?assertEqual(Before, snapshot(O)).

reservations_remain_guarded() ->
    O = <<"reserved-owner">>,
    {ok, _} = ecai_compute_settings:put_mint_policy(O, mint(100)),
    Metadata = #{<<"manifest_sha256">> => binary:copy(<<"a">>, 64)},
    {ok, Intent} = ecai_compute_settings:request_mint(O, <<"job-reserved">>, Metadata, recipient(), 80),
    ?assertEqual({error, below_reserved_mint_budget}, ecai_compute_settings:put_mint_policy(O, mint(79))),
    {ok, _} = ecai_compute_settings:put_compute_budget(O, compute(250)),
    S = snapshot(O),
    ?assertEqual(80, maps:get(<<"reserved_mint_cents">>, S)),
    ?assertEqual([Intent], maps:get(<<"mint_requests">>, S)).

new_account_defaults() ->
    O = <<"new-owner">>,
    {ok, _} = ecai_compute_settings:put_compute_budget(O, compute(300)),
    S = snapshot(O),
    ?assertEqual(false, maps:get(<<"enabled">>, maps:get(<<"mint">>, S))),
    ?assertEqual(0, maps:get(<<"mint_monthly_cents">>, maps:get(<<"budget">>, S))).

setup() ->
    Path = filename:join("/tmp", "ecai-policy-scope-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"),
    {ok, Pid} = ecai_compute_settings:start_link(#{path => Path}),
    {Pid, Path}.
cleanup({Pid, Path}) ->
    gen_server:stop(Pid), file:delete(Path).
