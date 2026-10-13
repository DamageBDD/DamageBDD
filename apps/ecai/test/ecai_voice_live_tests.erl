-module(ecai_voice_live_tests).
-include_lib("eunit/include/eunit.hrl").
options_test() ->
    O = #{profile => "voices.ecv", session => "_build/session"},
    ?assertMatch({ok, #{seconds := 6, backend := curve}}, ecai_voice_live:options(O)),
    ?assertMatch({error, _}, ecai_voice_live:options(O#{seconds => 60})),
    ?assertMatch({error, _}, ecai_voice_live:options(O#{backend => bogus})),
    ?assertMatch({error, _}, ecai_voice_live:options(O#{bad => true})),
    ?assertMatch({error, _}, ecai_voice_live:options(O#{profile => "bad\nname"})),
    ?assertMatch({error, _}, ecai_voice_live:options(garbage)).
