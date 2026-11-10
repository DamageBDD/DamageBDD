%% Pure policy boundary shared by the live NWC wallet and synthetic verification.
%% This is not a reservation/settlement engine. The ledger still owns atomic debit.
-module(damage_nwc_payment_policy).
-export([amount/3,balance/2]).
amount(P,A,H) when is_map(P),is_integer(A),A>0,is_integer(H),H>=0 ->
    R=maps:get(revoked,P,false), S=maps:get(max_single_msat,P,0),
    T=maps:get(max_total_msat,P,0),Spent=maps:get(spent_msat,P,0),
    E=maps:get(expires_height,P,0),
    Valid=is_boolean(R) andalso lists:all(fun(N)->is_integer(N) andalso N>=0 end,[S,T,Spent,E]),
    case Valid of
        false -> {error,<<"INVALID_POLICY">>,<<"Invalid payment policy">>};
        true when R -> {error,<<"REVOKED">>,<<"NWC session is revoked">>};
        true when S>0,A>S -> {error,<<"QUOTA_EXCEEDED">>,<<"amount exceeds max_single_msat">>};
        true when T>0,Spent+A>T -> {error,<<"QUOTA_EXCEEDED">>,<<"amount exceeds max_total_msat">>};
        true when E>0,H>E -> {error,<<"EXPIRED">>,<<"policy expired">>};
        true -> ok
    end;
amount(_,_,_) -> {error,<<"INVALID_AMOUNT">>,<<"A positive integer millisatoshi amount is required">>}.
balance({ok,B},A) when is_integer(B),B>=0,is_integer(A),A>0,B>=A -> ok;
balance({ok,B},_) when is_integer(B),B>=0 ->
    {error,<<"INSUFFICIENT_BALANCE">>,<<"balance too low">>};
balance(_,_) -> {error,<<"LEDGER_BALANCE_FAILED">>,<<"Ledger balance unavailable">>}.
