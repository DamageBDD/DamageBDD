-module(erm_anatomy_mesh_tests).
-include_lib("eunit/include/eunit.hrl").
quad_test() ->
    {ok, #{triangles := Ts}} = erm_anatomy_mesh:parse(
        <<"v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1/1/1 2/2/1 3/3/1 4/4/1\n">>
    ),
    ?assertEqual(2, length(Ts)).
negative_indices_test() ->
    {ok, A} = erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n">>),
    {ok, B} = erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n">>),
    ?assertEqual(A, B).
invalid_index_test() ->
    ?assertMatch({error, _}, erm_anatomy_mesh:parse(<<"v 0 0 0\nf 1 2 0\n">>)).
render_rotation_test() ->
    {ok, M} = erm_anatomy_mesh:parse(<<"v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n">>),
    Ps = [#{id => <<"test">>, mesh => M}],
    B = erm_anatomy_mesh:bounds(Ps),
    S = erm_anatomy_mesh:svg(Ps, {0.0, 0.0, 1.0}, B, undefined),
    ?assertNotEqual(S, erm_anatomy_mesh:svg(Ps, {0.5, 0.0, 1.0}, B, undefined)),
    ?assertNotEqual(nomatch, binary:match(S, <<"<polygon">>)),
    ?assertEqual(
        nomatch,
        binary:match(
            erm_anatomy_mesh:svg(
                [#{id => <<"test">>, mesh => M, visible => false}], {0.0, 0.0, 1.0}, B, undefined
            ),
            <<"<polygon">>
        )
    ).

picking_and_pan_test() ->
    Mesh = #{triangles => [{{-1.0, -1.0, 0.0}, {1.0, -1.0, 0.0}, {0.0, 1.0, 0.0}}]},
    P = #{id => <<"back">>, mesh => Mesh, visible => true},
    Front = P#{
        id => <<"front">>,
        mesh => #{triangles => [{{-1.0, -1.0, 1.0}, {1.0, -1.0, 1.0}, {0.0, 1.0, 1.0}}]}
    },
    Parts = [P, Front],
    Bounds = erm_anatomy_mesh:bounds(Parts),
    Camera = {0.0, 0.0, 1.0},
    ?assertEqual(
        <<"front">>, erm_anatomy_mesh:pick(Parts, Camera, Bounds, {0, 0}, {450, 350}, {900, 700})
    ),
    ?assertEqual(
        <<"back">>,
        erm_anatomy_mesh:pick(
            [P, Front#{visible := false}], Camera, Bounds, {0, 0}, {450, 350}, {900, 700}
        )
    ),
    ?assertEqual(
        undefined, erm_anatomy_mesh:pick(Parts, Camera, Bounds, {0, 0}, {10, 450}, {1800, 900})
    ),
    ?assertEqual(
        <<"front">>, erm_anatomy_mesh:pick(Parts, Camera, Bounds, {100, 0}, {550, 350}, {900, 700})
    ),
    ?assertNotEqual(
        erm_anatomy_mesh:svg(Parts, Camera, Bounds, undefined),
        erm_anatomy_mesh:svg(Parts, Camera, Bounds, undefined, {100, 0})
    ).
