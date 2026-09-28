-module(ecai_relation_tests).

-include_lib("eunit/include/eunit.hrl").

canonical_map_order_test() ->
    A = #{b => 2, a => 1},
    B = #{a => 1, b => 2},
    ?assertEqual(ecai_relation:encode_entity(A), ecai_relation:encode_entity(B)).

relation_key_deterministic_test() ->
    {ok, A} = ecai_relation:new(erm_mpv, uses, jsx),
    {ok, B} = ecai_relation:new(erm_mpv, uses, jsx),
    ?assertEqual(ecai_relation:key(A), ecai_relation:key(B)).

relation_metadata_not_identity_test() ->
    {ok, A} = ecai_relation:new(a, calls, b, #{source => one}),
    {ok, B} = ecai_relation:new(a, calls, b, #{source => two}),
    ?assertEqual(ecai_relation:key(A), ecai_relation:key(B)).

unsupported_runtime_term_test() ->
    ?assertMatch(
        {error, {invalid_subject, {unsupported_canonical_term, _}}},
        ecai_relation:new(self(), calls, b)
    ).

analysis_to_relations_test() ->
    Analysis = #{
        application => erm,
        module => erm_mpv,
        exports => [{play, 1}],
        remote_calls => [
            #{module => jsx, function => encode, arity => 1}
        ],
        behaviours => [gen_server],
        includes => [<<"erm_playlist.hrl">>],
        source_sha256 => <<"abc">>,
        analysis_sha256 => <<"def">>
    },
    Relations = ecai_relation:from_analysis(erm, Analysis),
    ?assert(has_relation(Relations, erm_mpv, belongs_to_application, erm)),
    ?assert(has_relation(Relations, erm_mpv, exports, {mfa, erm_mpv, play, 1})),
    ?assert(has_relation(Relations, erm_mpv, calls, {mfa, jsx, encode, 1})),
    ?assert(has_relation(Relations, {mfa, jsx, encode, 1}, belongs_to_module, jsx)),
    ?assert(has_relation(Relations, erm_mpv, implements, gen_server)).

has_relation(Relations, Subject, Predicate, Object) ->
    lists:any(
        fun(R) ->
            ecai_relation:entity_equal(ecai_relation:subject(R), Subject)
                andalso ecai_relation:entity_equal(ecai_relation:predicate(R), Predicate)
                andalso ecai_relation:entity_equal(ecai_relation:object(R), Object)
        end,
        Relations
    ).
