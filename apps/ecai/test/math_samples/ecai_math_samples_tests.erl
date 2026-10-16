%% Native fixture gate. Every candidate ID is checked by the actual codec.
-module(ecai_math_samples_tests).
-include_lib("eunit/include/eunit.hrl").

samples_test_() ->
    {ok,_} = application:ensure_all_started(crypto),
    Dir = case os:getenv("ECAI_MATH_SAMPLES_DIR") of
        false -> filename:absname(filename:join([filename:dirname(?FILE),"..","..","priv","static","math-samples"]));
        Configured -> Configured
    end,
    {ok,CatalogBin} = file:read_file(filename:join(Dir,"catalog.json")),
    #{<<"samples">> := Samples} = json:decode(CatalogBin),
    [{binary_to_list(maps:get(<<"id">>,S)),
      {timeout,30,fun() -> check_sample(Dir,S) end}} || S <- Samples].

check_sample(Dir,S) ->
    {ok,Bin} = file:read_file(filename:join(Dir,binary_to_list(maps:get(<<"file">>,S)))),
    case maps:get(<<"expected">>,S) of
        <<"reject">> -> ?assertMatch({error,_},ecai_math_codec:decode(Bin));
        <<"accept">> ->
            {ok,P} = ecai_math_codec:decode(Bin),
            {ok,Receipt} = ecai_math_pathfinder:verify_path(P),
            ?assertEqual(verified,maps:get(status,Receipt)),
            ?assertEqual(false,maps:get(formal_proof,Receipt)),
            ?assertEqual(maps:get(<<"id">>,maps:get(<<"path">>,S)),maps:get(id,P)),
            {ok,Encoded} = ecai_math_codec:encode(P),
            {ok,Reloaded} = ecai_math_codec:decode(Encoded),
            ?assertEqual(maps:get(id,P),maps:get(id,Reloaded)),
            Points = maps:get(<<"points">>,S),
            lists:foreach(fun(#{<<"x">>:=X,<<"y">>:=Y}) ->
                ?assertMatch({ok,_},ecai_math_pathfinder:apply_path(P,{rational(X),rational(Y)}))
            end,Points)
    end.
rational(Bin) ->
    case binary:split(Bin,<<"/">>) of
        [N] -> binary_to_integer(N);
        [N,D] -> {binary_to_integer(N),binary_to_integer(D)}
    end.
