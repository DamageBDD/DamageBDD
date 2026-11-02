%% Optional native GTKGS controls for the supervised ECDJ core. Opening this
%% window performs no network requests and never changes active playback.
-module(erm_dj_widget).
-behaviour(gen_server).
-export([start/0, start_link/0, show/0, close/0, status/0,
         parse_context/2, track_summary/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start() ->
    case whereis(?MODULE) of
        P when is_pid(P) -> show(), {ok,P};
        undefined ->
            case gtk_ready() of
                ok -> with_core(fun()->gen_server:start({local,?MODULE},?MODULE,[],[]) end);
                Error -> Error
            end
    end.
start_link() ->
    case gtk_ready() of
        ok -> with_core(fun()->gen_server:start_link({local,?MODULE},?MODULE,[],[]) end);
        Error -> Error
    end.

with_core(Start) ->
    try erm_dj:start() of
        {ok,_} -> Start();
        {error,{already_started,_}} -> Start();
        ok -> Start();
        Error -> Error
    catch _:_ -> {error,dj_core_unavailable} end.
show() ->
    case whereis(?MODULE) of
        undefined -> start();
        _ -> gen_server:call(?MODULE,show)
    end.
close() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:stop(?MODULE,normal,5000)
    end.
status() ->
    case whereis(?MODULE) of
        undefined -> #{running=>false};
        _ -> gen_server:call(?MODULE,status)
    end.

gtk_ready() ->
    try
        true = is_pid(whereis(gtkgs)),
        ok = gtknode4:await_ready(1000),
        ok
    catch _:_ -> {error,gtk_unavailable} end.

init([]) ->
    process_flag(trap_exit,true),
    case create_window() of
        {ok,Window,Server} ->
            try init_ui(Window,Server)
            catch C:R ->
                %% GTK objects are owned by this process. Explicitly remove
                %% the partial tree before reporting a failed start.
                try gtkgs:destroy(Window) catch _:_ -> ok end,
                {stop,{dj_widget_start_failed,C,R}}
            end;
        {error,R} -> {stop,R}
    end.

create_window() ->
    try
        Server=gtkgs:server(),
        Window=ref(gtkgs:create(window,erm_dj_window,Server,
            [{title,"ERM · ECDJ"},{width,820},{height,700},{min_width,360},
             {min_height,300},{wm_class,"erm_dj"},{wm_instance,"erm_dj"}])),
        {ok,Window,Server}
    catch C:R -> {error,{dj_widget_start_failed,C,R}} end.

init_ui(Window,Server) ->
        Scroll=ref(gtkgs:create(scrolled,Window,
            [{orient,vertical},{hscroll,never},{vscroll,automatic},{expand,true}])),
        Root=ref(gtkgs:create(frame,Scroll,
            [{orient,vertical},{spacing,10},{margin,18},{expand,true}])),
        _=label(Root,"ECDJ · open music discovery"),
        _=label(Root,"Fetch a release, cache its licensed audio, then recommend and play."),
        _=label(Root,"Ektoplazm release URL"),
        URL=ref(gtkgs:create(entry,erm_dj_url,Root,
            [{text,""},{hexpand,true}])),
        SourceRow=row(Root),
        Discover=button(SourceRow,discover,"Find releases"),
        Fetch=button(SourceRow,fetch,"Fetch release"),
        Cache=button(SourceRow,cache,"Cache fetched release"),
        Release=label(Root,"No release selected."),
        _=label(Root,"Preferred tags (comma separated)"),
        Tags=ref(gtkgs:create(entry,erm_dj_tags,Root,
            [{text,""},{hexpand,true}])),
        _=label(Root,"Desired mood (optional tag, such as ambient or uplifting)"),
        Mood=ref(gtkgs:create(entry,erm_dj_mood,Root,
            [{text,""},{hexpand,true}])),
        PlayRow=row(Root),
        Recommend=button(PlayRow,recommend,"Recommend"),
        Play=button(PlayRow,play,"Play selection"),
        Next=button(PlayRow,next,"Play next"),
        Recommendations=label(Root,"No recommendations yet."),
        Current=label(Root,"Nothing played from ECDJ yet."),
        RateRow=row(Root),
        Like=button(RateRow,like,"Like (+1)"),
        Dislike=button(RateRow,dislike,"Dislike (-1)"),
        Message=label(Root,"Ready. Opening this window does not fetch or play music."),
        ok=gtkgs:config(Window,{show,true}),
        {ok,#{window=>Window,gtk_mon=>monitor(process,Server),
              url=>URL,tags=>Tags,mood=>Mood,release_label=>Release,
              recommendations_label=>Recommendations,current_label=>Current,
              message=>Message,buttons=>[Discover,Fetch,Cache,Recommend,Play,Next,Like,Dislike],
              release=>undefined,recommendations=>[],index=>0,current=>undefined,
              job=>undefined,last_result=>undefined}}.

handle_call(show,_,S) ->
    ok=gtkgs:config(maps:get(window,S),{show,true}), {reply,ok,S};
handle_call(status,_,S) ->
    {reply,#{running=>true,busy=>maps:get(job,S)=/=undefined,
             recommendations=>length(maps:get(recommendations,S)),
             last_result=>maps:get(last_result,S)},S};
handle_call(_,_,S) -> {reply,{error,unsupported_call},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info({gtkgs,_,click,{ecdj,Action},[]},S) ->
    {noreply,action(Action,S)};
handle_info({gtkgs,erm_dj_url,keypress,_,['Return',_]},S) ->
    {noreply,action(fetch,S)};
handle_info({gtkgs,erm_dj_window,destroy,_,_},S) -> {stop,normal,S};
handle_info({dj_result,Ref,Action,Result},S=#{job:=#{ref:=Ref,mon:=Mon,timer:=Timer}}) ->
    erlang:cancel_timer(Timer), demonitor(Mon,[flush]),
    S1=busy(false,S#{job=>undefined,last_result=>result_tag(Result)}),
    {noreply,result(Action,Result,S1)};
handle_info({dj_timeout,Ref},S=#{job:=#{ref:=Ref,pid:=Pid,mon:=Mon}}) ->
    exit(Pid,kill), demonitor(Mon,[flush]),
    {noreply,message("Operation timed out. Check ECDJ status before retrying.",
                     busy(false,S#{job=>undefined,last_result=>timeout}))};
handle_info({'DOWN',Mon,process,_,_},S=#{gtk_mon:=Mon}) -> {stop,normal,S};
handle_info({'DOWN',Mon,process,_,Reason},S=#{job:=#{mon:=Mon,timer:=Timer}}) ->
    erlang:cancel_timer(Timer),
    {noreply,message(format({worker_stopped,Reason}),
                     busy(false,S#{job=>undefined,last_result=>error}))};
handle_info(_,S) -> {noreply,S}.

action(_,S=#{job:=J}) when J=/=undefined -> message("An operation is already running.",S);
action(discover,S) -> work(discover,fun erm_dj:discover/0,S);
action(fetch,S) ->
    URL=entry(maps:get(url,S)),
    case byte_size(URL)>0 andalso byte_size(URL)=<4096 of
        true -> work(fetch,fun()->erm_dj:fetch(URL) end,S);
        false -> message("Enter an Ektoplazm release URL.",S)
    end;
action(cache,S=#{release:=undefined}) -> message("Fetch a release first.",S);
action(cache,S=#{release:=R}) -> work(cache,fun()->erm_dj:cache_release(maps:get(id,R)) end,S);
action(recommend,S) ->
    case parse_context(entry(maps:get(tags,S)),entry(maps:get(mood,S))) of
        {ok,C} -> work(recommend,fun()->erm_dj:recommend(C,10) end,S);
        Error -> message(format(Error),S)
    end;
action(play,S) -> play_selection(S);
action(next,S=#{recommendations:=[]}) -> message("Recommend some cached music first.",S);
action(next,S=#{recommendations:=Tracks,index:=I}) ->
    play_selection(S#{index=>(I+1) rem length(Tracks)});
action(like,S) -> rate(1,S);
action(dislike,S) -> rate(-1,S);
action(_,S) -> S.

play_selection(S=#{recommendations:=[]}) -> message("Recommend some cached music first.",S);
play_selection(S=#{recommendations:=Tracks,index:=I}) ->
    T=lists:nth(I+1,Tracks),
    work(play,fun()->erm_dj:play(maps:get(id,T)) end,S).
rate(_,S=#{current:=undefined}) -> message("Play a track before rating it.",S);
rate(Rating,S=#{current:=T}) ->
    work(rate,fun()->erm_dj:rate(maps:get(id,T),Rating) end,S).

work(Action,Fun,S) ->
    Parent=self(), Ref=make_ref(),
    {Pid,Mon}=spawn_opt(fun()->
        Result=try Fun() catch C:R -> {error,{C,R}} end,
        Parent!{dj_result,Ref,Action,Result}
    end,[link,monitor]),
    %% The catalogue owns its own 180-second archive deadline. Allow its
    %% structured result to arrive before timing out this presentation worker.
    Timer=erlang:send_after(190000,self(),{dj_timeout,Ref}),
    message("Working…",busy(true,S#{job=>#{ref=>Ref,pid=>Pid,mon=>Mon,timer=>Timer}})).

result(discover,{ok,[URL|_]=URLs},S) ->
    ok=gtkgs:config(maps:get(url,S),{text,URL}),
    message(format({found_releases,length(URLs),fetch_the_first_or_paste_another}),S);
result(discover,{ok,[]},S) -> message("No release links found.",S);
result(fetch,{ok,R},S) when is_map(R) ->
    ok=gtkgs:config(maps:get(release_label,S),{label,track_summary(R)}),
    message("Release fetched. Cache its audio when ready.",S#{release=>R});
result(cache,{ok,Tracks},S) when is_list(Tracks) ->
    message(format({cached_tracks,length(Tracks)}),S);
result(recommend,{ok,Tracks},S) when is_list(Tracks) ->
    Lines=[io_lib:format("~B. ~ts — ~ts",[N,maps:get(artist,T,<<"Unknown artist">>),
                         maps:get(title,T,<<"Untitled">>)]) || {N,T}<-lists:zip(lists:seq(1,length(Tracks)),Tracks)],
    Text=case Lines of []->"No cached music matches. Fetch and cache a release first.";
                          _->lists:join("\n",Lines) end,
    ok=gtkgs:config(maps:get(recommendations_label,S),{label,unicode:characters_to_binary(Text)}),
    message("Recommendations ready. Play selection starts the first result.",
            S#{recommendations=>Tracks,index=>0});
result(play,{ok,T},S) when is_map(T) ->
    ok=gtkgs:config(maps:get(current_label,S),{label,track_summary(T)}),
    message("Playing through ERM media.",S#{current=>T});
result(rate,ok,S) -> message("Rating saved locally.",S);
result(_,Error,S) -> message(format(Error),S).

%% Explicit user input only. This reducer never infers emotions or samples audio.
parse_context(Tags,Mood) when is_binary(Tags),byte_size(Tags)=<2048,
                              is_binary(Mood),byte_size(Mood)=<128 ->
    try
        Parts=[unicode:characters_to_binary(string:trim(X)) || X<-string:split(unicode:characters_to_list(Tags),",",all)],
        Clean=lists:usort([T || T<-Parts,T=/=<<>>]),
        true=length(Clean)=<16,
        true=lists:all(fun(T)->byte_size(T)=<128 end,Clean),
        M=unicode:characters_to_binary(string:trim(unicode:characters_to_list(Mood))),
        {ok,#{tags=>Clean,mood=>M}}
    catch _:_ -> {error,invalid_context} end;
parse_context(_,_) -> {error,invalid_context}.

track_summary(T) when is_map(T) ->
    L=maps:get(license,T,#{}),
    unicode:characters_to_binary(io_lib:format("~ts — ~ts\nLicence: ~ts\n~ts\nSource: ~ts",
        [maps:get(artist,T,<<"Unknown artist">>),maps:get(title,T,<<"Untitled">>),
         maps:get(id,L,<<"Unknown">>),maps:get(url,L,<<>>),maps:get(source_url,T,<<>>)]));
track_summary(_) -> <<"No track selected.">>.

ref({gtkgs_ref,_,_}=R)->R;
ref(Error)->error(Error).
row(Parent)->ref(gtkgs:create(frame,Parent,[{orient,horizontal},{spacing,8}])).
label(Parent,Text)->ref(gtkgs:create(label,Parent,[{label,Text},{wrap,true}])).
button(Parent,Action,Text)->ref(gtkgs:create(button,Parent,
    [{label,Text},{data,{ecdj,Action}},{hexpand,true}])).
entry(Ref)->
    case gtkgs:read(Ref,text) of
        B when is_binary(B)->B;
        L when is_list(L)->unicode:characters_to_binary(L);
        _-><<>>
    end.
busy(Value,S)->
    lists:foreach(fun(B)->ok=gtkgs:config(B,{enable,not Value}) end,maps:get(buttons,S)),S.
message(Text,S)->ok=gtkgs:config(maps:get(message,S),{label,Text}),S.
format(T)->unicode:characters_to_binary(io_lib:format("~tp",[T])).
result_tag({ok,_})->ok;
result_tag(ok)->ok;
result_tag(_)->error.
terminate(_,S)->
    case maps:get(job,S,undefined) of
        #{pid:=Pid,timer:=Timer}->exit(Pid,kill),erlang:cancel_timer(Timer);
        _->ok
    end,
    try gtkgs:destroy(maps:get(window,S)) catch _:_ ->ok end,
    ok.
code_change(_,_,_)->{error,restart_required}.
