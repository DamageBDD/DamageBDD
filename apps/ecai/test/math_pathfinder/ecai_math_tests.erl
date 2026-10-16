-module(ecai_math_tests).
-include_lib("eunit/include/eunit.hrl").
-define(Q,ecai_math_q).
-define(P,ecai_math_poly).
-define(C,ecai_math_curve).
-define(I,ecai_math_isogeny).
-define(F,ecai_math_pathfinder).

q_canonical_test() -> ?assertEqual({-1,2},?Q:new({2,-4})).
q_zero_test() -> ?assertEqual({0,1},?Q:new({0,-29})).
q_float_rejected_test() -> ?assertError(invalid_or_oversized_rational,?Q:new(1.0)).
q_zero_denominator_test() -> ?assertError(zero_denominator,?Q:new({1,0})).
q_limit_test() -> ?assertError(invalid_or_oversized_rational,?Q:new(1 bsl 8192)).
q_arithmetic_test() ->
    ?assertEqual({5,6},?Q:add({1,2},{1,3})),
    ?assertEqual({1,6},?Q:sub({1,2},{1,3})),
    ?assertEqual({1,6},?Q:mul({1,2},{1,3})),
    ?assertEqual({3,2},?Q:divide({1,2},{1,3})),
    ?assertEqual({-8,27},?Q:pow({-2,3},3)).
poly_zero_test() -> ?assertEqual([],?P:new([0,0,0])).
poly_product_test() -> ?assertEqual(?P:new([-1,0,1]),?P:mul(?P:new([-1,1]),?P:new([1,1]))).
poly_division_test() -> ?assertEqual({?P:new([1,1]),[]},?P:divmod(?P:new([-1,0,1]),?P:new([-1,1]))).
poly_fraction_test() ->
    ?assertEqual({?P:new([1,1]),?P:new([1])},?P:fraction(?P:new([-2,0,2]),?P:new([-2,2]))).
poly_derivative_test() -> ?assertEqual(?P:new([2,6]),?P:derivative(?P:new([1,2,3]))).
curve_singular_test() -> ?assertEqual({error,singular_curve},?C:new(0,0,0)).
curve_identity_test() ->
    {ok,A}=?C:new(0,-1,0), {ok,B}=?C:new({0,3},{-2,2},{0,-4}),
    ?assertEqual(?C:id(A),?C:id(B)), ?assertEqual({64,1},?C:discriminant(A)).
curve_field_test() -> ?assertMatch({error,_},?C:normalize(#{kind=>elliptic_curve,field=>real,a2=>0,a4=>1,a6=>1})).
verify_two_test() ->
    {_,Phi,_,_,_}=fixture(),
    ?assertMatch({ok,#{status:=verified,degree:=2,formal_proof:=false}},?I:verify(Phi)).
verify_nonzero_root_test() ->
    {ok,E}=?C:new(0,-1,0), {ok,Phi}=?I:two(E,1),
    ?assertMatch({ok,_},?I:verify(Phi)),
    ?assertEqual({-6,1},maps:get(a2,maps:get(codomain,Phi))).
reject_non_kernel_test() -> {ok,E}=?C:new(0,-1,0), ?assertMatch({error,kernel_not_rational_two_torsion},?I:two(E,2)).
verify_scale_test() -> {ok,E}=?C:new(0,-1,0), {ok,Phi}=?I:scale(E,{2,3}), ?assertMatch({ok,#{degree:=1}},?I:verify(Phi)).
zero_scale_test() -> {ok,E}=?C:new(0,-1,0), ?assertEqual({error,zero_scale},?I:scale(E,0)).
wrong_degree_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({error,degree_mismatch},?I:verify(Phi#{degree:=3})).
wrong_codomain_test() ->
    {_,Phi,_,_,_}=fixture(), {ok,Wrong}=?C:new(0,5,0),
    ?assertEqual({error,curve_identity_failed},?I:verify(Phi#{codomain:=Wrong})).
tampered_map_test() ->
    {_,Phi,_,_,_}=fixture(),
    ?assertEqual({error,curve_identity_failed},?I:verify(Phi#{x_num:=?P:new([-2,0,1])})).
constant_map_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({error,infinity_not_preserved},?I:verify(Phi#{x_num:=[],x_den:=[1]})).
zero_polynomial_denominator_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({error,zero_polynomial_denominator},?I:verify(Phi#{x_den:=[]})).
verified_flag_rejected_test() -> {_,Phi,_,_,_}=fixture(), ?assertMatch({error,_},?I:verify(Phi#{verified=>true})).
point_at_kernel_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({ok,infinity},?I:evaluate(Phi,{0,0})).
point_image_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({ok,{{0,1},{0,1}}},?I:evaluate(Phi,{1,0})).
point_off_curve_test() -> {_,Phi,_,_,_}=fixture(), ?assertEqual({error,point_not_on_source},?I:evaluate(Phi,{2,1})).
demo_test() ->
    {ok,P}=?F:demo(), ?assertEqual(4,maps:get(total_degree,P)),
    ?assertEqual(2,maps:get(hops,P)), ?assertMatch({ok,#{status:=verified}},?F:verify_path(P)).
identity_path_test() ->
    {E,_,_,_,G}=fixture(), {ok,P}=?F:find(G,E,E),
    ?assertEqual(1,maps:get(total_degree,P)), ?assertEqual([],maps:get(steps,P)),
    ?assertEqual(0,maps:get(total_cost,P)), ?assertMatch({ok,_},?F:verify_path(P)).
depth_bound_test() ->
    {E,_,_,T,G}=fixture(),
    ?assertMatch({error,#{reason:=not_found_within_bounds}},?F:find(G,E,T,#{max_depth=>1})).
state_bound_test() ->
    {E,_,_,T,G}=fixture(),
    ?assertEqual({error,{search_limit,max_states}},?F:find(G,E,T,#{max_states=>1})).
invalid_option_test() -> {E,_,_,T,G}=fixture(), ?assertEqual({error,unknown_search_option},?F:find(G,E,T,#{max_dept=>2})).
weighted_path_test() ->
    {E,_,_,T,G}=fixture(), {ok,Direct}=?I:scale(E,2),
    {ok,G1}=?F:add_isogeny(G,Direct,#{cost=>10}),
    {ok,P}=?F:find(G1,E,T), ?assertEqual(2,maps:get(total_cost,P)),
    {ok,Short}=?F:find(G1,E,T,#{max_depth=>1}), ?assertEqual(10,maps:get(total_cost,Short)).
depth_sensitive_dijkstra_test() ->
    {E,_,_,T,G}=fixture(), {ok,Direct}=?I:scale(E,2),
    {ok,G1}=?F:add_isogeny(G,Direct,#{cost=>10}), {ok,Last}=?I:scale(T,3),
    {ok,G2}=?F:add_isogeny(G1,Last),
    {ok,P}=?F:find(G2,E,maps:get(codomain,Last),#{max_depth=>2}),
    ?assertEqual(11,maps:get(total_cost,P)), ?assertEqual(2,maps:get(hops,P)).
cycle_bound_test() ->
    {E,_,_,T,_}=fixture(), {ok,Self}=?I:scale(E,1),
    {ok,G1}=?F:add_isogeny(?F:new(),Self), {ok,G2}=?F:add_curve(G1,T),
    ?assertMatch({error,#{reason:=not_found_within_bounds}},?F:find(G2,E,T,#{max_depth=>5})).
negative_cost_test() -> {_,Phi,_,_,G}=fixture(), ?assertEqual({error,invalid_cost},?F:add_isogeny(G,Phi,#{cost=>-1})).
duplicate_cost_test() -> {_,Phi,_,_,G}=fixture(), ?assertEqual({error,duplicate_cost_conflict},?F:add_isogeny(G,Phi,#{cost=>2})).
deterministic_order_test() ->
    {E,Phi,Psi,T,G}=fixture(),
    {ok,G1}=?F:add_isogeny(?F:new(),Psi), {ok,G2}=?F:add_isogeny(G1,Phi),
    {ok,A}=?F:find(G,E,T), {ok,B}=?F:find(G2,E,T), ?assertEqual(maps:get(id,A),maps:get(id,B)).
forged_graph_test() ->
    {E,Phi,_,T,G}=fixture(), Id=?I:id(Phi), Edges=maps:get(edges,G), Entry=maps:get(Id,Edges),
    Bad=Phi#{degree:=3}, Forged=G#{edges:=Edges#{Id:=Entry#{map:=Bad,verified=>true}}},
    ?assertMatch({error,#{reason:=not_found_within_bounds}},?F:find(Forged,E,T)).
replay_tamper_test() ->
    {ok,P}=?F:demo(),
    ?assertEqual({error,composite_degree_mismatch},?F:verify_path(P#{total_degree:=999,verification=>#{status=>verified}})).
replay_disconnect_test() ->
    {ok,P}=?F:demo(),
    ?assertEqual({error,disconnected_path},?F:verify_path(P#{steps:=lists:reverse(maps:get(steps,P))})).
replay_id_tamper_test() -> {ok,P}=?F:demo(), ?assertEqual({error,path_id_mismatch},?F:verify_path(P#{id:=<<"fake">>})).
discover_three_kernels_test() ->
    {ok,E}=?C:new(0,-1,0), {ok,Maps}=?I:discover_two(E,#{}), ?assertEqual(3,length(Maps)),
    lists:foreach(fun(M) -> ?assertMatch({ok,_},?I:verify(M)) end,Maps).
discover_and_solve_test_() -> {timeout,35,fun() ->
    {E,_,_,T,_}=fixture(), {ok,P}=?F:solve_two(E,T,#{max_depth=>2}),
    ?assertEqual(4,maps:get(total_degree,P)) end}.
expansion_limit_test() ->
    {E,_,_,_,_}=fixture(),
    ?assertEqual({error,{expansion_limit,max_curves}},?F:expand_two(?F:new(),E,#{max_curves=>1})).
graph_json_roundtrip_test() ->
    {E,_,_,T,G}=fixture(), {ok,Bin}=ecai_math_codec:encode(G),
    {ok,G1}=ecai_math_codec:decode(Bin), {ok,P1}=?F:find(G,E,T), {ok,P2}=?F:find(G1,E,T),
    ?assertEqual(maps:get(id,P1),maps:get(id,P2)).
receipt_json_roundtrip_test() ->
    {ok,P}=?F:demo(), {ok,B}=ecai_math_codec:encode(P),
    {ok,P1}=ecai_math_codec:decode(B), ?assertEqual(maps:get(id,P),maps:get(id,P1)),
    ?assertMatch({ok,_},?F:verify_path(P1)).
json_size_limit_test() -> ?assertEqual({error,document_size_limit},ecai_math_codec:decode(binary:copy(<<"x">>,2097153))).
malformed_json_test() -> ?assertMatch({error,_},ecai_math_codec:decode(<<"{oops">>)).
job_timeout_test() -> ?assertEqual({error,timeout},ecai_math_job:run(fun() -> timer:sleep(1000),ok end,1)).
job_exception_test() -> ?assertEqual({error,deliberate},ecai_math_job:run(fun() -> error(deliberate) end,100)).
bridge_test() ->
    {ok,P}=?F:demo(),
    case code:ensure_loaded(ecai_relation) of
        {module,ecai_relation} ->
            {ok,R}=?F:to_relation(P), ?assertEqual({isogenous_over,q},ecai_relation:predicate(R));
        {error,_} -> ?assertEqual({error,ecai_relation_unavailable},?F:to_relation(P))
    end.
bdd_steps_test() ->
    C1=steps_ecai_math:step([],#{},<<"Given">>,1,["the ECAI mathematical pathfinder demo graph"],<<>>),
    C2=steps_ecai_math:step([],C1,<<"When">>,2,["I find the mathematical path"],<<>>),
    C3=steps_ecai_math:step([],C2,<<"Then">>,3,["the mathematical path has composite degree","4"],<<>>),
    C4=steps_ecai_math:step([],C3,<<"Then">>,4,["every mathematical path step replays successfully"],<<>>),
    ?assertNot(maps:is_key(fail,C4)), ?assert(maps:is_key(ecai_math_receipt,C4)).

apply_path_test() ->
    {ok,P}=?F:demo(), ?assertEqual({ok,infinity},?F:apply_path(P,{1,0})).
apply_identity_test() ->
    {E,_,_,_,G}=fixture(), {ok,P}=?F:find(G,E,E),
    ?assertEqual({ok,{{1,1},{0,1}}},?F:apply_path(P,{1,0})).
receipt_exclusive_file_test() ->
    Name=filename:join(filename:dirname(code:which(?MODULE)),"receipt-test.json"),
    try
        {ok,P}=?F:demo(), ?assertEqual(ok,ecai_math_codec:save(Name,P)),
        ?assertEqual({error,eexist},ecai_math_codec:save(Name,P)),
        ?assertMatch({ok,#{kind:=mathematical_path}},ecai_math_codec:load(Name))
    after file:delete(Name) end.

fixture() ->
    {ok,E}=?C:new(0,-1,0), {ok,Phi}=?I:two(E,0),
    {ok,Psi}=?I:two(maps:get(codomain,Phi),0), T=maps:get(codomain,Psi),
    {ok,G1}=?F:add_isogeny(?F:new(),Phi), {ok,G2}=?F:add_isogeny(G1,Psi),
    {E,Phi,Psi,T,G2}.
