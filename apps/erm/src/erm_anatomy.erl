%% GTKGS anatomy mesh viewer. Apache-2.0.
-module(erm_anatomy).
-behaviour(gen_server).
-export([show/0, stop/0, status/0, start_link/1, child_spec/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).

show() ->
    case whereis(?MODULE) of
        P when is_pid(P) -> gen_server:call(P,show);
        undefined ->
            Opts=application:get_env(erm,anatomy,[]),
            case erm_sup:start_gtknode4() of
                {error,_}=E -> E;
                _ -> case gtknode4:await_ready(10000) of
                    ok -> supervisor:start_child(erm_sup,child_spec(Opts));
                    E -> E
                end
            end
    end.
stop() -> case whereis(?MODULE) of undefined -> ok; _ -> gen_server:stop(?MODULE) end.
status() -> case whereis(?MODULE) of undefined -> not_started; _ -> gen_server:call(?MODULE,status) end.
start_link(Opts) -> gen_server:start_link({local,?MODULE},?MODULE,Opts,[]).
child_spec(Opts) -> #{id=>?MODULE,start=>{?MODULE,start_link,[Opts]},restart=>temporary,
    shutdown=>5000,type=>worker,modules=>[?MODULE]}.

init(Opts0) ->
    process_flag(trap_exit,true),
    Opts=case is_map(Opts0) of true -> Opts0; false -> maps:from_list(Opts0) end,
    %% A process-private directory avoids shared filenames and stale frames.
    Dir=filename:absname(filename:join(maps:get(cache_dir,Opts,"/tmp"),
        "erm_anatomy_"++integer_to_list(erlang:unique_integer([positive,monotonic]))++"_"++os:getpid())),
    case file:make_dir(Dir) of
        ok ->
            try
                ok=file:change_mode(Dir,8#700),
                init_ui(Dir,Opts)
            catch C:R ->
                try gtkgs:destroy(erm_anatomy_window) catch _:_ -> ok end,
                [file:delete(filename:join(Dir,F)) || F <- ["0.svg","1.svg"]],
                file:del_dir(Dir),
                {stop,{initialization,C,R}}
            end;
        E -> {stop,{cache_directory,E}}
    end.
init_ui(Dir,Opts) ->
    S=#{parts=>[],rows=>[],selected=>undefined,camera=>{0.0,0.0,1.0},
        bounds=>{{0.0,0.0,0.0},1.0},dir=>Dir,frame=>0,options=>Opts,
        phase=>loading,worker=>undefined,load_ref=>undefined},
    case gtkgs:create_tree(gtkgs:server(),tree([],"Preparing anatomy dataset")) of
        {ok,[W]} ->
            ok=gtkgs:config(W,{map,true}),
            {ok,start_load(draw(S))};
        E -> file:del_dir(Dir), {stop,{ui,E}}
    end.
start_load(#{worker:=undefined}=S) ->
    Parent=self(), Ref=make_ref(), Opts=maps:get(options,S),
    {Pid,Monitor}=spawn_opt(fun()->
        Progress=fun(P)->Parent!{anatomy_progress,Ref,P} end,
        Result=try
            case erm_anatomy_data:ensure(Opts,Progress) of
                {ok,Root,Receipt}->
                    Progress(#{stage=>loading}),
                    case load_parts(Root) of
                        {ok,Parts}->
                            Axis=maps:get(up_axis,Opts,z),
                            Oriented=[P#{mesh:=orient(maps:get(mesh,P),Axis)} || P <- Parts],
                            {ok,Oriented,erm_anatomy_mesh:bounds(Oriented),Receipt};
                        Error->Error
                    end;
                Error->Error
            end
        catch C:R->{error,{C,R}} end,
        Parent!{anatomy_loaded,Ref,Result}
    end,[link,monitor]),
    set_status("Preparing local anatomy data..."),
    S#{worker:={Pid,Monitor},load_ref:=Ref,phase:=loading};
start_load(S) -> S.
set_status(Text) -> gtkgs:config(erm_anatomy_status,{label,Text}).
progress_text(#{stage:=downloading,file:=File,bytes:=N}) ->
    io_lib:format("Downloading ~s: ~.1f MiB",[File,N/1048576]);
progress_text(#{stage:=extracting,meshes:=N,total_meshes:=Total}) ->
    io_lib:format("Preparing meshes: ~B / ~B",[N,Total]);
progress_text(#{stage:=Stage}) -> io_lib:format("Anatomy: ~p",[Stage]).
load_parts(Root) ->
    case file:consult(filename:join(Root,"manifest.config")) of
        {ok,[Specs]} when is_list(Specs), Specs =/= [], length(Specs) =< 200 ->
            try
                Parts=[load_part(Root,P) || P <- Specs],
                IDs=[maps:get(id,P) || P <- Parts],
                true=length(IDs)=:=length(lists:usort(IDs)),
                true=lists:sum([length(maps:get(triangles,maps:get(mesh,P))) || P <- Parts]) =< 50000,
                {ok,Parts}
            catch C:R -> {error,{invalid_manifest,C,R}} end;
        E -> {error,{manifest,E}}
    end.
load_part(Root,#{id:=ID,name:=Name}=P) when is_binary(ID),is_binary(Name) ->
    Files=case maps:find(files,P) of {ok,Fs}->Fs; error->[maps:get(file,P)] end,
    true=is_list(Files) andalso Files=/=[] andalso length(Files)=<4000,
    Meshes=[begin
        true=filename:pathtype(File)=:=relative,
        false=lists:member("..",filename:split(File)),
        {ok,M}=erm_anatomy_mesh:load(filename:join(Root,File)), M
    end || File <- Files],
    Mesh=#{triangles=>lists:append([maps:get(triangles,M) || M <- Meshes])},
    {R,G,B}=maps:get(color,P,{175,190,205}),
    true=lists:all(fun(V)-> is_integer(V) andalso V>=0 andalso V=<255 end,[R,G,B]),
    P#{mesh=>Mesh,visible=>true}.

tree(Parts,Credit) ->
    [{window,erm_anatomy_window,[{title,"erm anatomy"},{size,{1180,850}},{orient,vertical}],
      [{label,erm_anatomy_credit,[{label,Credit}]},
       {frame,erm_anatomy_body,[{orient,horizontal},{expand,true}],
        [{frame,erm_anatomy_sidebar,[{orient,vertical}],
          [{entry,erm_anatomy_search,[{text,""},{tooltip,"Search names or IDs; press Return"}]},
           {listbox,erm_anatomy_parts,[{items,names(Parts)},{expand,true}]},
           {button,erm_anatomy_hide,[{label,"Hide / show selected"},{data,toggle}]},
           {button,erm_anatomy_isolate,[{label,"Isolate selected"},{data,isolate}]},
           {button,erm_anatomy_all,[{label,"Show all"},{data,all}]}]},
         {picture,erm_anatomy_view,[{expand,true}]}]},
       {frame,erm_anatomy_controls,[{orient,horizontal}],
        [button(erm_anatomy_left,"Left",left),button(erm_anatomy_right,"Right",right),
         button(erm_anatomy_up,"Up",up),button(erm_anatomy_down,"Down",down),
         button(erm_anatomy_in,"Zoom +",zoom_in),button(erm_anatomy_out,"Zoom −",zoom_out),
         button(erm_anatomy_reset,"Reset",reset),
         button(erm_anatomy_retry,"Retry setup",retry)]},
       {label,erm_anatomy_status,[{label,"Select a structure"}]}]}].
button(Name,Label,Action) -> {button,Name,[{label,Label},{data,Action}]}.
names(Parts) -> [maps:get(name,P) || P <- Parts].
handle_call(show,_From,S) -> {reply,gtkgs:config(erm_anatomy_window,{map,true}),S};
handle_call(status,_From,S) -> {reply,maps:with([camera,selected,phase,progress,error,source],S),S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({anatomy_progress,Ref,Progress},#{load_ref:=Ref}=S) ->
    set_status(progress_text(Progress)),
    {noreply,S#{progress=>Progress}};
handle_info({anatomy_loaded,Ref,Result},#{load_ref:=Ref,worker:={Pid,Mon}}=S) ->
    unlink(Pid), demonitor(Mon,[flush]),
    Next=maps:remove(error,S#{worker:=undefined,load_ref:=undefined}),
    case Result of
        {ok,Parts,Bounds,Receipt} ->
            ok=gtkgs:config(erm_anatomy_parts,{items,names(Parts)}),
            ok=gtkgs:config(erm_anatomy_credit,{label,maps:get(attribution,Receipt)}),
            set_status(io_lib:format("Loaded ~B structures. Select one to explore.",[length(Parts)])),
            {noreply,draw(Next#{parts:=Parts,rows:=Parts,bounds:=Bounds,phase:=ready,
                               source=>maps:get(source,Receipt),selected:=undefined})};
        {error,Reason} ->
            set_status(io_lib:format("Setup failed: ~tp. Use Retry setup after correcting the cause.",[Reason])),
            {noreply,Next#{phase:=failed,error=>Reason}}
    end;
handle_info({'DOWN',Mon,process,_Pid,Reason},#{worker:={_,Mon}}=S) ->
    set_status(io_lib:format("Setup stopped: ~tp. Use Retry setup.",[Reason])),
    {noreply,S#{worker:=undefined,load_ref:=undefined,phase:=failed,error=>Reason}};
handle_info({'EXIT',_,_},S) -> {noreply,S};
handle_info({gtkgs,erm_anatomy_retry,click,retry,[]},S) -> {noreply,start_load(S)};
handle_info({gtkgs,erm_anatomy_window,destroy,_,_},S) -> {stop,normal,S};
handle_info({gtkgs,erm_anatomy_search,keypress,_,['Return',Text]},S) ->
    Q=string:casefold(unicode:characters_to_list(Text)),
    Rows=[P || P <- maps:get(parts,S), string:find(string:casefold(
        unicode:characters_to_list([maps:get(name,P)," ",maps:get(id,P)])),Q) =/= nomatch],
    ok=gtkgs:config(erm_anatomy_parts,{items,names(Rows)}),
    {noreply,S#{rows:=Rows}};
handle_info({gtkgs,erm_anatomy_parts,Event,_,[Index,_,true]},S) when Event=:=select; Event=:=click ->
    Rows=maps:get(rows,S),
    case is_integer(Index) andalso Index>=0 andalso Index<length(Rows) of
        true -> P=lists:nth(Index+1,Rows),
            ok=gtkgs:config(erm_anatomy_status,{label,<< (maps:get(name,P))/binary," - ",(maps:get(id,P))/binary >>}),
            {noreply,draw(S#{selected:=maps:get(id,P)})};
        false -> {noreply,S}
    end;
handle_info({gtkgs,_,click,Action,[]},S) -> {noreply,draw(action(Action,S))};
handle_info(_,S) -> {noreply,S}.
action(reset,S) -> S#{camera:={0.0,0.0,1.0}};
action(A,#{camera:={Y,P,Z}}=S) when A=:=left; A=:=right; A=:=up; A=:=down; A=:=zoom_in; A=:=zoom_out ->
    C=case A of left->{Y-0.15,P,Z}; right->{Y+0.15,P,Z}; up->{Y,P+0.15,Z};
        down->{Y,P-0.15,Z}; zoom_in->{Y,P,min(8.0,Z*1.2)}; zoom_out->{Y,P,max(0.1,Z/1.2)} end,
    S#{camera:=C};
action(A,#{parts:=Parts,selected:=ID}=S) when A=:=toggle; A=:=isolate; A=:=all ->
    Ps=[P#{visible:=case A of
        all -> true;
        isolate when ID=:=undefined -> maps:get(visible,P);
        isolate -> maps:get(id,P)=:=ID;
        toggle -> case maps:get(id,P)=:=ID of true->not maps:get(visible,P); false->maps:get(visible,P) end
    end} || P <- Parts], S#{parts:=Ps};
action(_,S) -> S.
draw(S) ->
    N=maps:get(frame,S)+1,
    Path=filename:join(maps:get(dir,S),integer_to_list(N rem 2)++".svg"),
    SVG=erm_anatomy_mesh:svg(maps:get(parts,S),maps:get(camera,S),maps:get(bounds,S),maps:get(selected,S)),
    ok=file:write_file(Path,SVG),
    ok=gtkgs:config(erm_anatomy_view,{file,Path}),
    ok=gtkgs:sync(), S#{frame:=N}.
terminate(_,S) ->
    case maps:get(worker,S,undefined) of
        {Pid,Mon}->unlink(Pid),exit(Pid,shutdown),demonitor(Mon,[flush]);
        undefined->ok
    end,
    try gtkgs:destroy(erm_anatomy_window) catch _:_ -> ok end,
    Dir=maps:get(dir,S),
    [file:delete(filename:join(Dir,F)) || F <- ["0.svg","1.svg"]],
    file:del_dir(Dir), ok.
code_change(_,S,_) -> {ok,S}.

orient(#{triangles:=Ts}=M,z) -> M#{triangles:=[{z_up(A),z_up(B),z_up(C)} || {A,B,C} <- Ts]};
orient(M,y) -> M.
z_up({X,Y,Z}) -> {X,Z,-Y}.
