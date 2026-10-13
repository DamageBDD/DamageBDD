-module(ecai_voice_curve_tests).
-include_lib("eunit/include/eunit.hrl").

bounded_metric_test_() ->
    {timeout, 120, fun() ->
        C = ecai_voice_curve:new(),
        %% Exhaustive small grid plus full-bound endpoints.
        lists:foreach(
            fun({A, B}) ->
                {ok, PA} = ecai_voice_curve:encode([A], C),
                {ok, PB} = ecai_voice_curve:encode([B], C),
                ?assertEqual({ok, abs(A - B)}, ecai_voice_curve:distance(PA, PB, C))
            end,
            [{A, B} || A <- lists:seq(-16, 16), B <- lists:seq(-16, 16)] ++
                [{-255, 255}, {255, -255}, {0, 0}, {-255, -255}]
        ),
        A = [-255, -17, 0, 1, 255],
        B = [255, 17, 1, 0, -255],
        {ok, PA} = ecai_voice_curve:encode(A, C),
        {ok, PB} = ecai_voice_curve:encode(B, C),
        ?assertEqual(ecai_voice_curve:integer_distance(A, B), ecai_voice_curve:distance(PA, PB, C)),
        ?assertEqual({error, invalid_quantized_vector}, ecai_voice_curve:encode([256], C)),
        ?assertEqual({error, invalid_quantized_vector}, ecai_voice_curve:encode([1.0], C)),
        ?assertEqual({error, invalid_quantized_vector}, ecai_voice_curve:encode([], C)),
        ?assertEqual(
            {error, invalid_quantized_vectors}, ecai_voice_curve:integer_distance([0], [0, 0])
        ),
        ?assertEqual({error, invalid_point_vectors}, ecai_voice_curve:distance([], [], C)),
        ?assertEqual(
            {error, point_outside_bounded_encoding},
            ecai_voice_curve:distance([<<4, 0:512>>], [<<0>>], C)
        ),
        ?assertEqual(
            {error, point_outside_bounded_encoding},
            ecai_voice_curve:distance([<<2, 0:256>>], [<<0>>], C)
        )
    end}.

openssl_reference_points_test() ->
    C = ecai_voice_curve:new(),
    {ok, [G, G2, G17, G255]} = ecai_voice_curve:encode([1, 2, 17, 255], C),
    ?assertEqual(
        binary:decode_hex(<<"0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798">>),
        G
    ),
    ?assertEqual(
        binary:decode_hex(<<"02C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5">>),
        G2
    ),
    ?assertEqual(
        binary:decode_hex(<<"03DEFDEA4CDB677750A420FEE807EACF21EB9898AE79B9768766E4FAA04A2D4A34">>),
        G17
    ),
    ?assertEqual(
        binary:decode_hex(<<"031B38903A43F7F114ED4500B4EAC7083FDEFECE1CF29C63528D563446F972C180">>),
        G255
    ),
    {ok, [NegG]} = ecai_voice_curve:encode([-1], C),
    <<2, GX/binary>> = G,
    ?assertEqual(<<3, GX/binary>>, NegG).
