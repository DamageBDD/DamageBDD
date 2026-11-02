%% Wire validation and bounded mathematical work for the dashboard.
%% JSON is data, never Erlang source. Imported receipts are never trusted.
-module(ecai_math_dashboard_task).
-export([prepare/1, execute/1, max_bytes/0]).

-define(MAX_BYTES, 262144).
max_bytes() -> ?MAX_BYTES.

-spec prepare(term()) -> {ok, map()} | {error, term()}.
prepare(Input) ->
    try {ok, prepare_1(Input)} catch error:Reason -> {error, Reason} end.

prepare_1(#{<<"operation">> := <<"demo">>} = M) ->
    only(M, [<<"operation">>]), #{operation => demo};
prepare_1(#{<<"operation">> := <<"explore">>, <<"source">> := S} = M) ->
    only(M, [<<"operation">>, <<"source">>, <<"bounds">>]),
    #{operation => explore, source => curve(S),
      bounds => exploration_bounds(maps:get(<<"bounds">>, M, #{}))};
prepare_1(#{<<"operation">> := <<"discover">>, <<"source">> := S,
            <<"target">> := T} = M) ->
    only(M, [<<"operation">>, <<"source">>, <<"target">>, <<"bounds">>]),
    #{operation => discover, source => curve(S), target => curve(T),
      bounds => bounds(maps:get(<<"bounds">>, M, #{}))};
prepare_1(#{<<"operation">> := <<"import">>, <<"path_json">> := B} = M)
        when is_binary(B), byte_size(B) > 0, byte_size(B) =< ?MAX_BYTES ->
    only(M, [<<"operation">>, <<"path_json">>]),
    %% Decoding/checking is deliberately deferred until a worker slot exists.
    #{operation => import, path_json => B};
prepare_1(_) -> error(invalid_math_request).

curve(#{<<"a2">> := A, <<"a4">> := B, <<"a6">> := C} = M) ->
    only(M, [<<"a2">>, <<"a4">>, <<"a6">>]),
    must(ecai_math_curve:new(rational(A), rational(B), rational(C)));
curve(_) -> error(invalid_curve).
rational([N, D]) -> ecai_math_q:new({integer(N), integer(D)});
rational(_) -> error(exact_string_pair_required).
integer(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 64 ->
    case re:run(B, <<"^-?[0-9]+$">>, [{capture, none}]) of
        match -> binary_to_integer(B);
        nomatch -> error(invalid_integer)
    end;
integer(_) -> error(integer_string_required).
bounds(M) when is_map(M) ->
    only(M, [<<"max_depth">>, <<"max_curves">>, <<"numerator_bound">>, <<"denominator_bound">>]),
    #{max_depth => bounded(M, <<"max_depth">>, 2, 0, 3),
      max_curves => bounded(M, <<"max_curves">>, 64, 1, 64),
      numerator_bound => bounded(M, <<"numerator_bound">>, 8, 0, 32),
      denominator_bound => bounded(M, <<"denominator_bound">>, 4, 1, 16)};
bounds(_) -> error(invalid_bounds).
exploration_bounds(M) when is_map(M) ->
    only(M, [<<"max_depth">>, <<"max_curves">>, <<"numerator_bound">>,
             <<"denominator_bound">>, <<"timeout_ms">>]),
    #{max_depth => bounded(M, <<"max_depth">>, 2, 0, 3),
      max_curves => bounded(M, <<"max_curves">>, 24, 1, 32),
      numerator_bound => bounded(M, <<"numerator_bound">>, 8, 0, 32),
      denominator_bound => bounded(M, <<"denominator_bound">>, 4, 1, 16),
      timeout_ms => bounded(M, <<"timeout_ms">>, 8000, 1, 20000)};
exploration_bounds(_) -> error(invalid_bounds).
bounded(M, Key, Default, Min, Max) ->
    V = maps:get(Key, M, Default),
    need(is_integer(V) andalso V >= Min andalso V =< Max, {invalid_bound, Key}), V.
only(M, Keys) -> need(maps:without(Keys, M) =:= #{}, unexpected_fields).

-spec execute(map()) -> {ok, map()} | {error, term()}.
execute(#{operation := explore, source := S, bounds := B}) ->
    try
        R = must(ecai_math_explorer:explore(S,B)),
        Bin = must(ecai_math_explorer:encode(R)),
        {ok, #{exploration => json:decode(Bin), exploration_json => Bin,
               artifact_sha256 => sha(Bin), elapsed_ms => maps:get(elapsed_ms,R),
               checked_at_ms => erlang:system_time(millisecond),
               evidence => #{native_replay => passed, q_classification => checked,
                   formal_proof => false, independent_check => not_attached,
                   damagebdd_run => not_attached, provenance => not_authenticated},
               metadata => #{mode => source_only_exploration, generation_bounds => B,
                   note => <<"No target supplied. A stopped exploration retains checked paths; it does not claim a complete isogeny class or mathematical novelty.">>}}}
    catch error:Reason -> {error,Reason} end;
execute(Task) ->
    try
        Start = erlang:monotonic_time(millisecond),
        {Path, Meta} = solve(Task),
        Receipt = must(ecai_math_pathfinder:verify_path(Path)),
        Verified = Path#{verification => Receipt},
        Bin = must(ecai_math_codec:encode(Verified)),
        need(byte_size(Bin) =< ?MAX_BYTES, result_size_limit),
        {ok, #{path_json => Bin, path => json:decode(Bin),
               artifact_sha256 => sha(Bin),
               elapsed_ms => erlang:monotonic_time(millisecond) - Start,
               checked_at_ms => erlang:system_time(millisecond),
               evidence => #{native_replay => passed, formal_proof => false,
                   independent_check => not_attached, damagebdd_run => not_attached,
                   hashes => native_path_identity_checked,
                   provenance => not_authenticated},
               metadata => Meta}}
    catch error:Reason -> {error, Reason} end.

solve(#{operation := demo}) ->
    {must(ecai_math_pathfinder:demo()), #{mode => explicit_demo,
        note => <<"Restricted degree-2 graph. Not a minimum-degree claim; endpoints also have a scaling isomorphism.">>}};
solve(#{operation := discover, source := S, target := T, bounds := B}) ->
    {must(ecai_math_pathfinder:solve_two(S, T, B)), #{mode => bounded_discovery,
        generation_bounds => B,
        note => <<"Search cost is an edge-weight sum, not currency. No complete exploration trace is recorded.">>}};
solve(#{operation := Op, path_json := Bin}) when Op =:= import; Op =:= replay ->
    %% Reject graphs before entering the graph decoder: this endpoint checks
    %% paths only, and cannot be used to load a large candidate graph.
    W = json:decode(Bin),
    need(is_map(W) andalso maps:get(<<"kind">>, W, undefined) =:= <<"mathematical_path">>,
         mathematical_path_required),
    Steps = maps:get(<<"steps">>, W, undefined),
    need(is_list(Steps) andalso length(Steps) =< 16, dashboard_hop_limit),
    P = must(ecai_math_codec:decode(Bin)),
    {P, #{mode => Op, input_sha256 => sha(Bin),
        note => <<"Submitted verification flags and search metadata were discarded. Algebra and native path identity were checked afresh; source labels are not authenticated.">>}}.

sha(Bin) -> binary:encode_hex(crypto:hash(sha256, Bin)).
must({ok, V}) -> V;
must({error, R}) -> error(R).
need(true, _) -> ok;
need(false, R) -> error(R).
