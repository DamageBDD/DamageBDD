-module(gtkgs_motion_tests).
-include_lib("eunit/include/eunit.hrl").

validation_test() ->
    ?assertEqual({error,invalid_motion},gtkgs_motion:stagger([unused],#{to=>#{x=>1},delay=>oops},10)),
    ?assertMatch({ok,[{200,0,spring,#{scale:=1}}]},
        gtkgs_motion:normalize([#{to=>#{scale=>1},duration=>200,easing=>spring}])),
    [?assertEqual({error,invalid_motion},gtkgs_motion:normalize(S)) || S<-
        [[],[#{to=>#{unknown=>1}}],[#{to=>#{opacity=>2}}],[#{to=>#{scale=>0}}],
         [#{to=>#{x=>0},duration=>-1}],[#{to=>#{x=>1},easing=>bogus}],
         lists:duplicate(65,#{to=>#{x=>1}})]].

reducer_test() ->
    E=fun(C,D)->#{channel=>C,data=>D,at=>1000} end,
    Input=E(input,#{phase=>listening,level=>0.6}),
    ?assertMatch(#{mood:=1,input:=0.6},erm_voice_widget:view([Input],1050)),
    ?assertMatch(#{mood:=0,input:=0.0},erm_voice_widget:view([Input],1500)),
    ?assertMatch(#{mood:=3,output:=0.8},erm_voice_widget:view(
        [Input,E(work,#{phase=>processing}),E(output,#{phase=>speaking,level=>0.8})],1050)),
    ?assertMatch(#{mood:=2},erm_voice_widget:view([E(work,#{phase=>processing})],1050)),
    ?assertMatch(#{mood:=4},erm_voice_widget:view([E(input,#{phase=>error})],1050)),
    ?assertEqual(0.0,erm_voice_widget:level(-120)),
    ?assertEqual(1.0,erm_voice_widget:level(0)).

bus_cleanup_test() ->
    {ok,_}=erm_voice_events:ensure_started(),
    {ok,_,_}=erm_voice_events:subscribe(),
    Parent=self(),
    P=spawn(fun()->erm_voice_events:publish(test_voice,input,#{phase=>listening,level=>0.5,
                                   embedding=>[1,2,3],pcm=><<1,2,3>>}),
                    Parent!published, receive stop->ok end end),
    receive published->ok after 1000->error(no_producer) end,
    receive {erm_voice_event,_,#{producer:=P,data:=D}} ->
        ?assertNot(maps:is_key(pcm,D)), ?assertNot(maps:is_key(embedding,D))
    after 1000->error(no_event) end,
    P!stop,
    receive {erm_voice_event,_,#{producer:=P,data:=#{phase:=stopped}}}->ok
    after 1000->error(no_cleanup) end,
    ?assertEqual([], [E || E=#{producer:=Producer}<-erm_voice_events:snapshot(),Producer=:=P]),
    ok=erm_voice_events:unsubscribe().

ecai_pcm_adapter_test() ->
    {ok,_}=erm_voice_events:ensure_started(),
    {ok,_,_}=erm_voice_events:subscribe(),
    {Path,Wav}=pcm_fixture(),
    ?assertEqual({ok,16000,1,44},ecai_voice_ui:wav_info(Wav)),
    Token=ecai_voice_ui:begin_audio(ecai_voice_session,"arecord",[Path]),
    ecai_voice_ui:tick(Token),
    Events=erm_voice_events:snapshot(),
    [#{data:=#{phase:=listening,level:=Level}}]=[E || E=#{source:=ecai_voice_session}<-Events],
    ?assert(abs(Level-0.7993)<0.001),
    ecai_voice_ui:end_audio(Token,ok),
    ?assertMatch([#{data:=#{phase:=idle,level:=0.0}}],
        [E || E=#{source:=ecai_voice_session}<-erm_voice_events:snapshot()]),
    Result=ecai_voice_ui:work(ecai_voice_session,fun()->#{speaker=><<"Steven">>} end),
    ?assertEqual(#{speaker=><<"Steven">>},Result),
    ok=erm_voice_events:unsubscribe().

pcm_fixture() ->
    Path=filename:join(os:getenv("MOTION_TEST_TMP"),"meter.wav"),
    PCM=binary:copy(<<8192:16/little-signed>>,16000),N=byte_size(PCM),
    Wav = <<"RIFF",(N+36):32/little,"WAVEfmt ",16:32/little,1:16/little,1:16/little,
          16000:32/little,32000:32/little,2:16/little,16:16/little,"data",N:32/little,PCM/binary>>,
    ok=file:write_file(Path,Wav), {Path,Wav}.

native_test_() -> {timeout,30,fun native/0}.
native() ->
    application:set_env(erm,log_to_file,false),
    {ok,Host}=inet:gethostname(),
    {ok,Sup}=gtknode4_sup:start_link(#{mode=>local_cnode,port=>#{cnode_node=>list_to_atom("gtknode4@"++Host),env=>[{"DISPLAY",os:getenv("DISPLAY")},
        {"XAUTHORITY",os:getenv("XAUTHORITY")} ]}}), unlink(Sup),
    try
        ok=gtknode4:await_ready(10000),
        Window=gtkgs:create(window,gtkgs:server(),[{width,360},{height,420}]),
        Stage=gtkgs:create(motion,Window,[]),
        ok=gtkgs_motion:seek(Stage,0),
        ?assertMatch({ok,#{scale:=1.0,opacity:=1.0}},gtkgs_motion:inspect(Stage)),
        _=gtkgs:create(button,Stage,[{label,"Motion test"}]),
        ok=gtkgs:config(Window,{show,true}),
        ok=gtkgs_motion:set(Stage,#{x=>0,opacity=>1}),
        {ok,_}=gtkgs_motion:sequence(Stage,[#{to=>#{x=>100},duration=>1000,easing=>linear},
                                          #{to=>#{x=>200},duration=>1000,easing=>linear}]),
        ok=gtkgs_motion:seek(Stage,500),
        ?assertMatch({ok,#{x:=50.0,paused:=true}},gtkgs_motion:inspect(Stage)),
        ok=gtkgs_motion:seek(Stage,1500),
        ?assertMatch({ok,#{x:=150.0}},gtkgs_motion:inspect(Stage)),
        Cursor=gtkgs:event_cursor(),
        {ok,Id}=gtkgs_motion:animate(Stage,#{x=>20},#{duration=>70}),
        ok=await_motion(Stage,Id,Cursor),
        ?assertMatch({ok,#{x:=20.0,active:=false}},gtkgs_motion:inspect(Stage)),
        {ok,_}=gtkgs_motion:animate(Stage,#{x=>0},#{duration=>5000,reduced_motion=>true}),
        ?assertMatch({ok,#{x:=0.0,active:=false}},gtkgs_motion:inspect(Stage)),
        {ok,_}=gtkgs_motion:animate(Stage,#{x=>100},#{duration=>5000}),
        ok=gtkgs_motion:pause(Stage),
        {ok,#{x:=Paused}}=gtkgs_motion:inspect(Stage),
        timer:sleep(70),
        ?assertMatch({ok,#{x:=Paused,paused:=true}},gtkgs_motion:inspect(Stage)),
        ok=gtkgs_motion:resume(Stage),
        ?assertMatch({ok,#{paused:=false,active:=true}},gtkgs_motion:inspect(Stage)),
        ok=gtkgs_motion:cancel(Stage),
        ?assertMatch({ok,#{active:=false}},gtkgs_motion:inspect(Stage)),
        ok=gtkgs_motion:classes(Stage,["erm_test","listening"]),
        ok=gtkgs_motion:remove_class(Stage,["listening"]),
        ok=gtkgs_motion:classes(Stage,[]),
        ok=gtkgs:destroy(Window),
        lists:foreach(fun(_)->
            Win=gtkgs:create(window,gtkgs:server(),[]),
            Child=gtkgs:create(motion,Win,[]),
            _=gtkgs:create(button,Child,[{label,"Destroy during animation"}]),
            ok=gtkgs:config(Win,{show,true}),
            {ok,_}=gtkgs_motion:animate(Child,#{x=>100},#{duration=>5000}),
            ok=gtkgs:destroy(Win)
        end,lists:seq(1,20)),
        widget(),
        ?assertMatch(#{ready:=true},gtknode4:status())
    after catch erm_voice_widget:stop(), exit(Sup,shutdown) end.
widget() ->
    {Path,_}=pcm_fixture(),
    {ok,_}=erm_voice_widget:start(#{sources=>[ecai_voice_session],show_text=>false}),
    Input=ecai_voice_ui:begin_audio(ecai_voice_session,"arecord",[Path]),
    ecai_voice_ui:tick(Input),
    wait_view(1,50),
    ?assertMatch(#{view:=#{input:=L}} when L>0.79,erm_voice_widget:status()),
    Output=ecai_voice_ui:begin_audio(ecai_voice_session,"aplay",[Path]),
    ecai_voice_ui:tick(Output),
    wait_view(3,50),
    ok=erm_voice_widget:hide(),ok=erm_voice_widget:show(),
    ?assertMatch(#{view:=#{output:=L}} when L>0.79,erm_voice_widget:status()),
    ecai_voice_ui:end_audio(Output,ok),
    ecai_voice_ui:end_audio(Input,ok),
    wait_view(0,50),
    ok=erm_voice_widget:stop().
wait_view(_,0) -> error(widget_not_updated);
wait_view(M,N) ->
    case erm_voice_widget:status() of
        #{view:=#{mood:=M}}->ok;
        _->timer:sleep(20),wait_view(M,N-1)
    end.

await_motion(Stage,Id,Cursor) ->
    case gtkgs:await_event(Stage,motion_finished,Cursor,2000) of
        {ok,#{payload:=#{animation_id:=Id,status:=completed}}}->ok;
        {ok,#{seq:=Next}}->await_motion(Stage,Id,Next);
        Error->error(Error)
    end.
