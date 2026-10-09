-module(erm_anatomy_mesh_tests).
-include_lib("eunit/include/eunit.hrl").
quad_test() ->
    {ok,#{triangles:=Ts}}=erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1/1/1 2/2/1 3/3/1 4/4/1\n">>),
    ?assertEqual(2,length(Ts)).
negative_indices_test() ->
    {ok,A}=erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n">>),
    {ok,B}=erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n">>),
    ?assertEqual(A,B).
invalid_index_test() ->
    ?assertMatch({error,_},erm_anatomy_mesh:parse(<<"v 0 0 0\nf 1 2 0\n">>)).
render_rotation_test() ->
    {ok,M}=erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n">>),
    Ps=[#{id=><<"test">>,mesh=>M}], B=erm_anatomy_mesh:bounds(Ps),
    S=erm_anatomy_mesh:svg(Ps,{0.0,0.0,1.0},B,undefined),
    ?assertNotEqual(S,erm_anatomy_mesh:svg(Ps,{0.5,0.0,1.0},B,undefined)),
    ?assertNotEqual(nomatch,binary:match(S,<<"<polygon">>)),
    ?assertEqual(nomatch,binary:match(erm_anatomy_mesh:svg([#{id=><<"test">>,mesh=>M,visible=>false}],{0.0,0.0,1.0},B,undefined),<<"<polygon">>)).
