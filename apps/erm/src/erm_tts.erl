%% Optional, native Piper speech. One bounded response at a time, no stale queue.
-module(erm_tts).
-behaviour(gen_server).
-export([start_link/1, child_specs/0, say/1, notify/2, cancel/0, status/0,
         suppressed/0, response/2, chunks/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st,{opts,port=undefined,ready=false,parts=[],busy=false,timer=undefined,
            retry=undefined,error=undefined}).
start_link(Opts) -> gen_server:start_link({local,?MODULE},?MODULE,Opts,[]).
child_specs() ->
    Opts = config(application:get_env(erm,tts,[])),
    case maps:get(enabled,Opts,false) of
        true -> [#{id=>?MODULE,start=>{?MODULE,start_link,[Opts]},restart=>permanent,
                   shutdown=>5000,type=>worker,modules=>[?MODULE]}];
        _ -> []
    end.
say(Text) -> call({say,Text}).
cancel() -> call(cancel).
status() -> call(status).
call(Request) ->
    try gen_server:call(?MODULE,Request,1000)
    catch exit:{noproc,_} -> {error,disabled}; exit:{timeout,_} -> {error,timeout} end.
notify(Result,Command) ->
    case response(Result,Command) of
        undefined -> ok;
        Text -> case whereis(?MODULE) of
            undefined -> ok;
            Pid -> case process_info(Pid,message_queue_len) of
                {message_queue_len,N} when N<10 -> gen_server:cast(Pid,{say,Text});
                _ -> ok
            end
        end
    end.
suppressed() -> now_ms() < persistent_term:get({?MODULE,suppress_until},now_ms()).
response({ok,#{action:=answer,text:=Text}},_) -> Text;
response({ok,#{playing:=Title}},_) -> ["Playing ",Title];
response(ok,Command) ->
    case catch erm_voice_intent:parse(Command) of
        {ok,#{action:=pause}} -> "Paused.";
        {ok,#{action:=stop}} -> "Stopped.";
        {ok,#{action:=play}} -> "Playing.";
        {ok,#{action:=next}} -> "Next song.";
        {ok,#{action:=previous}} -> "Previous song.";
        _ -> "Done."
    end;
response({error,busy},_) -> undefined;
response({error,cancelled},_) -> undefined;
response({error,_},_) -> "I couldn't complete that request.";
response(_,_) -> undefined.
config(M) when is_map(M) -> M;
config(L) when is_list(L) -> proplists:to_map(L);
config(_) -> #{}.
init(Options) ->
    process_flag(trap_exit,true),
    O=maps:merge(#{startup_timeout_ms=>30000,speech_timeout_ms=>30000,echo_guard_ms=>6000},config(Options)),
    case lists:all(fun(K)-> V=maps:get(K,O),is_integer(V) andalso V>=0 andalso V=<120000 end,
                   [startup_timeout_ms,speech_timeout_ms,echo_guard_ms]) of
        true -> self()!connect,{ok,#st{opts=O}};
        false -> {stop,invalid_tts_configuration}
    end.
handle_call(status,_,S) ->
    {reply,#{ready=>S#st.ready,speaking=>S#st.busy,listening_suppressed=>suppressed(),
             last_error=>S#st.error},S};
handle_call(cancel,_,S=#st{busy=true}) -> {reply,ok,disconnect(cancelled,S)};
handle_call(cancel,_,S) -> {reply,ok,S};
handle_call({say,Text},_,S) -> {Reply,Next}=enqueue(Text,S),{reply,Reply,Next};
handle_call(_,_,S) -> {reply,{error,unsupported_call},S}.
handle_cast({say,Text},S) -> {_,Next}=enqueue(Text,S),{noreply,Next};
handle_cast(_,S) -> {noreply,S}.
handle_info(connect,S=#st{port=undefined,opts=O}) ->
    try
        Bin=path(binary,O),Model=path(model,O),Config=path(config,O),Data=path(espeak_data,O),Player=path(player,O),
        true=filelib:is_regular(Model),true=filelib:is_regular(Config),true=filelib:is_dir(Data),
        P=open_port({spawn_executable,Bin},[binary,{packet,4},use_stdio,exit_status,
                      {args,[Model,Config,Data,Player]}]),
        {noreply,arm(maps:get(startup_timeout_ms,O),S#st{port=P,retry=undefined})}
    catch _:_ -> {noreply,retry(S#st{error=backend_unavailable,retry=undefined})} end;
handle_info({P,{data,<<"R">>}},S=#st{port=P,ready=false}) ->
    {noreply,clear_timer(S#st{ready=true,error=undefined})};
handle_info({P,{data,<<"D">>}},S=#st{port=P,busy=true,parts=[]}) ->
    gate(tail(S),S),{noreply,clear_timer(S#st{busy=false})};
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
        {ok,[First|Rest]} -> {ok,send(First,S#st{parts=Rest,busy=true})};
        Error -> {Error,S}
    end.
send(Text,S=#st{port=P,opts=O}) ->
    Timeout=maps:get(speech_timeout_ms,O),gate(Timeout+tail(S)+1000,S),
    try true=port_command(P,<<"S",Text/binary>>),arm(Timeout,S)
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
path(Key,O) ->
    P=unicode:characters_to_list(maps:get(Key,O)),absolute=filename:pathtype(P),P.
arm(Ms,S) -> C=clear_timer(S),C#st{timer=erlang:start_timer(Ms,self(),tts)}.
clear_timer(S=#st{timer=undefined}) -> S;
clear_timer(S=#st{timer=T}) -> erlang:cancel_timer(T),S#st{timer=undefined}.
retry(S=#st{retry=undefined}) -> S#st{retry=erlang:send_after(5000,self(),connect)};
retry(S) -> S.
disconnect(Reason,S) ->
    case S#st.busy of true -> gate(tail(S),S);false -> ok end,
    close(S#st.port),retry(clear_timer(S#st{port=undefined,ready=false,busy=false,parts=[],error=Reason})).
close(undefined) -> ok;
close(P) -> catch port_close(P),ok.
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
    case S#st.busy of true -> gate(tail(S),S);false -> ok end,
    close(S#st.port),ok.
code_change(_,S,_) -> {ok,S}.
