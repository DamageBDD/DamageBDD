%% Deterministic native Piper discovery. Explicit settings never fall back.
-module(erm_tts_paths).
-include_lib("kernel/include/file.hrl").
-export([resolve/1]).
resolve(O) ->
    Fallback = case maps:get(model_source,O,auto) of catalog->undefined;_->env("PIPER_MODEL") end,
    Model = selected(model,O,Fallback),
    Json = case Model of undefined->undefined;M when is_list(M)->M++".json";_->undefined end,
    Candidates = #{binary=>port_candidates(),model=>[],config=>[],
                   espeak_data=>data_candidates(O),player=>which("mpv")},
    Values = #{binary=>selected(binary,O,undefined),model=>Model,
               config=>selected(config,O,Json),espeak_data=>selected(espeak_data,O,undefined),
               player=>selected(player,O,undefined)},
    {Paths,Errors}=lists:foldl(fun(K,{Ps,Es})->
        case choose(K,maps:get(K,Values),maps:get(K,Candidates)) of
            {ok,P}->{Ps#{K=>P},Es};
            {error,E}->{Ps,Es#{K=>E}}
        end
    end,{#{},#{}},[binary,model,config,espeak_data,player]),
    #{paths=>Paths,errors=>Errors}.
selected(K,O,Default)->case maps:find(K,O) of
    error->Default;
    {ok,V}->text(V)
end.
text(V)->try unicode:characters_to_list(V) of
    S when is_list(S),S=/=[]->case lists:member(0,S) of true->invalid_path;false->S end;
    _->invalid_path
catch _:_ ->invalid_path end.
env(K)->case os:getenv(K) of false->undefined;""->undefined;V->text(V) end.
choose(K,undefined,[])->{error,#{reason=>missing_setting,key=>K}};
choose(K,undefined,Ps)->discover(K,Ps,[]);
choose(K,P,_)->case check(K,P) of ok->{ok,P};{error,R}->{error,#{path=>P,reason=>R}} end.
discover(_K,[],Failures)->{error,#{reason=>not_found,candidates=>lists:reverse(Failures)}};
discover(K,[P|Ps],Failures)->case check(K,P) of
    ok->{ok,P};{error,R}->discover(K,Ps,[#{path=>P,reason=>R}|Failures]) end.
check(_,P) when not is_list(P)->{error,invalid_path};
check(K,P)->case filename:pathtype(P) of
    absolute->check_file(K,P);
    _->{error,absolute_path_required}
end.
check_file(K,P)->case file:read_file_info(P) of
    {ok,#file_info{type=directory,access=A}} when K=:=espeak_data ->
        case A=:=read orelse A=:=read_write of
            true->readable(filename:join(P,"phontab"));false->{error,eacces} end;
    {ok,#file_info{type=regular,mode=Mode}} when K=:=binary;K=:=player ->
        case Mode band 8#111 of 0->{error,not_executable};_->ok end;
    {ok,#file_info{type=regular}} when K=:=model;K=:=config ->readable(P);
    {ok,_}->{error,wrong_file_type};
    {error,R}->{error,R}
end.
readable(P)->case file:open(P,[read,binary,raw]) of
    {ok,F}->file:close(F),ok;
    {error,R}->{error,R}
end.
port_candidates()->
    %% Resolve from the loaded application's installation, never cwd/_build guesses.
    case code:priv_dir(erm) of
        D when is_list(D)->[filename:join(D,"erm_tts_port")];
        _->case code:which(erm_tts) of
            P when is_list(P)->[filename:join([filename:dirname(filename:dirname(P)),"priv","erm_tts_port"])];
            _->[] end
    end.
which(Name)->case os:find_executable(Name) of false->[];P->[filename:absname(P)] end.
data_candidates(O)->
    Prefix=selected(piper_prefix,O,env("PIPER_PREFIX")),
    PrefixDirs=case Prefix of P when is_list(P)->[filename:join([P,"share","espeak-ng-data"])];_->[] end,
    HomeDirs=case os:getenv("HOME") of false->[];H->[filename:join([H,".local","share","erm","piper","share","espeak-ng-data"])] end,
    PrefixDirs++HomeDirs++["/opt/piper/share/espeak-ng-data",
        "/usr/local/share/espeak-ng-data","/usr/share/espeak-ng-data"] .
