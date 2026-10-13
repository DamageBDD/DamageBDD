-module(erm_model_catalog_tests).

-include_lib("eunit/include/eunit.hrl").

native_voice_bundle_test() ->
    Catalog = erm_model_catalog:all(),
    #{files := Files} = maps:get(native_voice_base_en, Catalog),
    ?assertEqual(
        [speaker_model, vad_model, whisper_model],
        lists:sort([maps:get(role, F) || F <- Files])
    ),
    lists:foreach(
        fun(F) ->
            ?assert(lists:prefix("https://", maps:get(url, F))),
            ?assertEqual(64, length(maps:get(sha256, F))),
            ?assert(
                maps:is_key(bytes, F) orelse maps:is_key(max_bytes, F)
            )
        end,
        Files
    ).
