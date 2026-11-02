-module(erm_dj_service_tests).
-include_lib("eunit/include/eunit.hrl").
lifecycle_test()->
 D=tmp(), {ok,_}=erm_dj:start_link(#{data_dir=>D}),
 try
  ?assertMatch(#{releases:=0,tracks:=0,busy:=false},erm_dj:status()),
  P=(ecai_dj_package:default())#{preferred_tags=>[<<"ambient">>],policy_license=><<"CC-BY-4.0">>},
  ok=erm_dj:set_policy(P),{ok,B}=erm_dj:export_policy(),ok=erm_dj:import_policy(B),
  ?assertMatch({error,_},erm_dj:import_policy(<<"{}">>)),
  ?assertMatch({error,_},erm_dj:fetch(<<"https://127.0.0.1/private">>)),
  Parent=self(),spawn(fun()->Parent!{discovery,erm_dj:discover()} end),
  wait_busy(50),
  ?assertMatch(#{busy:=true},erm_dj:status()),
  ?assertEqual({error,busy},erm_dj:fetch(<<"https://ektoplazm.com/free-music/fixture">>)),
  receive {discovery,{ok,[_]}}->ok after 2000->error(no_discovery) end,
  {ok,R}=erm_dj:fetch(<<"https://ektoplazm.com/free-music/fixture">>),
  ?assertEqual({error,no_archive_download},erm_dj:cache_release(maps:get(id,R))),
  ?assertMatch({error,{worker_down,killed}},erm_dj:fetch(<<"https://ektoplazm.com/free-music/crash">>)),
  ?assertMatch(#{busy:=false,releases:=1},erm_dj:status()),
  ok=erm_dj:stop(),{ok,_}=erm_dj:start_link(#{data_dir=>D}),
  ?assertMatch({ok,[_]},erm_dj:releases()),?assertEqual({ok,B},erm_dj:export_policy())
 after erm_dj:stop(),file:del_dir_r(D) end.

cached_playback_rating_restart_test()->
 D=tmp(),ok=filelib:ensure_dir(filename:join(D,"placeholder")),
 URL = <<"https://ektoplazm.com/free-music/fixture">>,
 {ok,R}=erm_dj_ektoplazm:fetch_release(URL),
 PCM=crypto:strong_rand_bytes(800),Size=byte_size(PCM),
 WAV = <<"RIFF",(36+Size):32/little,"WAVEfmt ",16:32/little,1:16/little,1:16/little,
       8000:32/little,16000:32/little,2:16/little,16:16/little,"data",Size:32/little,PCM/binary>>,
 {ok,{_,ZIP}}=zip:create("fixture.zip",[{"track.wav",WAV}],[memory,{compress,[]}]),
 {ok,[T]}=erm_dj_media:prepare_archive(R,ZIP,filename:join(D,"audio"),#{}),
 Id=maps:get(id,T),State=#{releases=>#{maps:get(id,R)=>R},tracks=>#{Id=>T},feedback=>#{},recent=>[],policy=>undefined},
 ok=file:write_file(filename:join(D,"catalogue.term"),term_to_binary({ecdj_state,1,State})),
 {ok,_}=erm_dj:start_link(#{data_dir=>D}),register(playlist,self()),
 try
  {ok,[Ranked]}=erm_dj:recommend(#{mood=><<"ambient">>},5),
  ?assertEqual(Id,maps:get(id,Ranked)),
  ?assertMatch({ok,_},erm_dj:play(Id)),
  receive {added,[_]}->ok after 500->error(no_playlist_add) end,
  receive {mpv,load_cached_audio,[_Path,_Format]}->ok after 500->error(no_mpv_command) end,
  ok=erm_dj:rate(Id,2),ok=erm_dj:stop(),{ok,_}=erm_dj:start_link(#{data_dir=>D}),
  {ok,[After]}=erm_dj:recommend(#{},1),
  Parts=maps:get(components,maps:get(reasons,After)),
  ?assert(maps:get(rating,Parts)>0),?assert(maps:get(repetition,Parts)<0),
  ?assertEqual({error,bad_request},erm_dj:rate(Id,100)),
  ok=file:write_file(maps:get(local_path,T),<<"tampered">>),
  ?assertMatch({error,_},erm_dj:play(Id))
 after unregister(playlist),erm_dj:stop(),file:del_dir_r(D) end.

invalid_persisted_state_test()->
 D=tmp(),ok=filelib:ensure_dir(filename:join(D,"placeholder")),
 State=#{releases=>#{},tracks=>#{},feedback=>#{},recent=>[],policy=>undefined,extra=>true},
 ok=file:write_file(filename:join(D,"catalogue.term"),term_to_binary({ecdj_state,1,State})),
 process_flag(trap_exit,true),
 ?assertMatch({error,{catalogue_load_failed,invalid_state}},erm_dj:start_link(#{data_dir=>D})),
 receive {'EXIT',_,_}->ok after 100->ok end,
 file:del_dir_r(D).

tmp()->filename:join("/tmp","ecdj-service-"++integer_to_list(erlang:unique_integer([positive]))).
wait_busy(0)->error(not_busy);
wait_busy(N)->case erm_dj:status() of #{busy:=true}->ok;_->timer:sleep(5),wait_busy(N-1) end.

supervised_start_stop_and_session_gate_test()->
 D=tmp(),{ok,Sup}=erm_sup:start_link(),
 try
  application:set_env(erm,dj,#{data_dir=>D}),
  application:set_env(erm,display_manager,[{mode,greeter}]),
  ?assertEqual({error,not_a_user_session},erm_dj:start()),
  application:set_env(erm,display_manager,#{mode=>disabled}),
  {ok,Pid}=erm_dj:start(),?assert(is_process_alive(Pid)),
  ok=erm_dj:stop(),?assertEqual(undefined,whereis(erm_dj)),
  ?assertEqual([],supervisor:which_children(erm_sup)),
  {ok,_}=erm_dj:start(),ok=erm_dj:stop()
 after
  unlink(Sup),exit(Sup,shutdown),application:unset_env(erm,dj),
  application:unset_env(erm,display_manager),file:del_dir_r(D)
 end.
