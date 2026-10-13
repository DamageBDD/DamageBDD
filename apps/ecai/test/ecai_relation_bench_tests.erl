-module(ecai_relation_bench_tests).

-include_lib("eunit/include/eunit.hrl").

hidden_relation_recovery_test() ->
    MFA = {mfa, jsx, encode, 1},
    {ok, Calls} = ecai_relation:new(erm_mpv, calls, MFA),
    {ok, Belongs} = ecai_relation:new(MFA, belongs_to_module, jsx),
    {ok, Hidden} = ecai_relation:new(erm_mpv, uses, jsx),
    Result = ecai_relation_bench:evaluate([Calls, Belongs], [Hidden], 2),
    ?assertEqual(1, maps:get(expected, Result)),
    ?assertEqual(1, maps:get(recovered, Result)),
    ?assertEqual(1.0, maps:get(recall, Result)),
    ?assertEqual(0, maps:get(llm_calls, Result)).
