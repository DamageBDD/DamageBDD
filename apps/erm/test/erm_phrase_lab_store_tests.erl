-module(erm_phrase_lab_store_tests).
-include_lib("eunit/include/eunit.hrl").

unvoiced_signed_zero_test_() ->
    [?_assertEqual(ok, erm_phrase_lab_store:validate_model(model(<<Bits:32>>)))
        || Bits <- [0, 16#80000000]].

voiced_pitch_bounds_test_() ->
    [?_assertEqual(Expected,
        erm_phrase_lab_store:validate_model(model(<<Pitch:32/float-big>>)))
        || {Pitch, Expected} <- [
            {50.0, ok},
            {400.0, ok},
            {49.0, {error, invalid_synthesis_model}},
            {401.0, {error, invalid_synthesis_model}},
            {-50.0, {error, invalid_synthesis_model}}
        ]].

model(PitchBytes) ->
    Frame = <<0.5:32/float-big, PitchBytes:4/binary, 0.5:32/float-big, 0:512>>,
    <<"ELS1", 400:32, 3:16, (binary:copy(Frame, 3))/binary>>.
