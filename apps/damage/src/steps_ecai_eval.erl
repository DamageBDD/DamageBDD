%% Evaluation scenarios reuse the durable runner and release gate.
%% The step authenticates the bearer again; Context owner/admin flags are ignored.
-module(steps_ecai_eval).
-export([step/6, step_dry/6]).

step(_, _, documentation, _, ["I run the ECAI evaluation suite", _, "on split", _, "with key", _], _) ->
    "WHEN: Submit a reviewed immutable suite using a managed session bearer in access_token. Key is account-scoped and idempotent.";
step(_, _, documentation, _, ["I wait up to", _, "seconds for the ECAI evaluation"], _) ->
    "WHEN: Wait for external requests to finish; pending human reviews still block the gate.";
step(_, _, documentation, _, ["the ECAI evaluation release gate must pass"], _) ->
    "THEN: Require all model target gates to pass without critical failures, errors or unreviewed rubrics.";
step(_, Context, Keyword, _, ["I run the ECAI evaluation suite", Suite, "on split", Split, "with key", Key], _) when
    Keyword =:= <<"When">>; Keyword =:= <<"And">> ->
    Owner = owner(Context),
    {ok, R} = ecai_eval_srv:request(submit, Owner, #{<<"suite_id">> => ecai_eval_util:bin(Suite),
        <<"split">> => ecai_eval_util:bin(Split), <<"idempotency_key">> => ecai_eval_util:bin(Key)}),
    Context#{ecai_eval_run_id => maps:get(<<"id">>, R), ecai_eval_submission => R};
step(_, Context, Keyword, _, ["I wait up to", Seconds, "seconds for the ECAI evaluation"], _) when
    Keyword =:= <<"When">>; Keyword =:= <<"And">> ->
    N = binary_to_integer(ecai_eval_util:bin(Seconds)), ecai_eval_util:integer(N, 1, 900),
    Deadline = erlang:monotonic_time(millisecond)+N*1000,
    R = await(Context, maps:get(ecai_eval_run_id, Context), Deadline), Context#{ecai_eval_report => R};
step(_, Context, Keyword, _, ["the ECAI evaluation release gate must pass"], _) when
    Keyword =:= <<"Then">>; Keyword =:= <<"And">> ->
    Owner = owner(Context), Id = maps:get(ecai_eval_run_id, Context),
    {ok, #{<<"report">> := R}} = ecai_eval_srv:request(run, Owner, #{<<"id">> => Id}),
    case maps:get(<<"release_gate">>, R) of
        true -> Context#{ecai_eval_report => R};
        false -> erlang:error({ecai_evaluation_gate_blocked, Id, maps:get(<<"counts">>, R)})
    end.
owner(Context) ->
    Token = ecai_eval_util:bin(maps:get(access_token, Context, <<>>)),
    case damage_auth:resolve_oauth(Token, #{}) of
        {ok, #{authenticated := true, auth_mode := custodial} = Auth} ->
            {ok, Owner} = damage_auth:authenticated_account(Auth), Owner;
        _ -> erlang:error(evaluation_managed_session_required)
    end.
await(Context, Id, Deadline) ->
    %% Re-resolve the session on each poll so revocation is respected.
    {ok, #{<<"report">> := R}} = ecai_eval_srv:request(run, owner(Context), #{<<"id">> => Id}),
    C = maps:get(<<"counts">>, R),
    case maps:get(<<"pending">>, C, 0)+maps:get(<<"inflight">>, C, 0) of
        0 -> R;
        _ -> case erlang:monotonic_time(millisecond) >= Deadline of
            true -> erlang:error({evaluation_wait_timeout, Id});
            false -> timer:sleep(500), await(Context, Id, Deadline)
        end
    end.

%% Recognize only our own steps during Damage cost estimation. Never submit,
%% authenticate, wait, review, or claim a real gate result in a dry run.
step_dry(Config, Context, K, N, ["I run the ECAI evaluation suite", _, "on split", _, "with key", _] = Parts, Args) ->
    steps_utils:step_dry(Config, Context#{ecai_eval_dry_run => true}, K, N, Parts, Args);
step_dry(Config, Context, K, N, ["I wait up to", _, "seconds for the ECAI evaluation"] = Parts, Args) ->
    steps_utils:step_dry(Config, Context#{ecai_eval_dry_run => true}, K, N, Parts, Args);
step_dry(Config, Context, K, N, ["the ECAI evaluation release gate must pass"] = Parts, Args) ->
    steps_utils:step_dry(Config, Context#{ecai_eval_dry_run => true}, K, N, Parts, Args).
