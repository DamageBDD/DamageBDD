-module(ecai_dj_package_tests).
-include_lib("eunit/include/eunit.hrl").

roundtrip_and_canonical_digest_test() ->
    P = (ecai_dj_package:default())#{preferred_tags => [<<"Ambient">>,<<"ambient">>]},
    {ok,Normalized} = ecai_dj_package:validate(P),
    ?assertEqual([<<"ambient">>],maps:get(preferred_tags,Normalized)),
    {ok,Bin} = ecai_dj_package:export(P),
    ?assertEqual({ok,Normalized},ecai_dj_package:import(Bin)),
    ?assertEqual(ecai_dj_package:digest(P),ecai_dj_package:digest(Normalized)),
    {ok,BinAgain} = ecai_dj_package:export(Normalized),
    ?assertEqual(Bin,BinAgain).

tamper_detection_test() ->
    {ok,Bin} = ecai_dj_package:export(ecai_dj_package:default()),
    Edited = binary:replace(Bin,<<"Open discovery">>,<<"Evil discovery">>),
    ?assertEqual({error,digest_mismatch},ecai_dj_package:import(Edited)).

closed_schema_and_no_code_test() ->
    ?assertMatch({error,_},ecai_dj_package:validate(#{module => <<"os">>})),
    ?assertMatch({error,_},ecai_dj_package:validate(#{weights => #{shell => 2}})),
    ?assertMatch({error,_},ecai_dj_package:validate(#{preferred_tags => [fun()->ok end]})),
    ?assertMatch({error,_},ecai_dj_package:validate(#{discovery => 1000000})),
    ?assertMatch({error,_},ecai_dj_package:validate(#{schema => <<"future-schema">>})),
    ?assertMatch({error,_},ecai_dj_package:validate(#{name=><<"a">>,<<"name">>=><<"b">>})).

bounded_import_test() ->
    ?assertEqual({error,package_too_large_or_invalid},
        ecai_dj_package:import(binary:copy(<<"x">>,65537))),
    ?assertEqual({error,invalid_package},ecai_dj_package:import(<<"not json">>)),
    ?assertEqual({error,invalid_package},ecai_dj_package:import(<<"{}">>)).

binary_keys_without_atom_creation_test() ->
    {ok,P} = ecai_dj_package:validate(#{<<"name">> => <<"Late night">>,
        <<"preferred_tags">> => [<<"ambient">>]}),
    ?assertEqual(<<"Late night">>,maps:get(name,P)).
