%% Optional, native Piper speech. One bounded response at a time, no stale queue.
-module(erm_tts).
-behaviour(gen_server).
-export([start_link/1, child_specs/0, say/1, notify/2, cancel/0, status/0,
         suppressed/0, response/2, response/3, chunks/1, diagnostics/0,
         voices/0, set_voice/1, reload/0, reload/1, set_volume/1, louder/0, quieter/0,
         repeat/0, repeat/1, personality/0, set_personality/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st,{opts,port=undefined,ready=false,parts=[],busy=false,timer=undefined,
            retry=undefined,error=undefined,resolved=undefined,last_response=undefined,current=undefined,speech_volume=120}).
start_link(Opts) -> gen_server:start_link({local,?MODULE},?MODULE,Opts,[]).
child_specs() ->
    Opts = config(application:get_env(erm,tts,[])),
    case maps:get(enabled,Opts,true) of
        true -> [erm_model_pull:child_spec(), #{id=>?MODULE,start=>{?MODULE,start_link,[Opts]},restart=>permanent,
                   shutdown=>5000,type=>worker,modules=>[?MODULE]}];
        _ -> []
    end.
say(Text) -> call({say,Text}).
voices() ->
    case erm_model_pull:models() of
        Ids when is_list(Ids) -> Ids;
        _ -> lists:sort(maps:keys(erm_model_catalog:all()))
    end.
set_voice(Id) -> call({set_voice,Id}).
reload() -> reload([]).
reload(Options) -> call({reload,Options}).
set_volume(N) -> call({set_volume,N}).
louder() -> call({adjust_volume,louder}).
quieter() -> call({adjust_volume,quieter}).
repeat() -> repeat(same).
repeat(Direction) -> call({repeat,Direction}).
personality() -> call(personality).
set_personality(P) -> call({set_personality,P}).
cancel() -> call(cancel).
status() -> call(status).
diagnostics() -> call(diagnostics).
call(Request) ->
    try gen_server:call(?MODULE,Request,1000)
    catch exit:{noproc,_} -> {error,disabled}; exit:{timeout,_} -> {error,timeout} end.
notify(Result,Command) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N<10 -> gen_server:cast(Pid,{notify,Result,Command});
            _ -> ok
        end
    end.
suppressed() -> now_ms() < persistent_term:get({?MODULE,suppress_until},now_ms()).
response(Result,Command) -> response(Result,Command,plain).
response({ok,#{tts:=_}},_,_) -> undefined;
response({ok,#{action:=answer,text:=Text}},_,_) -> Text;
response({ok,#{playing:=Title}},_,playful) -> ["Playing ",Title,". Excellent choice. No pressure."];
response({ok,#{playing:=Title}},_,_) -> ["Playing ",Title];
response(ok,Command,Personality) ->
    try erm_voice_intent:parse(Command) of
        {ok,#{action:=tts}} -> undefined;
        {ok,#{action:=Action}} -> acknowledgement(Action,Personality);
        _ -> acknowledgement(done,Personality)
    catch _:_ -> acknowledgement(done,Personality) end;
response({error,busy},_,_) -> undefined;
response({error,cancelled},_,_) -> undefined;
response({error,nothing_to_repeat},_,_) -> "I haven't finished a response to repeat yet.";
response({error,_},_,playful) -> "That didn't work. Rude.";
response({error,_},_,_) -> "I couldn't complete that request.";
response(_,_,_) -> undefined.
acknowledgement(pause,playful) -> "Paused. Take your time.";
acknowledgement(stop,playful) -> "Stopped. Peace at last.";
acknowledgement(play,playful) -> "Playing. Let's improve the atmosphere.";
acknowledgement(next,playful) -> "Next track. Redemption is possible.";
acknowledgement(previous,playful) -> "Previous track. A little nostalgia.";
acknowledgement(pause,_) -> "Paused.";
acknowledgement(stop,_) -> "Stopped.";
acknowledgement(play,_) -> "Playing.";
acknowledgement(next,_) -> "Next song.";
acknowledgement(previous,_) -> "Previous song.";
acknowledgement(_,_) -> "Done.".
config(M) when is_map(M) -> M;
config(L) when is_list(L) -> proplists:to_map(L);
config(_) -> #{}.
init(Options) ->
    logger:update_process_metadata(#{domain => [erm, tts]}),
    process_flag(trap_exit,true),
    case options(Options) of
        {ok,O} -> self()!connect,{ok,#st{opts=O}};
        {error,Reason} -> {stop,Reason}
    end.
options(Options) ->
    try
        true=is_map(Options) orelse is_list(Options),
        O=maps:merge(#{startup_timeout_ms=>30000,auto_pull=>true,voice=>lessac_low,
                      speech_timeout_ms=>30000,echo_guard_ms=>6000,personality=>plain,
                      volume=>120,volume_step=>10,volume_max=>150,model_source=>auto},config(Options)),
        true=is_boolean(maps:get(auto_pull,O)),
        true=lists:all(fun(K)-> V=maps:get(K,O),is_integer(V) andalso V>=0 andalso V=<120000 end,
                       [startup_timeout_ms,speech_timeout_ms,echo_guard_ms]),
        Max=maps:get(volume_max,O),Step=maps:get(volume_step,O),Vol=maps:get(volume,O),
        true=is_integer(Max) andalso Max>=100 andalso Max=<200,
        true=is_integer(Step) andalso Step>0 andalso Step=<100,
        true=is_integer(Vol) andalso Vol>=0 andalso Vol=<Max,
        true=lists:member(maps:get(personality,O),[plain,playful]),
        true=lists:member(maps:get(model_source,O),[auto,catalog]),
        {ok,case maps:get(model_source,O) of
            catalog -> maps:without([model,config],O);
            auto -> O
        end}
    catch _:_ -> {error,invalid_tts_configuration} end.
handle_call(diagnostics,_,S) ->
    O=case S#st.resolved of undefined->S#st.opts;R->R end,
    {reply,(erm_tts_paths:resolve(O))#{model_pull=>erm_model_pull:status()},S};
handle_call(status,_,S) ->
    {reply,#{ready=>S#st.ready,speaking=>S#st.busy,listening_suppressed=>suppressed(),
             last_error=>S#st.error,voice=>maps:get(voice,S#st.opts),
             model_source=>maps:get(model_source,S#st.opts),personality=>maps:get(personality,S#st.opts),
             volume=>maps:get(volume,S#st.opts),volume_max=>maps:get(volume_max,S#st.opts),
             has_last_response=>S#st.last_response=/=undefined},S};
handle_call(personality,_,S) -> {reply,maps:get(personality,S#st.opts),S};
handle_call({set_personality,P},_,S) when P=:=plain;P=:=playful ->
    {reply,ok,S#st{opts=(S#st.opts)#{personality=>P}}};
handle_call({set_personality,_},_,S) -> {reply,{error,invalid_personality},S};
handle_call({set_volume,V},_,S) ->
    case valid_volume(V,S) of
        true -> {reply,ok,S#st{opts=(S#st.opts)#{volume=>V}}};
        false -> {reply,{error,tts_volume_out_of_range},S}
    end;
handle_call({adjust_volume,Direction},_,S) when Direction=:=louder;Direction=:=quieter ->
    {reply,ok,S#st{opts=(S#st.opts)#{volume=>adjusted(Direction,S)}}};
handle_call({repeat,Direction},_,S) ->
    {Reply,Next}=repeat_response(Direction,S),{reply,Reply,Next};
handle_call({set_voice,Id},_,S) ->
    case resolve_voice(Id) of
        {ok,Voice} -> {reply,ok,reconnect(S#st{opts=catalog_options(Voice,S#st.opts)})};
        Error -> {reply,Error,S}
    end;
handle_call({reload,Overrides},_,S) ->
    case reload_options(Overrides,S#st.opts) of
        {ok,O} -> {reply,ok,reconnect(S#st{opts=O})};
        Error -> {reply,Error,S}
    end;
handle_call(cancel,_,S=#st{busy=true}) -> {reply,ok,disconnect(cancelled,S)};
handle_call(cancel,_,S) -> {reply,ok,S};
handle_call({say,Text},_,S) -> {Reply,Next}=enqueue(Text,S),{reply,Reply,Next};
handle_call(_,_,S) -> {reply,{error,unsupported_call},S}.
handle_cast({notify,Result,Command},S) ->
    case response(Result,Command,maps:get(personality,S#st.opts)) of
        undefined -> {noreply,S};
        Text -> {_,Next}=enqueue(Text,S),{noreply,Next}
    end;
handle_cast({say,Text},S) -> {_,Next}=enqueue(Text,S),{noreply,Next};
handle_cast(_,S) -> {noreply,S}.
handle_info(connect,S=#st{port=undefined,opts=O}) ->
    cancel_retry(S#st.retry),
    S0=S#st{retry=undefined},
    case model_options(O) of
        {ok,Resolved}->connect_resolved(Resolved,S0);
        {pending,Progress}->{noreply,retry(S0#st{error={model_pull,Progress}})};
        {error,Reason}->{noreply,startup_failed({model_pull,Reason},S0)}
    end;

handle_info({P,{data,<<"R">>}},S=#st{port=P,ready=false}) ->
    logger:notice("tts ready voice=~p volume=~p personality=~p",[maps:get(voice,S#st.opts),maps:get(volume,S#st.opts),maps:get(personality,S#st.opts)]),
    {noreply,clear_timer(S#st{ready=true,error=undefined})};
handle_info({P,{data,<<"D">>}},S=#st{port=P,busy=true,parts=[]}) ->
    gate(tail(S),S),{noreply,clear_timer(S#st{busy=false,last_response=S#st.current,current=undefined})};
handle_info({P,{data,<<"D">>}},S=#st{port=P,busy=true,parts=[Next|Rest]}) ->
    {noreply,send(Next,S#st{parts=Rest})};
handle_info({P,{data,<<"E",Reason/binary>>}},S=#st{port=P}) ->
    {noreply,disconnect({native,Reason},S)};
handle_info({P,{exit_status,Code}},S=#st{port=P}) -> {noreply,disconnect({exit_status,Code},S)};
handle_info({'EXIT',P,Reason},S=#st{port=P}) -> {noreply,disconnect({port_exit,Reason},S)};
handle_info({timeout,Ref,tts},S=#st{timer=Ref}) -> {noreply,disconnect(timeout,S)};
handle_info(_,S) -> {noreply,S}.
enqueue(_,S=#st{ready=false}) -> {{error,not_ready},S};
enqueue(_,S=#st{busy=true}) -> {{error,busy},S};
enqueue(Text,S) ->
    case chunks(Text) of
        {ok,[First|Rest]=Parts} ->
            Next=send(First,S#st{parts=Rest,busy=true,current=iolist_to_binary(lists:join(<<" ">>,Parts)),
                                  speech_volume=maps:get(volume,S#st.opts)}),
            case Next#st.ready of true->{ok,Next};false->{{error,Next#st.error},Next} end;
        Error -> {Error,S}
    end.
send(Text,S=#st{port=P,opts=O}) ->
    logger:debug("tts speaking chunk volume=~p voice=~p: ~tp", [S#st.speech_volume,maps:get(voice,O),Text]),
    Timeout=maps:get(speech_timeout_ms,O),gate(Timeout+tail(S)+1000,S),
    try true=port_command(P,<<"V",(integer_to_binary(S#st.speech_volume))/binary,"\n",Text/binary>>),arm(Timeout,S)
    catch _:_ -> disconnect(port_closed,S) end.
chunks(Text) ->
    try
        Chars=unicode:characters_to_list(Text),true=is_list(Chars),
        true=length(Chars)>0 andalso length(Chars)=<1200,
        false=lists:member(0,Chars),
        Words=string:lexemes(Chars," \t\r\n"),true=Words=/=[],
        Parts=split_words(Words,[],[],0),
        {ok,[unicode:characters_to_binary(P)||P<-Parts]}
    catch _:_ -> {error,invalid_or_too_long_text} end.
split_words([],[],Acc,_) -> lists:reverse(Acc);
split_words([],Cur,Acc,_) -> lists:reverse([string:join(lists:reverse(Cur)," ")|Acc]);
split_words([W|Rest],Cur,Acc,N) when N+length(W)+1>240,Cur=/=[] ->
    split_words([W|Rest],[],[string:join(lists:reverse(Cur)," ")|Acc],0);
split_words([W|Rest],Cur,Acc,N) when length(W)=<240 -> split_words(Rest,[W|Cur],Acc,N+length(W)+1);
split_words(_,_,_,_) -> error(word_too_long).
arm(Ms,S) -> C=clear_timer(S),C#st{timer=erlang:start_timer(Ms,self(),tts)}.
clear_timer(S=#st{timer=undefined}) -> S;
clear_timer(S=#st{timer=T}) -> erlang:cancel_timer(T),S#st{timer=undefined}.
startup_failed(Reason,S) ->
    case Reason=:=S#st.error of
        true->ok;
        false->logger:warning("tts backend unavailable: ~tp",[Reason])
    end,
    retry(S#st{error=Reason}).
cancel_retry(undefined)->ok;
cancel_retry(T)->erlang:cancel_timer(T),ok.
retry(S=#st{retry=undefined}) -> S#st{retry=erlang:send_after(5000,self(),connect)};
retry(S) -> S.
disconnect(Reason,S) ->
    logger:debug("tts backend disconnected: ~tp", [Reason]),
    case S#st.busy of true -> gate(tail(S),S);false -> ok end,
    close(S#st.port),retry(clear_timer(S#st{port=undefined,ready=false,busy=false,parts=[],current=undefined,error=Reason})).
close(undefined) -> ok;
close(P) ->
    try port_close(P) of
        _ -> ok
    catch
        _:_ -> ok
    end.
tail(#st{opts=O}) ->
    W=config(application:get_env(erm,whisper_trigger,[])),
    Roll=lists:sum([positive(maps:get(K,W,D),D)||{K,D}<-[{length_ms,5000},{keep_ms,200},{step_ms,500}]]),
    max(maps:get(echo_guard_ms,O),Roll).
positive(N,_) when is_integer(N),N>0 -> N;
positive(_,D) -> D.
gate(Ms,_) ->
    persistent_term:put({?MODULE,suppress_until},now_ms()+Ms),
    %% Only clear microphone context; do not cancel another command's planning.
    gen_server:cast(erm_voice,reset_boundary),ok.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    cancel_retry(S#st.retry),
    case S#st.busy of true -> gate(tail(S),S);false -> ok end,
    close(S#st.port),ok.
code_change(_,S,_) -> {ok,S}.

connect_resolved(O,S0)->
    case erm_tts_paths:resolve(O) of
        #{paths:=Paths,errors:=Errors} when map_size(Errors)=:=0 ->
            #{binary:=Bin,model:=Model,config:=Config,espeak_data:=Data,player:=Player}=Paths,
            try
                P=open_port({spawn_executable,Bin},[binary,{packet,4},use_stdio,exit_status,
                              {args,[Model,Config,Data,Player]}]),
                {noreply,arm(maps:get(startup_timeout_ms,O),S0#st{port=P,resolved=O})}
            catch C:R -> {noreply,startup_failed({backend_start_failed,#{class=>C,reason=>R,binary=>Bin}},S0)} end;
        #{errors:=Errors} -> {noreply,startup_failed({backend_configuration,Errors},S0)}
    end.
model_options(O)->
    case maps:get(model_source,O,auto)=/=catalog andalso
         (maps:is_key(model,O) orelse os:getenv("PIPER_MODEL")=/=false andalso os:getenv("PIPER_MODEL")=/="") of
        true->{ok,O};
        false->case maps:get(auto_pull,O,true) of
            false->{ok,O};
            true->case erm_model_pull:ensure(maps:get(voice,O,lessac_low)) of
                {ok,#{model:=Model,config:=Config}}->
                    %% An explicit JSON override retains precedence.
                    {ok,maps:merge(#{model=>Model,config=>Config},O)};
                {ok,_}->{error,manifest_missing_model_or_config};
                Other->Other
            end
        end
    end.

%% Runtime settings live in this process. Persist chosen defaults in sys.config.
valid_volume(V,#st{opts=O})->is_integer(V) andalso V>=0 andalso V=<maps:get(volume_max,O).
adjusted(same,#st{opts=O})->maps:get(volume,O);
adjusted(Direction,#st{opts=O})->
    Sign=case Direction of louder->1;quieter->-1 end,
    max(0,min(maps:get(volume_max,O),maps:get(volume,O)+Sign*maps:get(volume_step,O))).
repeat_response(Direction,S) when Direction=/=same,Direction=/=louder,Direction=/=quieter ->
    {{error,invalid_repeat_direction},S};
repeat_response(_,S=#st{ready=false})->{{error,not_ready},S};
repeat_response(_,S=#st{busy=true})->{{error,busy},S};
repeat_response(_,S=#st{last_response=undefined})->{{error,nothing_to_repeat},S};
repeat_response(Direction,S)->
    Next=S#st{opts=(S#st.opts)#{volume=>adjusted(Direction,S)}},
    case enqueue(S#st.last_response,Next) of
        {ok,Started}->{ok,Started};
        {Error,Failed}->{Error,Failed#st{opts=S#st.opts}}
    end.
reconnect(S)->
    %% Closing the worker also stops its active player; retain only the last
    %% fully completed response. Stale port messages are ignored by identity.
    cancel_retry(S#st.retry),
    case S#st.busy of true->gate(tail(S),S);false->ok end,
    close(S#st.port),self()!connect,
    clear_timer(S#st{port=undefined,ready=false,busy=false,parts=[],current=undefined,
                    retry=undefined,error=undefined,resolved=undefined}).
catalog_options(Voice,O)->(maps:without([model,config],O))#{voice=>Voice,model_source=>catalog,auto_pull=>true}.
resolve_voice(Id)->
    try
        Name=voice_name(case is_atom(Id) of true->atom_to_binary(Id,utf8);false->Id end),
        Alias=case Name of
            <<"amy">>-><<"amy medium">>;<<"cori">>-><<"cori medium">>;
            <<"alba">>-><<"alba medium">>;<<"lessac">>-><<"lessac low">>;
            <<"ljspeech">>-><<"ljspeech high">>;_->Name
        end,
        Matches=[V||V<-voices(),is_atom(V),voice_name(atom_to_binary(V,utf8))=:=Alias],
        case Matches of [V]->{ok,V};_->{error,unknown_voice} end
    catch _:_ -> {error,unknown_voice} end.
voice_name(Text)->binary:replace(erm_voice_boundary:normalize(Text),<<"_">>,<<" ">>,[global]).
reload_options(Overrides,O)->
    try
        true=is_map(Overrides) orelse is_list(Overrides),
        M=config(Overrides),Merged=maps:merge(O,M),
        Candidate=case {maps:find(voice,M),maps:is_key(model,M)} of
            {{ok,Id},false}->case resolve_voice(Id) of
                {ok,Voice}->catalog_options(Voice,Merged);
                _->throw(unknown_voice)
            end;
            {_,true}->Merged#{model_source=>maps:get(model_source,M,auto)};
            _->Merged
        end,
        options(Candidate)
    catch throw:unknown_voice->{error,unknown_voice};_:_->{error,invalid_tts_configuration} end.
