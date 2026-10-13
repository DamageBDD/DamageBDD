-module(ecai_compose_tests).

-include_lib("eunit/include/eunit.hrl").

calls_mfa_to_uses_module_test() ->
    MFA = {mfa, jsx, encode, 1},
    {ok, A} = ecai_relation:new(erm_mpv, calls, MFA),
    {ok, B} = ecai_relation:new(MFA, belongs_to_module, jsx),
    {ok, Derived} = ecai_compose:compose(A, B),
    ?assert(ecai_relation:entity_equal(ecai_relation:subject(Derived), erm_mpv)),
    ?assert(ecai_relation:entity_equal(ecai_relation:predicate(Derived), uses)),
    ?assert(ecai_relation:entity_equal(ecai_relation:object(Derived), jsx)),
    Proof = ecai_relation:proof(Derived),
    ?assertEqual(false, maps:get(llm_used, Proof)).

transitive_dependency_test() ->
    {ok, AB} = ecai_relation:new(a, calls_module, b),
    {ok, BC} = ecai_relation:new(b, calls_module, c),
    {ok, CD} = ecai_relation:new(c, calls_module, d),
    Derived = ecai_compose:derive([AB, BC, CD], a, depends_on, 4),
    Objects = [ecai_relation:object(R) || R <- Derived],
    ?assert(lists:member(c, Objects)),
    ?assert(lists:member(d, Objects)).

disconnected_test() ->
    {ok, A} = ecai_relation:new(a, calls_module, b),
    {ok, B} = ecai_relation:new(c, calls_module, d),
    ?assertEqual({error, disconnected}, ecai_compose:compose(A, B)).
