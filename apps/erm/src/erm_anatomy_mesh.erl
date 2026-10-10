%% Local OBJ loading and orthographic SVG software rendering. Apache-2.0.
-module(erm_anatomy_mesh).
-export([load/1, parse/1, svg/4, svg/5, pick/6, bounds/1]).
-include_lib("kernel/include/file.hrl").
-define(MAX_BYTES, 16777216).
-define(MAX_TRIANGLES, 50000).

load(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} when Info#file_info.size =< ?MAX_BYTES ->
            case file:read_file(Path) of
                {ok, B} -> case filename:extension(Path) of
                    Ext when Ext=:= ".vtk"; Ext=:= <<".vtk">> -> erm_anatomy_vtk:parse(B);
                    _ -> parse(B)
                end;
                E -> E
            end;
        {ok, _} -> {error, mesh_too_large};
        E -> E
    end.

parse(B) when is_binary(B), byte_size(B) =< ?MAX_BYTES ->
    try
        {Vs, Fs, _} = lists:foldl(fun line/2, {[], [], 0}, binary:split(B, <<"\n">>, [global])),
        V = list_to_tuple(lists:reverse(Vs)),
        true = tuple_size(V) > 0,
        Triangles = lists:append(lists:reverse(Fs)),
        true = Triangles =/= [],
        true = length(Triangles) =< ?MAX_TRIANGLES,
        T = [{element(A,V),element(C,V),element(D,V)} || {A,C,D} <- Triangles],
        {ok, #{triangles => T}} 
    catch _:_ -> {error, invalid_or_oversized_obj} end;
parse(_) -> {error, mesh_too_large}.

line(B, {Vs,Fs,N}=S) ->
    Tokens = string:lexemes(binary_to_list(hd(binary:split(B, <<"#">>))), " \t\r"),
    case Tokens of
        ["v",X,Y,Z|_] -> {[{number(X),number(Y),number(Z)}|Vs],Fs,N+1};
        ["f"|Ids] when length(Ids) >= 3 ->
            [A,C|Rest] = [index(I,N) || I <- Ids],
            Faces = fan(A,C,Rest),
            {Vs, [Faces|Fs],N};
        _ -> S
    end.
number(S) ->
    case string:to_float(S) of
        {F,[]} -> F;
        _ -> float(list_to_integer(S))
    end.
index(S,N) ->
    I = list_to_integer(hd(string:split(S,"/",all))),
    R = case I of X when X < 0 -> N+X+1; X -> X end,
    true = R > 0 andalso R =< N,
    R.
fan(_,_,[]) -> [];
fan(A,B,[C|Cs]) -> [{A,B,C}|fan(A,C,Cs)].

bounds(Parts) ->
    Points = [P || #{mesh := #{triangles := Ts}} <- Parts, {A,B,C} <- Ts, P <- [A,B,C]],
    case Points of
        [] -> {{0.0,0.0,0.0},1.0};
        [{X,Y,Z}|Rest] ->
            {X0,Y0,Z0,X1,Y1,Z1} = lists:foldl(fun({A,B,C},{D,E,F,G,H,I}) ->
                {min(A,D),min(B,E),min(C,F),max(A,G),max(B,H),max(C,I)}
            end,{X,Y,Z,X,Y,Z},Rest),
            {{(X0+X1)/2,(Y0+Y1)/2,(Z0+Z1)/2},max(0.001,math:sqrt(
                (X1-X0)*(X1-X0)+(Y1-Y0)*(Y1-Y0)+(Z1-Z0)*(Z1-Z0)))}
    end.

svg(Parts, Camera, Bounds, Selected) -> svg(Parts,Camera,Bounds,Selected,{0.0,0.0}).
svg(Parts, {Yaw,Pitch,Zoom}, Bounds, Selected, Pan) ->
    Project = fun(P) -> translate(project(P,Yaw,Pitch,Zoom,Bounds),Pan) end,
    Faces = lists:append([[
        face(Project(A),Project(B),Project(C),maps:get(color,P,{175,190,205}),
             maps:get(id,P) =:= Selected)
        || {A,B,C} <- maps:get(triangles,maps:get(mesh,P))]
        || P <- Parts, maps:get(visible,P,true)]),
    Sorted = lists:keysort(1,Faces),
    iolist_to_binary(["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"900\" height=\"700\" viewBox=\"0 0 900 700\"><rect width=\"900\" height=\"700\" fill=\"#101820\"/>",
        [S || {_,S} <- Sorted],"</svg>"]).
project({X,Y,Z},Yaw,Pitch,Zoom,{{CX,CY,CZ},D}) ->
    A=(X-CX), B=(Y-CY), C=(Z-CZ),
    U=A*math:cos(Yaw)+C*math:sin(Yaw),
    V=C*math:cos(Yaw)-A*math:sin(Yaw),
    W=B*math:cos(Pitch)-V*math:sin(Pitch),
    Depth=B*math:sin(Pitch)+V*math:cos(Pitch),
    Scale=580*Zoom/D,
    {450+U*Scale,350-W*Scale,Depth}.
face({X,Y,Z},{A,B,C},{D,E,F},{R,G,H},Selected) ->
    Light=0.65+0.35*abs((A-X)*(E-Y)-(B-Y)*(D-X))/
        max(1.0,math:sqrt(((A-X)*(A-X)+(B-Y)*(B-Y))*((D-X)*(D-X)+(E-Y)*(E-Y)))),
    Color=case Selected of true -> {255,190,70}; false -> {R,G,H} end,
    {CR,CG,CB}=Color,
    {(Z+C+F)/3,io_lib:format("<polygon points=\"~.2f,~.2f ~.2f,~.2f ~.2f,~.2f\" fill=\"rgb(~B,~B,~B)\"/>",
        [X,Y,A,B,D,E,round(CR*Light),round(CG*Light),round(CB*Light)])}.

translate({X,Y,Z},{PX,PY}) -> {X+PX,Y+PY,Z}.

%% Match the software renderer's painter order; hidden parts cannot be picked.
pick(Parts,{Yaw,Pitch,Zoom},Bounds,Pan,{X,Y},{Width,Height})
  when Width>0, Height>0 ->
    Scale = min(Width/900,Height/700),
    SX = (X-(Width-900*Scale)/2)/Scale,
    SY = (Y-(Height-700*Scale)/2)/Scale,
    case SX>=0 andalso SX=<900 andalso SY>=0 andalso SY=<700 of
        false -> undefined;
        true ->
            Project = fun(P) -> translate(project(P,Yaw,Pitch,Zoom,Bounds),Pan) end,
            Hits = lists:append([[begin
                PA={_,_,ZA}=Project(A), PB={_,_,ZB}=Project(B), PC={_,_,ZC}=Project(C),
                case inside({SX,SY},PA,PB,PC) of
                    true -> {(ZA+ZB+ZC)/3,maps:get(id,P)};
                    false -> none
                end
            end || {A,B,C} <- maps:get(triangles,maps:get(mesh,P))]
            || P <- Parts,maps:get(visible,P,true)]),
            case lists:keysort(1,[H || H <- Hits,H=/=none]) of
                [] -> undefined;
                Sorted -> element(2,lists:last(Sorted))
            end
    end;
pick(_,_,_,_,_,_) -> undefined.
inside({X,Y},{AX,AY,_},{BX,BY,_},{CX,CY,_}) ->
    Area=(BX-AX)*(CY-AY)-(BY-AY)*(CX-AX),
    A=(BX-AX)*(Y-AY)-(BY-AY)*(X-AX),
    B=(CX-BX)*(Y-BY)-(CY-BY)*(X-BX),
    C=(AX-CX)*(Y-CY)-(AY-CY)*(X-CX),
    abs(Area)>0.000001 andalso
        ((A>=0 andalso B>=0 andalso C>=0) orelse (A=<0 andalso B=<0 andalso C=<0)).
