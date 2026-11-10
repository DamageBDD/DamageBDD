%% Trusted step implementations, not feature tags, require node administration.
-module(steps_verification).
-damage_roles([node_admin]).
-export([step/6,step_dry/6]).
step_dry(C,X,K,L,B,A) -> steps_utils:step_dry(C,X,K,L,B,A).
step(Config,X,_,_,["the running node MUST pass the local production security baseline"],_) ->
    damage_node_security:verify(Config,X);
step(_,X,_,_,["I inspect the deployed AWS bunker health"],_) ->
    probe(X,bunker_health,fun damage_verification_checks:bunker_health/0);
step(_,X,_,_,["the deployed AWS bunker health checks MUST pass"],_) ->
    assert(X,bunker_health,[ok]);
step(_,X,_,_,["I verify signing through the approved bunker relays"],_) ->
    probe(X,bunker_signing,fun damage_verification_checks:bunker_signing/0);
step(_,X,_,_,["the bunker signatures and policy denials MUST be verified"],_) ->
    assert(X,bunker_signing,[ok]);
step(_,X,_,_,["I rehearse an isolated browser session revocation"],_) ->
    probe(X,session_revocation,fun damage_verification_checks:session_revocation/0);
step(_,X,_,_,["the synthetic session MUST work before revocation and fail afterwards"],_) ->
    assert(X,session_revocation,[baseline,revoked,unrelated_session_valid]);
step(_,X,_,_,["I inspect the wallet session privilege boundary"],_) ->
    probe(X,privilege_boundary,fun damage_verification_checks:privilege_boundary/0);
step(_,X,_,_,["wallet sessions MUST NOT gain execution signing or release transfer authority"],_) ->
    assert(X,privilege_boundary,[denied,positive_control,forged_admin_denied]);
step(_,X,_,_,["I inspect the configured Lightning node connection"],_) ->
    probe(X,lightning_connection,fun damage_verification_checks:lightning_connection/0);
step(_,X,_,_,["the Lightning node MUST respond with its identity and network"],_) ->
    assert(X,lightning_connection,[ok]);
step(_,X,_,_,["I rehearse the Lightning policy with single limit",Single,
              "and total limit",Total,"millisatoshis"],_) ->
    probe(X,lightning_policy,fun()->damage_verification_checks:lightning_policy(Single,Total) end);
step(_,X,_,_,["the synthetic Lightning policy MUST enforce limits revocation expiry and balance"],_) ->
    assert(X,lightning_policy,[within_budget,single_limit,total_limit,revoked,expired,
                               invalid_amount,insufficient_balance]).
probe(X,Key,Fun) ->
    case steps_utils:is_admin(X) of
        false -> X#{fail=><<"Node administrator required">>};
        true ->
            try Fun() of R when is_map(R)->X#{Key=>R}
            catch _:_ -> X#{fail=><<"Verification dependency failed or is unavailable">>} end
    end.
assert(X,Key,Fields) ->
    R=maps:get(Key,X,#{}),
    case steps_utils:is_admin(X) andalso lists:all(fun(F)->maps:get(F,R,false)=:=true end,Fields) of
        true -> X;
        false -> X#{fail=><<"Verification assertion failed; inspect deployment prerequisites and report">>}
    end.
