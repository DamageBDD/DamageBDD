%% A passive observer of the real local voice pipeline; opening it never
%% enables recording, changes speaker verification, or dispatches commands.
-module(erm_voice_widget).
-behaviour(gen_server).
-export([start/0, start/1, start_link/1, show/0, hide/0, stop/0, status/0,
         view/2, level/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start() -> start(#{}).
start(O) ->
    case gen_server:start({local,?MODULE},?MODULE,O,[]) of
        {error,{already_started,P}} -> show(), {ok,P}; R -> R
    end.
start_link(O) -> gen_server:start_link({local,?MODULE},?MODULE,O,[]).
show() -> gen_server:call(?MODULE,show).
hide() -> gen_server:call(?MODULE,hide).
stop() -> case whereis(?MODULE) of undefined -> ok; _ -> gen_server:stop(?MODULE) end.
status() -> gen_server:call(?MODULE,status).
init(O) when is_map(O) ->
    try
        Sources=maps:get(sources,O,all),
        true=Sources=:=all orelse (is_list(Sources) andalso lists:all(fun is_atom/1,Sources)),
        Text=maps:get(show_text,O,true), true=is_boolean(Text),
        {ok,Bus}=erm_voice_events:ensure_started(),
        {ok,Seq,Events}=erm_voice_events:subscribe(),
        ok=gtknode4:await_ready(5000),
        #{capabilities:=#{motion:=1}}=gtknode4:status(),
        ok=gtkgs:set_stylesheet(erm_voice_widget,css()),
        Server=gtkgs:server(),
        Window=ref(gtkgs:create(window,erm_voice_window,Server,
                   [{title,"erm · voice"},{width,360},{height,440},{class,"erm_voice_window"},
                    {wm_class,"erm_voice"},{wm_instance,"erm_voice"}])),
        Root=ref(gtkgs:create(frame,Window,[{orient,vertical},{spacing,4},{border,24}])),
        _=ref(gtkgs:create(label,Root,[{label,"E C A I   /   V O I C E"},{class,"erm_voice_eyebrow"}])),
        Stage=ref(gtkgs:create(motion,Root,[{expand,true}])),
        Meter=ref(gtkgs:create(voice_meter,Stage,[{width,240},{height,240}])),
        Title=ref(gtkgs:create(label,Root,[{label,"Waiting for voice"},{class,"erm_voice_title"}])),
        Detail=ref(gtkgs:create(label,Root,[{label,"Start your voice session to connect"},
                    {wrap,true},{class,"erm_voice_detail"},{height,60}])),
        _=ref(gtkgs:create(label,Root,[{label,"MIC  /  teal        VOICE  /  violet"},{class,"erm_voice_legend"}])),
        ok=gtkgs:config(Window,{show,true}),
        ok=gtkgs_motion:set(Stage,#{opacity=>0,scale=>0.94,y=>10}),
        {ok,_}=gtkgs_motion:animate(Stage,#{opacity=>1,scale=>1,y=>0},#{duration=>320}),
        Mon=monitor(process,gtkgs:server()),
        States=maps:from_list([{maps:get(key,E),E} || E <- Events]),
        self() ! refresh,
        {ok,#{window=>Window,meter=>Meter,title=>Title,detail=>Detail,seq=>Seq,
              states=>States,options=>O,sources=>Sources,show_text=>Text,
              bus=>Bus,bus_mon=>monitor(process,Bus),gtk_mon=>Mon,
              timer=>erlang:send_after(1000,self(),refresh),view=>undefined,hidden=>false}}
    catch C:R -> {stop,{voice_widget_start_failed,C,R}} end;
init(_) -> {stop,invalid_options}.
ref({gtkgs_ref,_,_}=R) -> R;
ref(Error) -> error(Error).
handle_call(show,_,S) ->
    ok=gtkgs:config(maps:get(window,S),{show,true}),
    {reply,ok,render(S#{hidden=>false})};
handle_call(hide,_,S) ->
    ok=gtkgs:config(maps:get(window,S),{show,false}), {reply,ok,S#{hidden=>true}};
handle_call(status,_,S) -> {reply,maps:with([view,hidden,sources],S),S};
handle_call(_,_,S) -> {reply,{error,badarg},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({erm_voice_event,Seq,E},S) ->
    Next=case Seq=:=maps:get(seq,S)+1 of
        true -> S#{states=>put_event(E,maps:get(states,S)),seq=>Seq};
        false -> resync(S)
    end,
    {noreply,render(Next)};
handle_info(refresh,S) ->
    erlang:cancel_timer(maps:get(timer,S)),
    %% A low-rate reconciliation recovers dropped telemetry and a restarted bus.
    {noreply,render((resync(S))#{timer=>erlang:send_after(1000,self(),refresh)})};
handle_info({'DOWN',M,process,_,_},S=#{gtk_mon:=M}) -> {stop,normal,S};
handle_info({'DOWN',M,process,_,_},S=#{bus_mon:=M}) -> {noreply,S#{states=>#{},bus=>undefined}};
handle_info({gtkgs,erm_voice_window,destroy,_,_},S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
put_event(#{key:=K,data:=#{phase:=stopped}},States) ->
    maps:remove(K,States);
put_event(E=#{key:=K},States) -> States#{K=>E}.
resync(S) ->
    try
        {ok,P}=erm_voice_events:ensure_started(),
        {ok,Seq,Events}=erm_voice_events:subscribe(),
        Mon=case P=:=maps:get(bus,S) of
            true -> maps:get(bus_mon,S);
            false -> demonitor(maps:get(bus_mon,S),[flush]), monitor(process,P)
        end,
        S#{seq=>Seq,states=>maps:from_list([{maps:get(key,E),E} || E<-Events]),bus=>P,bus_mon=>Mon}
    catch _:_ -> S end.
render(S=#{hidden:=true}) -> S;
render(S) ->
    Sources=maps:get(sources,S),
    Events=[E || E<-maps:values(maps:get(states,S)),
                 Sources=:=all orelse lists:member(maps:get(source,E),Sources)],
    V=view(Events,erlang:monotonic_time(millisecond)),
    Old=maps:get(view,S),
    case Old=/=undefined andalso V=:=maps:remove(display_text,Old) of
        true -> S;
        false ->
            {ok,_}=gtkgs_motion:animate(maps:get(meter,S),
                        maps:with([input,output,mood],V),#{duration=>90,easing=>out_cubic}),
            update_label(title,maps:get(title,V),Old,S),
            Detail=case maps:get(show_text,S) of true->maps:get(text,V);false->maps:get(hint,V) end,
            case Old=:=undefined orelse Detail=/=maps:get(display_text,Old,undefined) of
                true -> gtkgs:config(maps:get(detail,S),{label,Detail}); false -> ok
            end,
            S#{view=>V#{display_text=>Detail}}
    end.
update_label(Key,Value,Old,S) ->
    case Old=:=undefined orelse maps:get(Key,Old)=/=Value of
        true -> gtkgs:config(maps:get(Key,S),{label,Value}); false -> ok
    end.
%% Pure reducer shared by integration tests. Never manufacture an audio level.
view(Events,Now) ->
    Inputs=[E || E=#{channel:=input}<-Events], Outputs=[E || E=#{channel:=output}<-Events],
    Work=[E || E=#{channel:=work}<-Events],
    In=max_level(Inputs,Now), Out=max_level(Outputs,Now),
    Speaking=has_phase(Outputs,[speaking]),
    Processing=has_phase(Work,[processing]) orelse has_phase(Outputs,[synthesizing]),
    Listening=has_phase(Inputs,[listening]),
    Error=has_phase([E || E=#{at:=At}<-Events,Now-At<5000],[error]),
    Muted=has_phase(Inputs,[muted]),
    {Mood,Title,Hint}=case {Speaking,Processing,Listening,Error,Muted} of
        {true,_,_,_,_} -> {3,<<"Speaking">>,<<"Voice output is playing">>};
        {_,true,_,_,_} -> {2,<<"Processing">>,<<"Working on your voice input">>};
        {_,_,_,true,_} -> {4,<<"Voice needs attention">>,<<"Check voice backend status">>};
        {_,_,true,_,_} when In>0.03 -> {1,<<"Listening">>,<<"Microphone activity">>};
        {_,_,true,_,_} -> {0,<<"Ready">>,<<"Voice capture is active">>};
        {_,_,_,_,true} -> {0,<<"Microphone gated">>,<<"Waiting for the capture gate to reopen">>};
        _ -> {0,<<"Waiting for voice">>,<<"Start your voice session to connect">>}
    end,
    Texts=lists:sort([{maps:get(text_at,E,maps:get(at,E)),T} || E=#{data:=#{text:=T}}<-Events,T=/=<<>>]),
    Text=case Texts of []->Hint;_->element(2,lists:last(Texts)) end,
    #{input=>In,output=>Out,mood=>Mood,title=>Title,hint=>Hint,text=>Text}.
has_phase(Events,Phases) -> lists:any(fun(#{data:=D})->lists:member(maps:get(phase,D,idle),Phases) end,Events).
max_level(Events,Now) -> lists:max([0.0|[maps:get(level,D,0.0) || #{at:=At,data:=D}<-Events,
                        Now-At<400, lists:member(maps:get(phase,D,idle),[listening,speaking])]]).
level(Db) when is_number(Db) -> max(0.0,min(1.0,(Db+60)/60));
level(_) -> 0.0.
terminate(_,S) ->
    erlang:cancel_timer(maps:get(timer,S)),
    try erm_voice_events:unsubscribe() catch _:_ -> ok end,
    try gtkgs:destroy(maps:get(window,S)) catch _:_ -> ok end,
    ok.
code_change(_,S,_) -> {ok,S}.
css() -> <<
".erm_voice_window { background: #0d1420; color: #edf3fa; }\n"
".erm_voice_eyebrow { color: #86a0b8; font-size: 11px; letter-spacing: 2px; margin-top: 18px; }\n"
".erm_voice_title { font-size: 25px; font-weight: 600; margin: 4px; }\n"
".erm_voice_detail { color: #a9b9cb; font-size: 13px; margin: 8px 20px; }\n"
".erm_voice_legend { color: #7f91a8; font-size: 10px; margin: 14px; }\n">>.
