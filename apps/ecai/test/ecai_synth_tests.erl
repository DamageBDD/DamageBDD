-module(ecai_synth_tests).

-include_lib("eunit/include/eunit.hrl").

maxwell_soundscape_smoke_test() ->
    Samples = ecai_synth:maxwell_soundscape(
        <<"ECAI Maxwell smoke test">>,
        0.004,
        1000
    ),
    ?assertEqual(4, length(Samples)),
    ?assert(lists:all(fun erlang:is_float/1, Samples)),
    ?assert(lists:all(fun(Sample) -> erlang:abs(Sample) =< 1.0 end, Samples)).

manual_demo_is_not_auto_discovered_test() ->
    {module, ecai_synth} = code:ensure_loaded(ecai_synth),
    ?assert(erlang:function_exported(ecai_synth, maxwell_demo, 0)),
    %% Rebar3 defines TEST for EUnit builds, so the production compatibility
    %% alias ending in _test must not be present in this beam.
    ?assertNot(erlang:function_exported(ecai_synth, maxwell_test, 0)).
