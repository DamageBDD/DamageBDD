%% JSON interchange for mathematical graphs and replayable path receipts.
%% Requires OTP 27+ json. Fixed-key decoding never creates atoms from input.
-module(ecai_math_codec).
-export([encode/1, decode/1, load/1, save/2]).
-define(MAX_BYTES,2097152).
-define(F,ecai_math_pathfinder).

-spec encode(map()) -> {ok,binary()} | {error,term()}.
encode(Thing) ->
    ecai_math_job:run(fun() ->
        Wire = case Thing of
            #{kind:=math_graph,curves:=Curves,edges:=Edges} ->
                #{schema=>1,kind=>math_graph,
                  curves=>[C || {_,C} <- lists:sort(maps:to_list(Curves))],
                  edges=>[maps:with([map,cost,origins],E) || {_,E} <- lists:sort(maps:to_list(Edges))]};
            #{kind:=mathematical_path,total_degree:=D} ->
                _ = must(?F:verify_path(Thing)), Thing#{total_degree:=integer_to_binary(D)};
            _ -> error(unsupported_document)
        end,
        Bin = iolist_to_binary(json:encode(wire(Wire))),
        need(byte_size(Bin) =< ?MAX_BYTES,document_size_limit), {ok,Bin}
    end,5000).
wire({N,D}) when is_integer(N), is_integer(D) -> [integer_to_binary(N),integer_to_binary(D)];
wire(M) when is_map(M) -> maps:from_list([{key(K),wire(V)} || {K,V} <- maps:to_list(M)]);
wire(L) when is_list(L) -> [wire(V) || V <- L];
wire(true) -> true;
wire(false) -> false;
wire(null) -> null;
wire(A) when is_atom(A) -> atom_to_binary(A,utf8);
wire(V) when is_integer(V), abs(V) > 9007199254740991 -> integer_to_binary(V);
wire(V) when is_binary(V); is_integer(V) -> V;
wire(_) -> error(unsupported_json_value).
key(A) when is_atom(A) -> atom_to_binary(A,utf8);
key(B) when is_binary(B) -> B.

-spec decode(binary()) -> {ok,map()} | {error,term()}.
decode(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_BYTES ->
    ecai_math_job:run(fun() -> document(json:decode(Bin)) end,10000);
decode(_) -> {error,document_size_limit}.
document(#{<<"schema">>:=1,<<"kind">>:=<<"math_graph">>,
           <<"curves">>:=Curves,<<"edges">>:=Edges})
    when is_list(Curves),length(Curves) =< 4000,is_list(Edges),length(Edges) =< 10000 ->
    G0 = lists:foldl(fun(C,G) -> must(?F:add_curve(G,curve(C))) end,?F:new(),Curves),
    G = lists:foldl(fun(Step,Acc) ->
        #{map:=Map,cost:=Cost,origins:=Origins} = step(Step),
        %% Empty provenance is not accepted on graph import.
        need(Origins =/= [],missing_source),
        lists:foldl(fun(O,A) -> must(?F:add_isogeny(A,Map,#{cost=>Cost,source=>O})) end,Acc,Origins)
    end,G0,Edges), {ok,G};
document(#{<<"schema">>:=1,<<"kind">>:=<<"mathematical_path">>}=W) ->
    Steps = maps:get(<<"steps">>,W),
    need(is_list(Steps) andalso length(Steps) =< 64,invalid_steps),
    P = #{schema=>1,kind=>mathematical_path,source=>curve(maps:get(<<"source">>,W)),
          target=>curve(maps:get(<<"target">>,W)),steps=>[step(S) || S <- Steps],
          total_cost=>maps:get(<<"total_cost">>,W),total_degree=>integer(maps:get(<<"total_degree">>,W)),
          hops=>maps:get(<<"hops">>,W),id=>maps:get(<<"id">>,W)},
    %% Ignore submitted verification flags and recompute all evidence.
    Proof = must(?F:verify_path(P)), {ok,P#{verification=>Proof}};
document(_) -> {error,invalid_document_schema}.
curve(#{<<"kind">>:=<<"elliptic_curve">>,<<"field">>:=<<"q">>,
        <<"a2">>:=A,<<"a4">>:=B,<<"a6">>:=C}) ->
    must(ecai_math_curve:new(rational(A),rational(B),rational(C)));
curve(_) -> error(unsupported_curve_model).
step(#{<<"map">>:=M,<<"cost">>:=Cost,<<"origins">>:=Origins}) ->
    need(is_list(Origins) andalso length(Origins) =< 16 andalso
         lists:all(fun(O) -> is_binary(O) andalso byte_size(O) =< 1024 end,Origins),invalid_origins),
    #{map=>isogeny(M),cost=>Cost,origins=>Origins};
step(_) -> error(invalid_step).
isogeny(#{<<"kind">>:=<<"isogeny">>,<<"domain">>:=S,<<"codomain">>:=T,
           <<"degree">>:=D,<<"x_num">>:=N,<<"x_den">>:=Den,<<"y_num">>:=M,<<"y_den">>:=L}) ->
    must(ecai_math_isogeny:new(curve(S),curve(T),#{degree=>D,x_num=>poly(N),x_den=>poly(Den),
                                                y_num=>poly(M),y_den=>poly(L)}));
isogeny(_) -> error(invalid_map_schema).
poly(L) when is_list(L),length(L) =< 65 -> [rational(Q) || Q <- L];
poly(_) -> error(polynomial_size_limit).
rational([N,D]) -> ecai_math_q:new({integer(N),integer(D)});
rational(_) -> error(invalid_rational_encoding).
integer(N) when is_integer(N),abs(N) < (1 bsl 1024) -> N;
integer(B) when is_binary(B),byte_size(B) > 0,byte_size(B) =< 310 ->
    N = binary_to_integer(B), need(abs(N) < (1 bsl 1024),integer_size_limit), N;
integer(_) -> error(invalid_integer_encoding).

-spec load(file:filename_all()) -> {ok,map()} | {error,term()}.
load(Path) ->
    case file:open(Path,[read,raw,binary]) of
        {ok,F} ->
            Read = try file:read(F,?MAX_BYTES+1) after file:close(F) end,
            case Read of {ok,B} -> decode(B); eof -> {error,empty_document}; Error -> Error end;
        Error -> Error
    end.
%% Exclusive creation: never silently overwrite a prior report.
-spec save(file:filename_all(),map()) -> ok | {error,term()}.
save(Path,Thing) ->
    case encode(Thing) of
        {ok,Bin} -> file:write_file(Path,Bin,[exclusive]);
        {error,_}=Error -> Error
    end.
must({ok,V}) -> V;
must({error,R}) -> error(R).
need(true,_) -> ok;
need(false,R) -> error(R).
