-module(ecai_index_pool_ledger_tests).
-include_lib("eunit/include/eunit.hrl").

per_segment_prices_control_reservations_test() ->
    {Id,S0,[U|_],T} = funded(0),
    S = next({allocate,<<"creator">>,Id,U,<<"worker">>,<<"verifier">>},S0),
    C = campaign(Id,S), P = maps:get(U,maps:get(unit_prices,T)),
    ?assertEqual(maps:get(index_msat,P)+1000,maps:get(reserved_msat,C)),
    ?assertEqual(maps:get(budget_msat,T),maps:get(available_msat,C)+maps:get(reserved_msat,C)).

acceptance_uses_same_quoted_prices_test() ->
    {Id,S0,Ids,T} = funded(20),
    S = lists:foldl(fun(U,Acc) -> decide(Id,U,accept,Acc) end,S0,Ids),
    C = campaign(Id,S),
    lists:foreach(fun(U) ->
        P = maps:get(U,maps:get(unit_prices,T)),
        Amounts = lists:sort([maps:get(amount_msat,X) || X <- maps:get(payouts,C),maps:get(unit_id,X)=:=U]),
        ?assertEqual(lists:sort([maps:get(index_msat,P),maps:get(verify_msat,P)]),Amounts)
    end,Ids),
    ?assertEqual(maps:get(budget_msat,T),maps:get(reserved_msat,C)),
    ?assertEqual(0,maps:get(available_msat,C)).

unpaid_coordinator_does_not_get_a_payout_test() ->
    {Id,S0,[U|_],_} = funded(0),
    C = campaign(Id,decide(Id,U,accept,S0)),
    [P] = maps:get(payouts,C),
    ?assertEqual(index,maps:get(role,P)).

reject_only_earns_verification_test() ->
    {Id,S0,[U|_],T} = funded(20),
    C = campaign(Id,decide(Id,U,reject,S0)), [P] = maps:get(payouts,C),
    Price = maps:get(U,maps:get(unit_prices,T)),
    ?assertEqual(verify,maps:get(role,P)),
    ?assertEqual(maps:get(verify_msat,Price),maps:get(amount_msat,P)),
    ?assertEqual(maps:get(verify_msat,Price)+1000,maps:get(reserved_msat,C)).

malformed_price_tables_rejected_test() ->
    T = terms(20), Ids = maps:get(unit_ids,T), [U|_] = Ids, Ps=maps:get(unit_prices,T),
    ?assertEqual({error,invalid_unit_prices}, change({create,<<"creator">>,<<"bad1">>,T#{unit_prices=>maps:remove(U,Ps)}},ecai_index_reward_ledger:new())),
    ?assertEqual({error,quoted_budget_exceeded}, change({create,<<"creator">>,<<"bad2">>,T#{budget_msat=>1}},ecai_index_reward_ledger:new())).

participant_remains_independent_test() ->
    {Id,S,[U|_],_} = funded(20),
    ?assertEqual({error,independent_verifier_required}, change({allocate,<<"creator">>,Id,U,<<"worker">>,<<"worker">>},S)).

contract_key_cannot_change_the_price_table_test() ->
    {Id,S,_Ids,T}=funded(0),
    ?assert(is_binary(Id)),
    ?assertEqual({error,campaign_key_conflict}, change({create,<<"creator">>,<<"pool-test">>,T#{participation_contract=>hash(changed)}},S)).

legacy_fixed_price_contract_kept_test() ->
    T0=terms(0), T=(maps:without([unit_prices,participation_contract,allocation_policy],T0))#{index_msat=>100000,verify_msat=>10000},
    {ok,C,_,none}=change({create,<<"creator">>,<<"legacy">>,T},ecai_index_reward_ledger:new()),
    ?assertEqual(T,maps:get(terms,C)).

terms(V) ->
    Us=[#{id=>hash({unit,N}),bytes=>N} || N <- [1,2,3]],
    {ok,Q}=ecai_index_pool_budget:quote(Us,1000,V,1),
    (maps:with([budget_msat,index_msat,verify_msat,fee_cap_msat,unit_prices],Q))#{
        plan_root=>hash(plan),unit_ids=>[maps:get(id,U) || U <- Us],
        participation_contract=>hash(contract),allocation_policy=><<"source-bytes-largest-remainder/v1">>}.
funded(V) ->
    T=terms(V), {ok,C,S0,none}=change({create,<<"creator">>,<<"pool-test">>,T},ecai_index_reward_ledger:new()),
    Id=maps:get(id,C), Inv=#{label=>maps:get(funding_label,C),payment_hash=>hash(funding),
        amount_msat=>maps:get(budget_msat,T),amount_received_msat=>maps:get(budget_msat,T),status=><<"paid">>},
    {Id,next({funding_seen,Id,Inv},S0),maps:get(unit_ids,T),T}.
decide(Id,U,V,S0) ->
    S1=next({allocate,<<"creator">>,Id,U,<<"worker">>,<<"verifier">>},S0),
    S2=next({submit,<<"worker">>,Id,U,hash({artifact,U}),hash({evidence,U})},S1),
    S3=next({attest,<<"verifier">>,Id,U,hash({artifact,U}),V,hash({report,U,V})},S2),
    next({accept_work,<<"creator">>,Id,U,hash({artifact,U}),V},S3).
change(C,S) -> ecai_index_reward_ledger:change(C,S,config(),2000000000).
next(C,S) -> {ok,_,N,_}=change(C,S),N.
campaign(Id,S) -> {ok,C}=ecai_index_reward_ledger:campaign(Id,S),C.
hash(T) -> ecai_index_reward_ledger:digest(T).
config() -> #{creators=>[<<"creator">>], participants=>#{<<"creator">>=>ln(1),<<"worker">>=>ln(2),<<"verifier">>=>ln(3)},treasury_node=>ln(4),network=><<"regtest">>,payments_enabled=>false}.
ln(N) -> <<"02",(hash(N))/binary>>.
