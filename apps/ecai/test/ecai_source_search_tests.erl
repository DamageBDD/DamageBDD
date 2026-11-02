%% Requires the same full ECAI/NIF environment as ecai_search_tests.
-module(ecai_source_search_tests).
-include_lib("eunit/include/eunit.hrl").

full_body_terms_removed_on_record_replacement_test() ->
    Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
    Text = <<"preview ",(binary:copy(<<"filler ">>,300))/binary," tailneedle">>,
    R = #{title => <<"Fixture">>,text => <<"preview">>,source_text => Text,
          source_sha256 => ecai_index_job_codec:id_hex(crypto:hash(sha256,Text)),
          source_bytes => byte_size(Text),source_complete => true,source_representation => <<"test">>},
    try
        ok = ecai_search:add_record(Ctx,<<"doc">>,R),
        ok = ecai_source_retrieval:index_text(Ctx,<<"doc">>,R),
        {Hits,[]} = ecai_search:search(Ctx,#{text => <<"tailneedle">>,prefix => false},5,#{include_proofs => false}),
        ?assertEqual(1,length(Hits)),
        {ok,Source} = ecai_search:source(Ctx,<<"doc">>),
        ?assertEqual(Text,maps:get(text,Source)),
        ok = ecai_search:upsert_record(Ctx,<<"doc">>,#{title => <<"Replacement">>,text => <<"replacement">>}),
        ?assertEqual({[],[]},ecai_search:search(Ctx,#{text => <<"tailneedle">>,prefix => false},5,#{include_proofs => false}))
    after ecai_search:wipe(Ctx) end.
