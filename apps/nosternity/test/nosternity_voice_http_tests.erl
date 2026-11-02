-module(nosternity_voice_http_tests).
-include_lib("eunit/include/eunit.hrl").
voice_http_test_() -> {timeout,60,fun roundtrip/0}.

roundtrip() ->
    {ok,_}=application:ensure_all_started(cowboy),{ok,_}=application:ensure_all_started(gun),
    Auth=nosternity_auth_tests:setup(),Old=application:get_env(ecai,voice_notes),
    OldOrigin=application:get_env(nosternity,browser_auth_origin),T=ets:new(voice_fixture,[public,set]),
    Provider=make_ref(),Listener=make_ref(),
    {ok,_}=cowboy:start_clear(Provider,#{socket_opts=>[{ip,{127,0,0,1}},{port,0}]},
        #{env=>#{dispatch=>cowboy_router:compile([{'_',[{'_',nosternity_voice_provider_fixture,#{table=>T}}]}])}}),
    PP=ranch:get_port(Provider),
    C=#{enabled=>true,whisper_port=>PP,ollama_port=>PP,cleanup_enabled=>true,ollama_model=><<"fixture-model">>},
    application:set_env(ecai,voice_notes,C),
    {ok,_}=cowboy:start_clear(Listener,#{socket_opts=>[{ip,{127,0,0,1}},{port,0}]},
        #{env=>#{dispatch=>trails:single_host_compile(nosternity_voice_http:trails())}}),
    P=ranch:get_port(Listener),Origin=list_to_binary("http://127.0.0.1:"++integer_to_list(P)),
    application:set_env(nosternity,browser_auth_origin,Origin),
    try
        %% A real Nostr proof produces the session; no auth bypass or test adapter.
        Binding=binary:copy(<<"b">>,64),
        {ok,Challenge}=nosternity_auth:challenge(nostr,<<"signup">>,Origin,Binding,voice_test),
        {ok,Token,_}=nosternity_auth:verify_nostr(maps:get(challenge_id,Challenge),
            nosternity_auth_tests:sign(maps:get(event,Challenge),31),maps:get(payload,Challenge),Origin,Binding),
        Headers=[{<<"origin">>,Origin},{<<"x-nosternity-auth">>,<<"1">>},{<<"content-type">>,<<"audio/wav">>}],
        H=Headers++[{<<"cookie">>,<<"nosternity_session=",Token/binary>>}],
        W=ecai_voice_notes_tests:wav(),Path="/api/nosternity/voice/transcribe",
        {401,_,_}=request(P,<<"POST">>,Path,Headers,<<"bad input">>),
        Evil=lists:keyreplace(<<"origin">>,1,H,{<<"origin">>,<<"https://wrong.example">>}),
        {403,_,_}=request(P,<<"POST">>,Path,Evil,W),
        {405,_,_}=request(P,<<"GET">>,Path,H,<<>>),
        {200,_,Opt}=request(P,<<"GET">>,"/api/nosternity/voice/options",H,<<>>),
        ?assertEqual(false,maps:is_key(<<"whisper_host">>,json(Opt))),
        {200,RH,RB}=request(P,<<"POST">>,Path,H,W),
        ?assertEqual(<<"no-store">>,proplists:get_value(<<"cache-control">>,RH)),
        ?assertEqual(<<"hello voice world">>,maps:get(<<"raw_text">>,json(RB))),
        ?assertEqual(false,maps:get(<<"cleanup_applied">>,json(RB))),
        [{_,Parts}]=ets:lookup(T,<<"/inference">>),
        ?assertMatch({ok,_},ecai_voice_wav:decode(maps:get(<<"file">>,Parts))),
        ?assertEqual(<<"false">>,maps:get(<<"translate">>,Parts)),
        {200,_,Polished}=request(P,<<"POST">>,Path,H++[{<<"x-voice-cleanup">>,<<"1">>},{<<"x-voice-language">>,<<"ml">>}],W),
        ?assertEqual(<<"Hello, voice world.">>,maps:get(<<"text">>,json(Polished))),
        ?assertEqual(<<"hello voice world">>,maps:get(<<"raw_text">>,json(Polished))),
        [{_,Prompt}]=ets:lookup(T,<<"/api/generate">>),
        ?assertEqual(<<"fixture-model">>,maps:get(<<"model">>,Prompt)),
        ?assertEqual(false,maps:is_key(<<"tools">>,Prompt)),
        [{_,Parts2}]=ets:lookup(T,<<"/inference">>),?assertEqual(<<"ml">>,maps:get(<<"language">>,Parts2)),
        {415,_,_}=request(P,<<"POST">>,Path,lists:keyreplace(<<"content-type">>,1,H,{<<"content-type">>,<<"text/plain">>}),W),
        {413,_,_}=request(P,<<"POST">>,Path,H,binary:copy(<<0>>,2097153)),
        {422,_,_}=request(P,<<"POST">>,Path,H,<<"not a wav">>),
        ?assertEqual(413,chunked(P,Path,H)),
        ets:insert(T,{mode,error}),
        {503,_,Failed}=request(P,<<"POST">>,Path,H,W),
        ?assertEqual(nomatch,binary:match(Failed,<<"private-provider-error">>)),
        ets:insert(T,{mode,cleanup_error}),
        {200,_,Kept}=request(P,<<"POST">>,Path,H++[{<<"x-voice-cleanup">>,<<"1">>}],W),
        ?assertEqual(<<"hello voice world">>,maps:get(<<"text">>,json(Kept))),
        ?assertEqual(false,maps:get(<<"cleanup_applied">>,json(Kept))),
        ?assertEqual(<<"cleanup_unavailable">>,maps:get(<<"warning">>,json(Kept))),
        %% Lock contention and revocation are exercised during real in-flight inference.
        ets:insert(T,[{mode,wait},{notify,self()}]),Parent=self(),
        spawn(fun()->Parent!{first,request(P,<<"POST">>,Path,H,W)} end),
        receive {provider_started,Worker}->
            {429,_,_}=request(P,<<"POST">>,Path,H,W),
            ok=nosternity_auth:revoke(Token),Worker!proceed
        after 5000->error(provider_not_called) end,
        receive {first,{401,_,_}}->ok after 5000->error(revocation_not_enforced) end
    after cowboy:stop_listener(Listener),cowboy:stop_listener(Provider),ets:delete(T),
        nosternity_auth_tests:cleanup(Auth),restore(ecai,voice_notes,Old),restore(nosternity,browser_auth_origin,OldOrigin)
    end.

request(P,Method,Path,H,B) ->
    {ok,C}=gun:open("127.0.0.1",P,#{protocols=>[http]}),{ok,http}=gun:await_up(C),
    try Ref=gun:request(C,Method,Path,H,B),
        case gun:await(C,Ref,10000) of
            {response,nofin,Code,Headers}->{ok,Body}=gun:await_body(C,Ref,10000),{Code,Headers,Body};
            {response,fin,Code,Headers}->{Code,Headers,<<>>}
        end
    after gun:close(C) end.
chunked(P,Path,H) ->
    {ok,C}=gun:open("127.0.0.1",P,#{protocols=>[http]}),{ok,http}=gun:await_up(C),
    try Ref=gun:headers(C,<<"POST">>,Path,H),
        [gun:data(C,Ref,nofin,binary:copy(<<0>>,65536)) || _<-lists:seq(1,32)],
        gun:data(C,Ref,fin,<<0>>),{response,_,Code,_}=gun:await(C,Ref,10000),Code
    after gun:close(C) end.
json(B)->jsx:decode(B,[return_maps]).
restore(App,Key,undefined)->application:unset_env(App,Key);
restore(App,Key,{ok,V})->application:set_env(App,Key,V).
