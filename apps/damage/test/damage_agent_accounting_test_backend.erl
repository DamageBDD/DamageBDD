%% TEST ONLY: an in-memory, serial treasury model. Never install as a live backend.
-module(damage_agent_accounting_test_backend).
-behaviour(gen_server).
-export([start_link/0, stop/0, set/2, snapshot/0,
         prepare/1, reserve/1, authorize/3, settle/2, write_receipt/2, reconcile/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
stop() -> gen_server:stop(?MODULE).
set(K,V) -> gen_server:call(?MODULE,{set,K,V}).
snapshot() -> gen_server:call(?MODULE,snapshot).
prepare(B) -> gen_server:call(?MODULE,{prepare,B}).
reserve(B) -> gen_server:call(?MODULE,{reserve,B}).
authorize(B,M,N) -> gen_server:call(?MODULE,{authorize,B,M,N}).
settle(B,N) -> gen_server:call(?MODULE,{settle,B,N}).
write_receipt(B,R) -> gen_server:call(?MODULE,{receipt,B,R}).
reconcile(B,R) -> gen_server:call(?MODULE,{reconcile,B,R}).
init([]) -> {ok,#{available => 100, rows => #{}, calls => [], faults => #{}}}.
handle_call({set,K,V},_,S) -> {reply,ok,S#{faults => (maps:get(faults,S))#{K => V}}};
handle_call(snapshot,_,S) -> {reply,S,S};
handle_call({prepare,B},_,S) ->
    Names = [agent_policy,agent_treasury,agent_execution_ledger],
    Ct = #{agent_policy => <<"ct_policy">>,agent_treasury => <<"ct_treasury">>,
           agent_execution_ledger => <<"ct_ledger">>},
    {reply,{ok,#{contracts => Ct, sources => maps:from_list([{K,<<"/test/not-live.aes">>} || K <- Names]),
        source_hashes => maps:from_list([{K,binary:copy(<<"0">>,64)} || K <- Names]),
        network_id => maps:get(network_id,B),executor => <<"ak_executor">>}},S};
handle_call({authorize,B,Method,_Units},_,S0) ->
    S = note(authorize,B,S0),
    Reply = case maps:get(deny_method,maps:get(faults,S),none) of
        Method -> {error,denied}; _ -> ok
    end,
    {reply,Reply,S};
handle_call({reserve,B},_,S0) ->
    S = note(reserve,B,S0), Id = maps:get(job_id,B), Cap = maps:get(max_cost_units,B),
    Available = maps:get(available,S),
    case Available >= Cap andalso not maps:get(deny_reserve,maps:get(faults,S),false) of
        false -> {reply,{error,reservation_not_submitted},S};
        true ->
            false = maps:is_key(Id,maps:get(rows,S)),
            P = proof(B,agent_treasury), Row = #{reserved => Cap, status => reserved,proof => P},
            S1 = S#{available => Available-Cap,rows => (maps:get(rows,S))#{Id => Row}},
            Reply = case maps:get(lose_reserve,maps:get(faults,S),false) of
                true -> {error,response_lost}; false -> {ok,P}
            end,
            {reply,Reply,S1}
    end;
handle_call({settle,B,N},_,S0) ->
    S = note(settle,B,S0), Id = maps:get(job_id,B), Rows = maps:get(rows,S),
    Row = maps:get(Id,Rows), reserved = maps:get(status,Row),
    true = N >= 0 andalso N =< maps:get(reserved,Row),
    P = proof(B,agent_treasury),
    S1 = S#{available => maps:get(available,S)+maps:get(reserved,Row)-N,
            rows => Rows#{Id => Row#{status => settled,cost => N,settlement_proof => P}}},
    Reply = case maps:get(lose_settle,maps:get(faults,S),false) of
        true -> {error,response_lost}; false -> {ok,P}
    end,
    {reply,Reply,S1};
handle_call({receipt,B,R},_,S0) ->
    S = note(receipt,B,S0), Id = maps:get(job_id,B), Rows = maps:get(rows,S), Row = maps:get(Id,Rows),
    settled = maps:get(status,Row), false = maps:is_key(receipt,Row),
    P = proof(B,agent_execution_ledger),
    S1 = S#{rows => Rows#{Id => Row#{receipt => R,receipt_proof => P}}},
    Reply = case maps:get(lose_receipt,maps:get(faults,S),false) of
        true -> {error,response_lost}; false -> {ok,P}
    end,
    {reply,Reply,S1};
handle_call({reconcile,B,_R},_,S0) ->
    S = note(reconcile,B,S0), Id = maps:get(job_id,B), Row = maps:get(Id,maps:get(rows,S)),
    O = case maps:get(status,B) of
        reservation_pending -> #{stage => reserved,job_id => Id,
            reserved_units => maps:get(reserved,Row),proof => maps:get(proof,Row)};
        settlement_pending -> #{stage => settled,job_id => Id,cost_units => maps:get(cost,Row),
            proof => maps:get(settlement_proof,Row)};
        receipt_pending -> #{stage => receipted,job_id => Id,
            receipt_hash => damage_agent_codec:hash(maps:get(receipt,Row)),proof => maps:get(receipt_proof,Row)}
    end,
    Reply = case maps:get(bad_reconciliation,maps:get(faults,S),false) of
        true -> {ok,O#{job_id => <<"wrong-job">>}}; false -> {ok,O}
    end,
    {reply,Reply,S};
handle_call(_,_,S) -> {reply,{error,unexpected_call},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
note(Name,B,S) -> S#{calls => [{Name,maps:get(job_id,B)}|maps:get(calls,S)]}.
proof(B,Name) -> #{contract_id => maps:get(Name,maps:get(contracts,B)),
    caller_id => maps:get(owner,B),caller_nonce => 1,height => 42,outcome => included,
    tx_hash => <<"th_fixture">>}.
