-module(damage_enterprise_invoices_tests).
-include_lib("eunit/include/eunit.hrl").
-define(S, damage_enterprise_invoices).
-define(B, damage_invoice_test_backend).
-define(ADMIN, <<"ak_TestNodeAdmin">>).
-define(BILLER, <<"ak_TestBiller">>).

service_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun(_) -> ?_test(roles()) end,
      fun(_) -> ?_test(period_idempotency()) end,
      fun(_) -> ?_test(concurrent_generation()) end,
      fun(_) -> ?_test(snapshot_and_payment()) end,
      fun(_) -> ?_test(render_retry_number()) end,
      fun(_) -> ?_test(smtp_acceptance()) end,
      fun(_) -> ?_test(smtp_unknown()) end,
      fun(_) -> ?_test(restart_during_smtp()) end,
      fun(_) -> ?_test(failed_persistence()) end,
      fun(_) -> ?_test(locked_service()) end,
      fun(_) -> ?_test(scheduled_catchup()) end,
      fun(_) -> ?_test(scheduled_auto_send()) end,
      fun(_) -> ?_test(global_gate()) end,
      fun(_) -> ?_test(optout_before_smtp()) end]}.
setup() ->
    Keys = [enterprise_invoices,node_admins,invoice_admins,l402_account],
    Previous = [{K,application:get_env(damage,K)} || K <- Keys],
    ok = ?B:reset(),
    application:set_env(damage,node_admins,[?ADMIN]),
    application:set_env(damage,invoice_admins,[?BILLER]),
    application:set_env(damage,l402_account,<<"ak_SharedPayer">>),
    application:set_env(damage,enterprise_invoices,[{enabled,true},{auto_send,false},
        {backend,?B},{number_prefix,<<"TEST-ENT">>},{job_timeout_ms,5000}]),
    start(), Previous.
cleanup(Previous) ->
    stop(), ?B:destroy(),
    [case Value of {ok,V} -> application:set_env(damage,K,V);
                   undefined -> application:unset_env(damage,K) end || {K,Value} <- Previous], ok.
start() -> {ok,Pid} = ?S:start_link(), unlink(Pid), ok.
stop() -> case whereis(?S) of undefined -> ok; Pid -> gen_server:stop(Pid) end.
request(C) -> ?S:request(?ADMIN,C).
get_invoice(Id) -> {ok,I} = request({get_invoice,Id}), I.
revision(I) -> #{<<"revision">> => maps:get(revision,I)}.
roles() ->
    ?assertMatch({error,forbidden},?S:request(<<"ak_Ordinary">>,session)),
    application:set_env(damage,invoice_admins,[?BILLER,<<"ak_SharedPayer">>]),
    ?assertMatch({error,forbidden},?S:request(<<"ak_SharedPayer">>,session)),
    ?assertMatch({ok,#{role := invoice_admin}},?S:request(?BILLER,session)),
    ?assertMatch({error,forbidden},?S:request(?BILLER,list_admins)),
    ?assertMatch({error,forbidden},?S:request(?BILLER,{set_admin,#{}})),
    ?assertMatch({ok,_},request({set_admin,#{<<"account">> => <<"ak_ABC123">>,<<"enabled">> => true}})),
    ?assertMatch({ok,#{role := invoice_admin}},?S:request(<<"ak_ABC123">>,session)),
    {ok,_} = request({set_admin,#{<<"account">> => <<"ak_ABC123">>,<<"enabled">> => false}}),
    ?assertMatch({error,forbidden},?S:request(<<"ak_ABC123">>,session)).
period_idempotency() ->
    seed(), {ok,I} = generate(), Id = maps:get(id,I),
    ?assertEqual({ok,I},generate()), stop(), start(),
    ?assertEqual({ok,I},generate()),
    {ok,#{items := [P]}} = request({list,plans}),
    ?assertEqual(1,maps:get(generated_count,P)),
    ?assertEqual(<<"2026-11-09">>,maps:get(next_date,P)),
    ?assertMatch({error,{conflict,_}},request({edit_invoice,Id,#{<<"revision">> => 0}})).
concurrent_generation() ->
    seed(), Owner = self(),
    [spawn(fun() -> Owner ! {done,generate()} end) || _ <- lists:seq(1,12)],
    Replies = [receive {done,R} -> R after 2000 -> timeout end || _ <- lists:seq(1,12)],
    ?assertEqual(12,length([ok || {ok,_} <- Replies])),
    ?assertEqual(1,length(lists:usort([maps:get(id,I) || {ok,I} <- Replies]))).
snapshot_and_payment() ->
    seed(), I = issue(), Id = maps:get(id,I),
    {ok,#{items := [C]}} = request({list,customers}),
    {ok,_} = request({save_customer,<<"fixture">>,#{<<"revision">> => maps:get(revision,C),<<"name">> => <<"Changed">>}}),
    ?assertEqual(<<"Fixture enterprise">>,maps:get(name,maps:get(customer,get_invoice(Id)))),
    ?assertMatch({error,{validation,_}},request({edit_invoice,Id,(revision(I))#{<<"notes">> => <<"change">>}})),
    {pdf,Number,PDF} = request({get_pdf,Id}),
    {ok,_} = request({action,Id,<<"paid">>,(revision(I))#{<<"paid_on">> => <<"2026-10-09">>,
        <<"payment_reference">> => <<"TEST-TRANSACTION">>,<<"note">> => <<"Verified test payment">>}}),
    ?assertEqual(<<"paid">>,maps:get(status,get_invoice(Id))),
    ?assertEqual({pdf,Number,PDF},request({get_pdf,Id})),
    ?assertEqual(0,?B:get(sends)).
render_retry_number() ->
    seed(), ?B:set(render_mode,fail), {ok,D} = generate(), Id = maps:get(id,D),
    {ok,Pending} = request({action,Id,<<"issue">>,revision(D)}),
    Failed = wait_status(Id,<<"issue_failed">>), ?B:set(render_mode,ok),
    {ok,_} = request({action,Id,<<"issue">>,revision(Failed)}),
    I = wait_status(Id,<<"issued">>),
    ?assertEqual(maps:get(number,Pending),maps:get(number,I)),
    ?assertEqual(1,maps:get(sequence,?B:get(data))).
smtp_acceptance() ->
    seed(), I = issue(), Id = maps:get(id,I),
    {ok,_} = request({action,Id,<<"send">>,revision(I)}),
    Sent = wait_delivery(Id,<<"sent">>),
    ?assertEqual(1,?B:get(sends)),
    ?assertMatch({error,{conflict,_}},request({action,Id,<<"send">>,revision(Sent)})),
    stop(), start(), request(session), ?S:tick(), timer:sleep(40),
    ?assertEqual(1,?B:get(sends)).
smtp_unknown() ->
    seed(), I = issue(), Id = maps:get(id,I), ?B:set(send_mode,fail),
    {ok,_} = request({action,Id,<<"send">>,revision(I)}),
    Unknown = wait_delivery(Id,<<"unknown">>),
    ?assertMatch({error,{conflict,_}},request({action,Id,<<"send">>,revision(Unknown)})),
    ?B:set(send_mode,accepted),
    {ok,_} = request({action,Id,<<"send">>,(revision(Unknown))#{<<"confirm_resend">> => true}}),
    wait_delivery(Id,<<"sent">>), ?assertEqual(2,?B:get(sends)).
restart_during_smtp() ->
    seed(), I = issue(), Id = maps:get(id,I), ?B:set(send_mode,block),
    {ok,_} = request({action,Id,<<"send">>,revision(I)}),
    wait_delivery(Id,<<"sending">>),
    await(fun() -> ?B:get(sends) =:= 1 end),
    Pid = whereis(?S), Ref = monitor(process,Pid), exit(Pid,kill),
    receive {'DOWN',Ref,process,Pid,_} -> ok after 2000 -> error(stop_timeout) end,
    ?B:set(send_mode,accepted), start(),
    ?assertEqual(<<"unknown">>,maps:get(status,maps:get(delivery,get_invoice(Id)))),
    ?S:tick(), timer:sleep(40), ?assertEqual(1,?B:get(sends)).
failed_persistence() ->
    seed(), I = issue(), Id = maps:get(id,I), ?B:set(fail_save,true),
    ?assertMatch({error,unavailable},request({action,Id,<<"send">>,revision(I)})),
    timer:sleep(40), ?assertEqual(0,?B:get(sends)),
    ?B:set(fail_save,false),
    ?assertEqual(<<"not_sent">>,maps:get(status,maps:get(delivery,get_invoice(Id)))).
locked_service() ->
    seed(), ?B:set(ready,false),
    ?assertEqual({error,unavailable},request({list,customers})),
    ?S:tick(), timer:sleep(20), ?assertEqual(0,?B:get(sends)).
scheduled_catchup() ->
    seed(), {ok,#{items := [P]}} = request({list,plans}),
    {ok,_} = request({save_plan,<<"retainer">>,#{<<"revision">> => maps:get(revision,P),
        <<"enabled">> => true,<<"auto_send">> => true,<<"start_date">> => <<"2026-08-09">>}}),
    Cfg = application:get_env(damage,enterprise_invoices,[]),
    application:set_env(damage,enterprise_invoices,lists:keystore(auto_send,1,Cfg,{auto_send,true})),
    ?S:tick(),
    await(fun() -> case request({list_invoices,#{}}) of {ok,#{total := 1}} -> true; _ -> false end end),
    {ok,#{items := [I]}} = request({list_invoices,#{}}),
    ?assertEqual(<<"2026-08-09">>,maps:get(period_start,I)),
    ?assertEqual(<<"draft">>,maps:get(status,I)), ?assertEqual(0,?B:get(sends)).
scheduled_auto_send() ->
    enable_plan(true), ?S:tick(),
    I = wait_single_invoice(), wait_delivery(maps:get(id,I),<<"sent">>),
    ?assertEqual(1,?B:get(sends)).
global_gate() ->
    enable_plan(false), ?S:tick(), I = wait_single_invoice(),
    ?assertEqual(<<"draft">>,maps:get(status,I)), ?assertEqual(0,?B:get(sends)).
optout_before_smtp() ->
    enable_plan(true), ?B:set(prepare_mode,block), ?S:tick(),
    I = wait_single_invoice(),
    await(fun() -> try is_pid(?B:get(prepare_pid)) catch _:_ -> false end end),
    Cfg = application:get_env(damage,enterprise_invoices,[]),
    application:set_env(damage,enterprise_invoices,lists:keystore(auto_send,1,Cfg,{auto_send,false})),
    ?B:get(prepare_pid) ! release,
    wait_delivery(maps:get(id,I),<<"cancelled">>), ?assertEqual(0,?B:get(sends)).
enable_plan(GlobalAuto) ->
    seed(), {ok,#{items := [P]}} = request({list,plans}),
    {ok,_} = request({save_plan,<<"retainer">>,#{<<"revision">> => maps:get(revision,P),
        <<"enabled">> => true, <<"auto_send">> => true}}),
    Cfg = application:get_env(damage,enterprise_invoices,[]),
    application:set_env(damage,enterprise_invoices,lists:keystore(auto_send,1,Cfg,{auto_send,GlobalAuto})).
wait_single_invoice() ->
    await(fun() -> case request({list_invoices,#{}}) of {ok,#{total := 1}} -> true; _ -> false end end),
    {ok,#{items := [I]}} = request({list_invoices,#{}}), I.
seed() ->
    {ok,_} = request({save_customer,<<"fixture">>,#{<<"name">> => <<"Fixture enterprise">>,
        <<"email">> => <<"billing@example.invalid">>,<<"enabled">> => true}}),
    {ok,_} = request({save_plan,<<"retainer">>,#{<<"customer_id">> => <<"fixture">>,
        <<"name">> => <<"Monthly support">>,<<"start_date">> => <<"2026-10-09">>,
        <<"items">> => [#{<<"description">> => <<"Support">>,<<"unit_price_minor">> => 85000}]}}), ok.
generate() -> request({generate,<<"retainer">>,#{<<"period_start">> => <<"2026-10-09">>}}).
issue() ->
    {ok,D} = generate(), Id = maps:get(id,D),
    {ok,_} = request({action,Id,<<"issue">>,revision(D)}), wait_status(Id,<<"issued">>).
wait_status(Id,Status) -> await(fun() -> maps:get(status,get_invoice(Id)) =:= Status end),get_invoice(Id).
wait_delivery(Id,Status) -> await(fun() -> maps:get(status,maps:get(delivery,get_invoice(Id))) =:= Status end),get_invoice(Id).
await(F) -> await(F,200).
await(F,0) -> ?assert(F());
await(F,N) -> case F() of true -> ok; false -> timer:sleep(10),await(F,N-1) end.
