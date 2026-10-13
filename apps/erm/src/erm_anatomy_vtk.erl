%% Bounded legacy VTK POLYDATA surface reader (ASCII and big-endian binary).
%% Volumes, XML VTK and VTK 5.x offset/connectivity arrays are not accepted.
-module(erm_anatomy_vtk).
-export([parse/1]).
-define(MAX_BYTES, 16777216).
-define(MAX_POINTS, 150000).
-define(MAX_TRIANGLES, 50000).

parse(B) when is_binary(B), byte_size(B) =< ?MAX_BYTES ->
    try
        {<<"# vtk DataFile Version ", _/binary>>, B1} = line(B),
        {_Title, B2} = line(B1),
        {Mode, B3} = line(B2),
        true = Mode =:= <<"BINARY">> orelse Mode =:= <<"ASCII">>,
        {<<"DATASET POLYDATA">>, B4} = line(B3),
        {Header, B5} = line(B4),
        [<<"POINTS">>, Count, Type] = words(Header),
        N = binary_to_integer(Count),
        true = N > 0 andalso N =< ?MAX_POINTS,
        {Coordinates, Rest} = values(Mode, Type, 3 * N, B5),
        Points = list_to_tuple(points(Coordinates)),
        Faces = cells(Mode, Rest, [], 0),
        true = Faces =/= [],
        {ok, #{
            triangles => [
                {element(A + 1, Points), element(C + 1, Points), element(D + 1, Points)}
             || {A, C, D} <- Faces
            ]
        }}
    catch
        _:_ -> {error, invalid_or_oversized_vtk}
    end;
parse(_) ->
    {error, mesh_too_large}.

line(B) ->
    [L, Rest] = binary:split(B, <<"\n">>),
    {string:trim(L), Rest}.
words(B) -> string:lexemes(B, " \t\r\n").
points([]) -> [];
points([X, Y, Z | Rest]) -> [{X, Y, Z} | points(Rest)].

values(<<"BINARY">>, <<"float">>, N, B) ->
    Size = N * 4,
    <<Data:Size/binary, Rest/binary>> = B,
    {[V || <<V:32/float-big>> <= Data], Rest};
values(<<"BINARY">>, <<"double">>, N, B) ->
    Size = N * 8,
    <<Data:Size/binary, Rest/binary>> = B,
    {[V || <<V:64/float-big>> <= Data], Rest};
values(<<"BINARY">>, <<"int">>, N, B) ->
    Size = N * 4,
    <<Data:Size/binary, Rest/binary>> = B,
    {[V || <<V:32/signed-big>> <= Data], Rest};
values(<<"ASCII">>, Type, N, B) when
    Type =:= <<"float">>; Type =:= <<"double">>; Type =:= <<"int">>
->
    ascii_values(N, B, Type, []).
ascii_values(0, B, _, Acc) ->
    {lists:reverse(Acc), B};
ascii_values(N, B, Type, Acc) ->
    {match, [{Start, Length}]} = re:run(B, <<"^\\s*(\\S+)">>, [{capture, [1], index}]),
    Token = binary:part(B, Start, Length),
    Tail = binary:part(B, Start + Length, byte_size(B) - Start - Length),
    V =
        case Type of
            <<"int">> -> binary_to_integer(Token);
            _ -> number(Token)
        end,
    ascii_values(N - 1, Tail, Type, [V | Acc]).
number(B) ->
    S = binary_to_list(B),
    case string:to_float(S) of
        {F, []} ->
            F;
        _ ->
            case re:run(B, <<"^([+-]?[0-9]+)([eE][+-]?[0-9]+)$">>, [{capture, [1, 2], binary}]) of
                {match, [Mantissa, Exponent]} ->
                    binary_to_float(<<Mantissa/binary, ".0", Exponent/binary>>);
                nomatch ->
                    float(binary_to_integer(B))
            end
    end.

cells(Mode, B0, Acc, Total) ->
    B = string:trim(B0, leading, "\r\n \t"),
    case B of
        <<>> ->
            lists:append(lists:reverse(Acc));
        <<"POINT_DATA ", _/binary>> ->
            lists:append(lists:reverse(Acc));
        <<"CELL_DATA ", _/binary>> ->
            lists:append(lists:reverse(Acc));
        _ ->
            {Header, Body} = line(B),
            [Kind, Count, Size] = words(Header),
            true = lists:member(Kind, [
                <<"POLYGONS">>, <<"TRIANGLE_STRIPS">>, <<"VERTICES">>, <<"LINES">>
            ]),
            C = binary_to_integer(Count),
            I = binary_to_integer(Size),
            true = C >= 0 andalso C =< ?MAX_TRIANGLES,
            true = I >= C andalso I =< 4 * ?MAX_POINTS,
            {Indices, Rest} = values(Mode, <<"int">>, I, Body),
            {Faces, Added} = decode_cells(C, Indices, Kind, [], Total),
            cells(Mode, Rest, [Faces | Acc], Added)
    end.
decode_cells(0, [], _, Acc, Total) ->
    {lists:append(lists:reverse(Acc)), Total};
decode_cells(N, [K | Ints], Kind, Acc, Total) when N > 0, K >= 0 ->
    {Cell, Rest} = lists:split(K, Ints),
    true = lists:all(fun(I) -> I >= 0 andalso I < ?MAX_POINTS end, Cell),
    Faces =
        case Kind of
            <<"POLYGONS">> ->
                [A, B | Cs] = Cell,
                fan(A, B, Cs);
            <<"TRIANGLE_STRIPS">> ->
                strip(Cell, false);
            _ ->
                []
        end,
    Next = Total + length(Faces),
    true = Next =< ?MAX_TRIANGLES,
    decode_cells(N - 1, Rest, Kind, [Faces | Acc], Next).
fan(_, _, []) -> [];
fan(A, B, [C | Rest]) -> [{A, B, C} | fan(A, C, Rest)].
strip([A, B, C | Rest], Flip) ->
    T =
        case Flip of
            false -> {A, B, C};
            true -> {B, A, C}
        end,
    case A =:= B orelse B =:= C orelse A =:= C of
        true -> strip([B, C | Rest], not Flip);
        false -> [T | strip([B, C | Rest], not Flip)]
    end;
strip(_, _) ->
    [].
