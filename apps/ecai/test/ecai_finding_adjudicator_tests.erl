-module(ecai_finding_adjudicator_tests).

-include_lib("eunit/include/eunit.hrl").

rejects_existing_atom_exhaustion_premise_test() ->
    Finding = #{
        <<"function">> => <<"existing_module_atom/1">>,
        <<"evidence">> =>
            <<"binary_to_existing_atom/2 allows arbitrary atom injection">>,
        <<"impact">> =>
            <<"Atom table exhaustion can cause denial of service">>,
        <<"remediation">> => <<"validate input">>
    },
    ?assertMatch(
        {reject, #{class := invalid_security_premise}},
        ecai_finding_adjudicator:adjudicate(Finding)
    ).

rejects_binary_to_atom_replacement_test() ->
    Finding = #{
        <<"function">> => <<"existing_module_atom/1">>,
        <<"evidence">> =>
            <<"binary_to_existing_atom/2 receives untrusted input">>,
        <<"remediation">> =>
            <<"Replace it with binary_to_atom/2 after validation">>
    },
    ?assertMatch(
        {reject, #{class := unsafe_remediation}},
        ecai_finding_adjudicator:adjudicate(Finding)
    ).

accepts_existing_atom_selection_finding_without_allocation_claim_test() ->
    Finding = #{
        <<"function">> => <<"existing_module_atom/1">>,
        <<"evidence">> =>
            <<"Untrusted input may select an unexpected already-loaded module">>,
        <<"impact">> =>
            <<"Unexpected module selection could alter authorization behavior">>,
        <<"remediation">> =>
            <<"Validate against an application-specific allowlist">>
    },
    ?assertEqual(
        accept,
        ecai_finding_adjudicator:adjudicate(Finding)
    ).

accepts_unrelated_finding_test() ->
    Finding = #{
        <<"function">> => <<"parse_header/1">>,
        <<"evidence">> => <<"Header length is not bounded">>,
        <<"impact">> => <<"Memory pressure">>,
        <<"remediation">> => <<"Enforce a size limit">>
    },
    ?assertEqual(
        accept,
        ecai_finding_adjudicator:adjudicate(Finding)
    ).
