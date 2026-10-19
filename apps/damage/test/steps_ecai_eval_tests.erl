-module(steps_ecai_eval_tests).
-include_lib("eunit/include/eunit.hrl").

dry_submit_has_no_run_test() ->
    C = steps_ecai_eval:step_dry([], #{step_spend => 1}, <<"When">>, 1,
        ["I run the ECAI evaluation suite", "fixture", "on split", "test", "with key", "fixture-key"], <<>>),
    ?assertEqual(true, maps:get(ecai_eval_dry_run,C)),
    ?assertEqual(false, maps:is_key(ecai_eval_run_id,C)).
dry_gate_does_not_certify_test() ->
    C = steps_ecai_eval:step_dry([], #{step_spend => 1}, <<"Then">>, 1,
        ["the ECAI evaluation release gate must pass"], <<>>),
    ?assertEqual(false, maps:is_key(ecai_eval_report,C)).
unrelated_steps_not_captured_test() ->
    ?assertError(function_clause,steps_ecai_eval:step_dry([],#{},<<"When">>,1,["an unrelated step"],<<>>)).
