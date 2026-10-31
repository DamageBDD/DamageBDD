%% ECDJ catalogue and private session state. No network work in the server loop.
-module(erm_dj).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start/0,start_link/0,start_link/1,child_spec/0,stop/0,status/0,
         discover/0,fetch/1,cache_release/1,releases/0,tracks/0,
         recommend/2,play/1,rate/2,set_policy/1,export_policy/0,import_policy/1,
         show/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-define(MAX_STATE,8388608).

child_spec()->#{id=>?MODULE,start=>{?MODULE,start_link,[]},restart=>permanent,
                shutdown=>5000,type=>worker,modules=>[?MODULE]}.
start()->
    case whereis(?MODULE) of
        P when is_pid(P)->{ok,P};
        undefined->case whereis(erm_sup) of
            undefined->{error,erm_not_started};
            _->case options_map(application:get_env(erm,display_manager,#{})) of
              #{mode:=Mode} when Mode=:=greeter; Mode=:=session_host->{error,not_a_user_session};
              _->case supervisor:start_child(erm_sup,child_spec()) of
                {error,already_present}->supervisor:restart_child(erm_sup,?MODULE);
                R->R
              end
            end
        end
    end.
start_link()->start_link(application:get_env(erm,dj,#{})).
start_link(Opts) when is_map(Opts)->gen_server:start_link({local,?MODULE},?MODULE,Opts,[]).
stop()->case whereis(erm_sup) of
    undefined->call(stop);
    _->case lists:keymember(?MODULE,1,supervisor:which_children(erm_sup)) of
        true->case supervisor:terminate_child(erm_sup,?MODULE) of
            ok->supervisor:delete_child(erm_sup,?MODULE); E->E end;
        false->call(stop)
    end
end.
status()->call(status).
discover()->call(discover,65000).
fetch(URL)->call({fetch,URL},65000).
cache_release(Id)->call({cache,Id},185000).
releases()->call(releases).
tracks()->call(tracks).
recommend(Context,Limit)->call({recommend,Context,Limit}).
rate(Id,Rating)->call({rate,Id,Rating}).
set_policy(Policy)->call({policy,Policy}).
export_policy()->call(export_policy).
import_policy(Bin)->case ecai_dj_package:import(Bin) of
    {ok,P}->set_policy(P); E->E end.
show()->erm_dj_widget:show().

%% Playback happens in the caller, never while holding the catalogue loop.
play(Id)->
    case call({track,Id}) of
        {ok,T}->case erm_dj_media:play(T) of
            ok->case call({played,Id}) of ok->{ok,T}; E->E end;
            E->E
        end;
        E->E
    end.
call(M)->call(M,5000).
call(M,T)->case whereis(?MODULE) of
    undefined->{error,dj_not_started};
    _->try gen_server:call(?MODULE,M,T) catch exit:{timeout,_}->{error,timeout};
        exit:{noproc,_}->{error,dj_not_started} end
end.

init(Opts)->
    process_flag(trap_exit,true),
    %% Safe ETF decoding after a cold VM restart requires this finite atom
    %% vocabulary to be loaded; no atom creation from persisted input.
    lists:foreach(fun(M)->code:ensure_loaded(M) end,
        [erm_dj_ektoplazm,erm_dj_media,ecai_dj_package,ecai_music_recommender]),
    Dir=filename:absname(maps:get(data_dir,Opts,default_dir())),
    case private_dir(Dir) of
        ok->
            Path=filename:join(Dir,"catalogue.term"),
            case load(Path) of
                {ok,Data}->{ok,#{dir=>Dir,path=>Path,opts=>Opts,data=>Data,job=>undefined,
                                last_error=>undefined}};
                {error,R}->{stop,{catalogue_load_failed,R}}
            end;
        E->{stop,E}
    end.

handle_call(status,_,S)->
    D=maps:get(data,S),
    {reply,#{releases=>map_size(maps:get(releases,D)),tracks=>map_size(maps:get(tracks,D)),
             busy=>maps:get(job,S)=/=undefined,last_error=>maps:get(last_error,S),
             commercial=>maps:get(commercial,maps:get(opts,S),false)},S};
handle_call(releases,_,S)->{reply,{ok,ordered(maps:get(releases,maps:get(data,S)))},S};
handle_call(tracks,_,S)->{reply,{ok,ordered(maps:get(tracks,maps:get(data,S)))},S};
handle_call({track,Id},_,S)->{reply,lookup(Id,S),S};
handle_call({recommend,C,N},_,S) when is_map(C)->
    D=maps:get(data,S), C1=C#{recent_ids=>maps:get(recent,D)},
    P=case maps:get(policy,D) of undefined->ecai_dj_package:default(); V->V end,
    Allowed=[T||T<-ordered(maps:get(tracks,D)),erm_dj_media:permitted(T,maps:get(opts,S))=:=ok],
    R=ecai_music_recommender:recommend(Allowed,C1,P,maps:get(feedback,D),N),
    {reply,R,S};
handle_call({rate,Id,V},_,S) when is_integer(V),V>=-2,V=<2->
    case lookup(Id,S) of
        {ok,_}->D=maps:get(data,S), F=maps:get(feedback,D),
            Old=maps:get(Id,F,#{plays=>0,rating=>0}),
            commit(D#{feedback=>F#{Id=>Old#{rating=>V}}},S);
        E->{reply,E,S}
    end;
handle_call({played,Id},_,S)->
    case lookup(Id,S) of
        {ok,_}->D=maps:get(data,S),F=maps:get(feedback,D),
            Old=maps:get(Id,F,#{plays=>0,rating=>0}),
            Recent=lists:sublist([Id|lists:delete(Id,maps:get(recent,D))],100),
            commit(D#{recent=>Recent,feedback=>F#{Id=>Old#{plays=>maps:get(plays,Old)+1}}},S);
        E->{reply,E,S}
    end;
handle_call({policy,P},_,S)->case ecai_dj_package:validate(P) of
    {ok,V}->commit((maps:get(data,S))#{policy=>V},S);
    E->{reply,E,S}
end;
handle_call(export_policy,_,S)->
    P=case maps:get(policy,maps:get(data,S)) of undefined->ecai_dj_package:default(); V->V end,
    {reply,ecai_dj_package:export(P),S};
handle_call(discover,From,S)->job(discover,From,S);
handle_call({fetch,U},From,S)->
    case erm_dj_http:validate_url(U) of
        {ok,URL}->job({fetch,URL},From,S);
        E->{reply,E,S}
    end;
handle_call({cache,Id},From,S)->
    case maps:find(Id,maps:get(releases,maps:get(data,S))) of
        {ok,R}->job({cache,R},From,S);
        error->{reply,{error,unknown_release},S}
    end;
handle_call(stop,_,S)->{stop,normal,ok,S};
handle_call(_,_,S)->{reply,{error,bad_request},S}.

job(_,_,S=#{job:=J}) when J=/=undefined->{reply,{error,busy},S};
job(Op,From,S)->
    Parent=self(),Ref=make_ref(),Opts=maps:get(opts,S),Dir=maps:get(dir,S),
    {Pid,Mon}=spawn_opt(fun()->
        Result=try work(Op,Dir,Opts) catch C:R->{error,{worker_failed,C,R}} end,
        Parent!{job_result,Ref,Result}
    end,[link,monitor]),
    Timeout=case Op of {cache,_}->180000; _->60000 end,
    Timer=erlang:send_after(Timeout,self(),{job_timeout,Ref}),
    {noreply,S#{job=>#{ref=>Ref,pid=>Pid,mon=>Mon,timer=>Timer,from=>From,op=>Op}}}.
work(discover,_,_)->erm_dj_ektoplazm:discover();
work({fetch,U},_,_)->erm_dj_ektoplazm:fetch_release(U);
work({cache,R},Dir,Opts)->
    erm_dj_media:prepare_release(R,filename:join(Dir,"audio"),Opts).

handle_info({job_result,Ref,Result},S=#{job:=#{ref:=Ref}=J})->
    erlang:cancel_timer(maps:get(timer,J)),erlang:demonitor(maps:get(mon,J),[flush]),
    {Reply,S1}=accept(maps:get(op,J),Result,S#{job=>undefined}),
    gen_server:reply(maps:get(from,J),Reply),
    Last=case Reply of {error,R}->R; _->undefined end,
    {noreply,S1#{last_error=>Last}};
handle_info({job_timeout,Ref},S=#{job:=#{ref:=Ref}=J})->
    exit(maps:get(pid,J),kill),erlang:demonitor(maps:get(mon,J),[flush]),
    gen_server:reply(maps:get(from,J),{error,job_timeout}),
    {noreply,S#{job=>undefined,last_error=>job_timeout}};
handle_info({'DOWN',Mon,process,_,R},S=#{job:=#{mon:=Mon}=J})->
    erlang:cancel_timer(maps:get(timer,J)),
    gen_server:reply(maps:get(from,J),{error,{worker_down,R}}),
    {noreply,S#{job=>undefined,last_error=>{worker_down,R}}};
handle_info(_,S)->{noreply,S}.
handle_cast(_,S)->{noreply,S}.

accept({fetch,_},{ok,R},S)->
    D=maps:get(data,S),Rs=maps:get(releases,D),
    %% Keep cache/evidence coherent: a refreshed release invalidates its old
    %% playable rows until explicitly cached again against the new evidence.
    Id=maps:get(id,R),Ts=maps:filter(fun(_,T)->maps:get(release_id,T,undefined)=/=Id end,maps:get(tracks,D)),
    persist_result({ok,R},D#{releases=>Rs#{Id=>R},tracks=>Ts},S);
accept({cache,R},{ok,Tracks},S)->
    D=maps:get(data,S),Id=maps:get(id,R),
    Ts0=maps:filter(fun(_,T)->maps:get(release_id,T,undefined)=/=Id end,maps:get(tracks,D)),
    Ts=lists:foldl(fun(T,A)->A#{maps:get(id,T)=>T#{release_id=>Id}} end,Ts0,Tracks),
    persist_result({ok,Tracks},D#{tracks=>Ts},S);
accept(_,Reply,S)->{Reply,S}.

commit(D,S)->case persist(D,S) of
    ok->{reply,ok,S#{data=>D}};
    E->{reply,E,S}
end.
persist_result(Reply,D,S)->case persist(D,S) of
    ok->{Reply,S#{data=>D}};
    E->{E,S}
end.
persist(D,S) when map_size(D)=:=5->
    case map_size(maps:get(releases,D))=<500 andalso map_size(maps:get(tracks,D))=<10000 of
        false->{error,catalogue_full};
        true->B=term_to_binary({ecdj_state,1,D}),
            case byte_size(B)=< ?MAX_STATE of
                false->{error,catalogue_full};
                true->atomic_write(maps:get(path,S),B)
            end
    end.
atomic_write(Path,B)->
    Tmp=Path++".tmp-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    case file:open(Tmp,[write,binary,raw,exclusive]) of
        {ok,F}->
            R=try
                ok=file:change_mode(Tmp,8#600),ok=file:write(F,B),ok=file:sync(F),
                ok=file:close(F),file:rename(Tmp,Path)
            catch C:E->{error,{state_write,C,E}} after file:close(F) end,
            case R of ok->ok; _->file:delete(Tmp),R end;
        {error,R}->{error,{state_write,R}}
    end.
load(P)->case file:read_link_info(P) of
    {error,enoent}->{ok,empty()};
    {ok,#file_info{type=regular,size=N}} when N=< ?MAX_STATE->
        case file:read_file(P) of
            {ok,<<131,80,_/binary>>}->{error,compressed_state_not_supported};
            {ok,B}->try
                {ecdj_state,1,D}=binary_to_term(B,[safe]),
                #{releases:=Rs,tracks:=Ts,feedback:=F,recent:=Recent,policy:=_}=D,
                5=map_size(D),
                true=is_map(Rs) andalso map_size(Rs)=<500,
                true=is_map(Ts) andalso map_size(Ts)=<10000,
                true=is_map(F) andalso map_size(F)=<10000,
                true=is_list(Recent) andalso length(Recent)=<100,
                true=lists:all(fun is_binary/1,Recent),
                maps:foreach(fun(Id,R)->true=is_binary(Id),Id=maps:get(id,R),
                    true=is_binary(maps:get(title,R)),true=is_map(maps:get(license,R)) end,Rs),
                maps:foreach(fun(Id,T)->true=is_binary(Id),Id=maps:get(id,T),
                    true=is_binary(maps:get(title,T)),true=is_binary(maps:get(sha256,T)),
                    true=is_map(maps:get(license,T)),true=is_list(maps:get(tags,T)) end,Ts),
                maps:foreach(fun(Id,#{rating:=V,plays:=PlayCount})->true=is_binary(Id),
                    true=is_integer(V) andalso V>=-2 andalso V=<2,
                    true=is_integer(PlayCount) andalso PlayCount>=0 andalso PlayCount=<1000000000 end,F),
                case maps:get(policy,D) of undefined->ok; LoadedPolicy->{ok,_}=ecai_dj_package:validate(LoadedPolicy) end,
                {ok,D}
            catch _:_->{error,invalid_state} end;
            E->E
        end;
    _->{error,invalid_state_file}
end.
empty()->#{releases=>#{},tracks=>#{},feedback=>#{},recent=>[],policy=>undefined}.
lookup(Id,S)->case maps:find(Id,maps:get(tracks,maps:get(data,S))) of
    {ok,T}->case erm_dj_media:permitted(T,maps:get(opts,S)) of ok->{ok,T}; E->E end;
    error->{error,unknown_track} end.
ordered(M)->[V||{_,V}<-lists:sort(maps:to_list(M))].
private_dir(D)->case filelib:ensure_dir(filename:join(D,"placeholder")) of
    ok->case file:read_link_info(D) of
        {ok,#file_info{type=directory}}->file:change_mode(D,8#700);
        _->{error,unsafe_data_directory}
    end;
    E->E
end.
default_dir()->
    Base=case os:getenv("XDG_DATA_HOME") of
        false->filename:join(os:getenv("HOME","."),".local/share"); V->V end,
    filename:join([Base,"erm","ecdj"]).
terminate(_,S)->case maps:get(job,S,undefined) of
    undefined->ok;
    J->exit(maps:get(pid,J),kill),gen_server:reply(maps:get(from,J),{error,stopped})
end,ok.
code_change(_,S,_)->{ok,S}.

options_map(M) when is_map(M)->M;
options_map(L) when is_list(L)->maps:from_list(L);
options_map(_)->#{}.
