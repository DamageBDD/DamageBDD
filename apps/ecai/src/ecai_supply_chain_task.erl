%% Pure bounded jobs; called from monitored workers, never the HTTP process.
-module(ecai_supply_chain_task).
-export([plan/4, benchmark/3]).

plan(S,Reference,Cases,Mode) ->
    Start=erlang:monotonic_time(microsecond),
    {P,Evidence}=case Mode of
        cold -> {ecai_supply_chain_planner:solve(S,Reference,[],newly_solved),#{kind => none}};
        warm -> {ecai_supply_chain_planner:solve(S,Reference,ecai_supply_chain_model:skeleton(Reference),warm_start),#{kind => previous_plan}};
        _ when Mode=:=lookup; Mode=:=ecai ->
            Retrieval=ecai_supply_chain_cases:retrieve(S,Cases,Mode),
            R=maps:get(case_record,Retrieval),
            E0=maps:remove(case_record,Retrieval),
            case maps:get(kind,Retrieval) of
                miss -> {ecai_supply_chain_planner:solve(S,Reference,[],newly_solved),E0};
                exact ->
                    CP=maps:get(plan,R), Check=ecai_supply_chain_validator:validate(S,CP),
                    case maps:get(valid,Check) of
                        true -> {ecai_supply_chain_planner:cached(S,Reference,CP),E0#{case_id => maps:get(id,R)}};
                        false -> {ecai_supply_chain_planner:solve(S,Reference,[],newly_solved),E0#{kind := rejected,reason => failed_revalidation}}
                    end;
                near ->
                    {ecai_supply_chain_planner:solve(S,Reference,ecai_supply_chain_model:skeleton(maps:get(plan,R)),retrieved_repaired),
                     E0#{case_id => maps:get(id,R)}}
            end
    end,
    P#{mode => Mode,retrieval => Evidence,total_us => max(1,erlang:monotonic_time(microsecond)-Start)}.

benchmark(S,Reference,Cases) ->
    %% Frozen memory for all four modes: no benchmark result enters the index.
    %% Rotate execution order deterministically to reduce fixed warm-cache bias.
    Modes=[cold,warm,lookup,ecai], Offset=maps:get(seed,S) rem 4,
    {A,B}=lists:split(Offset,Modes), Order=B++A,
    Results=[begin P=plan(S,Reference,Cases,M),
        #{mode => M,metrics => maps:get(metrics,P),objective => maps:get(objective,P),
          valid => maps:get(valid,maps:get(validation,P)),source => maps:get(source,P),
          total_us => maps:get(total_us,P),search_starts => maps:get(search_starts,P),
          retrieval => maps:get(retrieval,P)} end || M <- Order],
    #{rows => [hd([R || R <- Results,maps:get(mode,R)=:=M]) || M <- Modes],
      execution_order => Order,case_count => length(Cases),
      comparison => <<"Single local trial; same scenario, validator, objective and four-start repair cap. Exact hits skip search. Includes index rebuild. Not a statistical speedup claim.">>}.
