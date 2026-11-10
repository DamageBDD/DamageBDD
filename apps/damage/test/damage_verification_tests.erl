%% Run in the complete DamageBDD umbrella. These tests do not need a real AWS
%% account, signer, Lightning node or payment. Live probes require acceptance separately.
-module(damage_verification_tests).
-include_lib("eunit/include/eunit.hrl").

feature_ast_projection_test() ->
    Source= <<"Feature fixture">>,
    AST={1,[<<"@verification">>,<<"@synthetic">>],<<"Example">>,
        [<<"A readable explanation">>],[],[
        {4,<<"A friendly check">>,[],[{5,<<"When">>,<<"I set \"{{input_limit}}\"">>},
            {6,<<"Then">>,<<"the check MUST pass">>}]}]},
    {ok,E}=damage_verification_catalog:from_ast(<<"id">>,Source,AST),
    ?assertEqual(<<"Example">>,maps:get(title,E)),
    ?assertEqual([<<"input_limit">>],maps:get(inputs,E)),
    ?assertEqual(damage_verification_catalog:sha256(Source),maps:get(sha256,E)),
    P=damage_verification_catalog:public(E),
    ?assertNot(maps:is_key(source,P)),?assertNot(maps:is_key(inputs,P)),
    [Scenario]=maps:get(scenarios,P),[Step|_]=maps:get(steps,Scenario),
    ?assertNot(maps:is_key(args,Step)).

variables_include_docstrings_but_not_sections_test() ->
    Steps=[#{text=><<"Use {{input_host}} and {{{raw}}} and {{#loop}}">>,
             args=>{docstring,[<<"{{verification_limit}}">>]}}],
    ?assertEqual([<<"input_host">>,<<"verification_limit">>],
        damage_verification_catalog:placeholders(Steps)).

safe_context_projection_test() ->
    Keys=[<<"input_limit">>,<<"api_secret">>,<<"input_locked">>,<<"public_key">>],
    Snapshot=#{entries=>#{
        <<"api_secret">>=>#{sensitive=>true,value=><<"never-emit-this">>},
        <<"input_locked">>=>#{sensitive=>false,locked=>true,value=><<"fixed">>},
        <<"public_key">>=>#{sensitive=>false,value=><<"trusted">>}}},
    [Input,Secret,Locked,Identity]=damage_verification_catalog:input_fields(Keys,Snapshot),
    ?assert(maps:get(editable,Input)),?assert(is_binary(maps:get(label,Input))),
    ?assertEqual(<<>>,maps:get(value,Secret)),?assertNot(maps:get(editable,Secret)),
    ?assertNot(maps:get(editable,Locked)),?assertNot(maps:get(editable,Identity)),
    ?assertMatch({ok,_},damage_verification_catalog:validate_inputs(Keys,#{<<"input_limit">>=><<"5">>},Snapshot)),
    ?assertMatch({error,invalid_inputs},damage_verification_catalog:validate_inputs(Keys,
        #{<<"input_limit">>=><<"5">>,<<"public_key">>=><<"attacker">>},Snapshot)),
    ?assertMatch({error,invalid_inputs},damage_verification_catalog:validate_inputs(Keys,
        #{<<"input_limit">>=><<"5\nWhen do something else">>},Snapshot)).

missing_protected_context_blocks_test() ->
    ?assertEqual({error,context_required},damage_verification_catalog:validate_inputs(
        [<<"api_secret">>],#{},#{entries=>#{}})).

budget_and_frozen_context_test() ->
    ?assertEqual(ok,damage_verification_runner:ensure_budget(5,[{verification_max_cost,5}])),
    ?assertThrow(verification_budget_exceeded,damage_verification_runner:ensure_budget(6,[{verification_max_cost,5}])),
    P=#{node=>#{version=>1,root=><<"root">>}},
    Hash=damage_verification_catalog:fingerprint(#{proofs=>P}),
    ?assertEqual(ok,damage_verification_runner:ensure_context(#{context_proofs=>P},[{verification_context_fingerprint,Hash}])),
    ?assertThrow(verification_context_changed,damage_verification_runner:ensure_context(
        #{context_proofs=>#{}},[{verification_context_fingerprint,Hash}])),
    ?assertEqual(ok,damage_verification_runner:ensure_context(#{},[])).

result_projection_and_unknown_outcome_test() ->
    Quote=damage_verification_runner:result(preview,{200,#{status=><<"ok">>,cost=>5,
        private_key=><<"secret">>,context=>#{password=><<"secret">>}}}),
    ?assertEqual(ready,maps:get(state,Quote)),?assertNot(maps:is_key(private_key,Quote)),
    ?assertNot(maps:is_key(context,Quote)),
    ?assertEqual(indeterminate,maps:get(state,damage_verification_runner:result(execute,
        {200,#{status=><<"ok">>}}))),
    ?assertEqual(passed,maps:get(state,damage_verification_runner:result(execute,
        {200,#{status=><<"ok">>,report_hash=><<"report">>}}))),
    Pending=damage_verification_runner:result(execute,{202,#{status=><<"pending">>,tx_hash=><<"tx">>}}),
    ?assertEqual(pending,maps:get(state,Pending)),?assertEqual(false,maps:get(retry_feature,Pending)).

job_projection_hides_internal_state_test() ->
    J=#{id=><<"id">>,mode=>execute,state=>passed,owner=><<"owner">>,
        spec=>#{source=><<"source">>,inputs=>#{<<"secret">>=><<"secret">>}},
        pid=>self(),ref=>make_ref(),timer=>make_ref(),progress=>#{5=>passed}},
    P=damage_verification_service:public_job(J),
    ?assertEqual([#{line=>5,state=>passed}],maps:get(progress,P)),
    lists:foreach(fun(K)->?assertNot(maps:is_key(K,P)) end,[owner,spec,pid,ref,timer]).

authorization_and_origin_test() ->
    A=#{authenticated=>true,public_key=><<"account">>,auth_mode=>custodial},
    ?assert(damage_verification_service:authorized(A)),
    ?assertNot(damage_verification_service:authorized(A#{auth_mode=>wallet})),
    ?assertNot(damage_verification_service:authorized(A#{authenticated=>false})),
    ?assert(damage_verification_http:same_origin(<<"https://example.test">>,<<"https://EXAMPLE.test:443/">>)),
    lists:foreach(fun(U)->?assertNot(damage_verification_http:same_origin(U,<<"https://example.test">>)) end,
        [<<"http://example.test">>,<<"https://example.test.evil">>,<<"https://user@example.test">>,
         <<"https://example.test/path">>,<<"null">>]).

formatter_emits_only_line_and_status_test() ->
    C=#{phase=>execute,sink=>self(),job_id=><<"job">>},
    ok=verification_formatter:format(C,step,{<<"When">>,8,<<"secret body">>,
        [<<"secret arg">>],#{password=><<"secret">>},success}),
    receive M->?assertEqual({verification_progress,<<"job">>,#{line=>8,state=>passed}},M)
    after 1000->?assert(false) end,
    ok=verification_formatter:format(C#{phase=>preview},step,{<<"When">>,8,<<>>,[],#{},success}),
    receive {verification_progress,_,_}->?assert(false) after 10->ok end.

synthetic_session_rehearsal_test() ->
    R=damage_verification_checks:session_revocation(),
    lists:foreach(fun(K)->?assertEqual(true,maps:get(K,R)) end,
        [baseline,revoked,unrelated_session_valid]),
    ?assertEqual(synthetic_session_store,maps:get(scope,R)).

synthetic_wallet_boundary_rehearsal_test() ->
    R=damage_verification_checks:privilege_boundary(),
    lists:foreach(fun(K)->?assertEqual(true,maps:get(K,R)) end,
        [denied,positive_control,forged_admin_denied]).

policy_rehearsal_uses_shared_evaluator_test() ->
    R=damage_verification_checks:lightning_policy(<<"100000">>,<<"500000">>),
    lists:foreach(fun(K)->?assertEqual(true,maps:get(K,R)) end,
        [within_budget,single_limit,total_limit,revoked,expired,invalid_amount,insufficient_balance]).

real_parser_and_registered_signatures_test() ->
    %% Must use the production egherkin parser and compiled clause metadata,
    %% never substitute a regex parser or make unknown steps succeed.
    Paths=filelib:wildcard(filename:join([code:priv_dir(damage),"features","verification","*.feature"])),
    ?assert(length(Paths)>=3),
    {steps_verification,Beam,_}=code:get_object_code(steps_verification),
    {ok,{steps_verification,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Beam,[abstract_code]),
    Steps=damage_bdd_catalog:from_forms(<<"steps_verification">>,<<"test-md5">>,Forms),
    Cat=#{revision=><<"test">>,steps=>Steps},
    lists:foreach(fun(Path)->
        {ok,Source}=file:read_file(Path),
        ?assertMatch({ok,_},damage_verification_catalog:parse(<<"fixture">>,Source)),
        ?assertMatch(#{valid:=true},damage_bdd_validator:validate(Source,Cat))
    end,Paths).

owner_isolation_and_repeated_approval_test() ->
    Owner= <<"account-a">>, Other= <<"account-b">>, Now=erlang:monotonic_time(millisecond),
    A=#{authenticated=>true,public_key=>Owner,auth_mode=>custodial},
    Run=#{id=><<"run">>,mode=>execute,state=>passed,owner=>Owner,
          created_at=>1,created_mono=>Now,progress=>#{}},
    Quote=#{id=><<"quote">>,mode=>preview,state=>ready,owner=>Owner,
          created_at=>1,created_mono=>Now,completed_at=>1,progress=>#{},approved_job=><<"run">>},
    S=#{jobs=>#{<<"quote">>=>Quote,<<"run">>=>Run}},
    {reply,{ok,First},_}=damage_verification_service:handle_call({approve,<<"quote">>,A},undefined,S),
    {reply,{ok,Second},_}=damage_verification_service:handle_call({approve,<<"quote">>,A},undefined,S),
    ?assertEqual(First,Second),?assertEqual(<<"run">>,maps:get(id,First)),
    ?assertMatch({reply,{error,not_found},_},damage_verification_service:handle_call(
        {status,<<"run">>,A#{public_key=>Other}},undefined,S)),
    ?assertMatch({reply,{ok,[]},_},damage_verification_service:handle_call(
        {history,A#{public_key=>Other}},undefined,S)),
    Expired=maps:remove(approved_job,Quote#{finished_mono=>Now-400000,spec=>#{}}),
    ?assertMatch({reply,{error,approval_expired},_},damage_verification_service:handle_call(
        {approve,<<"quote">>,A},undefined,#{jobs=>#{<<"quote">>=>Expired}})).
