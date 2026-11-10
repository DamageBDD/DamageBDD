-module(damage_nwc_payment_policy_tests).
-include_lib("eunit/include/eunit.hrl").

limits_and_expiry_test() ->
    P=#{max_single_msat=>100,max_total_msat=>500,spent_msat=>400,expires_height=>50},
    ?assertEqual(ok,damage_nwc_payment_policy:amount(P,100,50)),
    ?assertMatch({error,<<"QUOTA_EXCEEDED">>,_},damage_nwc_payment_policy:amount(P,101,50)),
    ?assertMatch({error,<<"QUOTA_EXCEEDED">>,_},damage_nwc_payment_policy:amount(P#{spent_msat=>500},1,50)),
    ?assertMatch({error,<<"EXPIRED">>,_},damage_nwc_payment_policy:amount(P,1,51)),
    ?assertMatch({error,<<"REVOKED">>,_},damage_nwc_payment_policy:amount(P#{revoked=>true},1,50)).

fail_closed_values_test() ->
    lists:foreach(fun(A)->?assertMatch({error,_,_},damage_nwc_payment_policy:amount(#{},A,10)) end,
        [0,-1,1.5,<<"100">>,undefined]),
    lists:foreach(fun(P)->?assertMatch({error,_,_},damage_nwc_payment_policy:amount(P,10,10)) end,
        [#{revoked=><<"false">>},#{max_total_msat=>-1},#{spent_msat=>-10},#{max_single_msat=><<"0">>}]),
    ?assertMatch({error,_,_},damage_nwc_payment_policy:amount(#{},1,-1)).

balance_test() ->
    ?assertEqual(ok,damage_nwc_payment_policy:balance({ok,100},100)),
    ?assertMatch({error,<<"INSUFFICIENT_BALANCE">>,_},damage_nwc_payment_policy:balance({ok,99},100)),
    ?assertMatch({error,<<"LEDGER_BALANCE_FAILED">>,_},damage_nwc_payment_policy:balance({error,<<"private exception">>},100)).

valid_policy_parity_test() ->
    %% Preserve the original live evaluator's precedence and inclusive boundary.
    lists:foreach(fun({R,S,T,Spent,E,A,H})->
        P=#{revoked=>R,max_single_msat=>S,max_total_msat=>T,spent_msat=>Spent,expires_height=>E},
        ?assertEqual(old_code(P,A,H),code(damage_nwc_payment_policy:amount(P,A,H)))
    end,[{R,S,T,Spent,E,A,H}||R<-[false,true],S<-[0,10],T<-[0,20],Spent<-[0,19,20],
        E<-[0,100],A<-[1,10,11,21],H<-[99,100,101]]).
old_code(#{revoked:=true},_,_)-> <<"REVOKED">>;
old_code(#{max_single_msat:=S},A,_) when S>0,A>S -> <<"QUOTA_EXCEEDED">>;
old_code(#{max_total_msat:=T,spent_msat:=S},A,_) when T>0,S+A>T -> <<"QUOTA_EXCEEDED">>;
old_code(#{expires_height:=E},_,H) when E>0,H>E -> <<"EXPIRED">>;
old_code(_,_,_)->ok.
code(ok)->ok;
code({error,C,_})->C.
