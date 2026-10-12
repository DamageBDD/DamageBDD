-module(erm_anatomy_vtk_tests).
-include_lib("eunit/include/eunit.hrl").

ascii_polygon_test() ->
    {ok, #{triangles := Ts}} = erm_anatomy_vtk:parse(
        <<
            "# vtk DataFile Version 3.0\nfixture\nASCII\nDATASET POLYDATA\n"
            "POINTS 4 float\n0 0 0 1 0 0 1 1 0 0 1 0\nPOLYGONS 1 5\n4 0 1 2 3\n"
        >>
    ),
    ?assertEqual(2, length(Ts)).
binary_strip_test() ->
    B = binary_fixture(<<4:32, 0:32, 1:32, 2:32, 3:32>>),
    {ok, #{triangles := [A, C]}} = erm_anatomy_vtk:parse(B),
    ?assertEqual({{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}}, A),
    ?assertEqual({{0.0, 1.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}}, C).
invalid_index_and_truncation_test() ->
    ?assertMatch(
        {error, _}, erm_anatomy_vtk:parse(binary_fixture(<<4:32, 0:32, 1:32, 2:32, 90:32>>))
    ),
    ?assertMatch({error, _}, erm_anatomy_vtk:parse(binary_fixture(<<4:32, 0:32>>))),
    ?assertMatch(
        {error, _},
        erm_anatomy_vtk:parse(
            <<"# vtk DataFile Version 3.0\nf\nBINARY\nDATASET POLYDATA\nPOINTS 999999999 float\n">>
        )
    ).
binary_fixture(Cells) ->
    Points =
        <<0.0:32/float, 0.0:32/float, 0.0:32/float, 1.0:32/float, 0.0:32/float, 0.0:32/float,
            0.0:32/float, 1.0:32/float, 0.0:32/float, 1.0:32/float, 1.0:32/float, 0.0:32/float>>,
    <<"# vtk DataFile Version 3.0\nf\nBINARY\nDATASET POLYDATA\nPOINTS 4 float\n", Points/binary,
        "\nTRIANGLE_STRIPS 1 5\n", Cells/binary, "\n">>.
