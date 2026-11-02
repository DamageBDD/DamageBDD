%% Local biometric-derived corpus: no raw audio and no generated training takes.
-module(erm_phrase_lab_store).
-include_lib("kernel/include/file.hrl").
-export([validate_model/1, load/2, save/3, insert/2, write_report/2]).
-define(MAX_FILE,8388608).
validate_model(<<"ELS1",Samples:32,N:16,Frames/binary>>)
    when Samples>=400,Samples=<128000,N=:=(Samples+159) div 160,byte_size(Frames)=:=N*76 ->
    try
        Rows=[{R,P,V,K} || <<R:32/float-big,P:32/float-big,V:32/float-big,K:64/binary>> <= Frames],
        true=length(Rows)=:=N,
        lists:foreach(fun({R,P,V,K}) ->
            true=R>=0 andalso R=<1, true=P=:=0.0 orelse (P>=50 andalso P=<400),
            true=V>=0 andalso V=<1,
            Ks=[F || <<F:32/float-big>> <= K], true=length(Ks)=:=16,
            true=lists:all(fun(F)->abs(F)=<0.970001 end,Ks)
        end,Rows), ok
    catch _:_ -> {error,invalid_synthesis_model} end;
validate_model(_) -> {error,invalid_synthesis_model}.
validate_row(#{origin:=human,expected:=A,split:=Split,sample:=Sample,model:=Model,
    speaker_ok:=Speaker,created_at:=Time,id:=Id}=R) ->
    true=maps:size(R)=:=8,
    true=lists:member(A,[unknown|erm_phrase_codec:actions()]),
    true=lists:member(Split,[train,validation,test]),
    true=is_boolean(Speaker) andalso is_integer(Time),
    true=maps:size(Sample)=:=3,
    Check=Sample#{action=>stop_music},ok=erm_phrase_codec:validate_samples([Check,Check,Check]),
    true=Id=:=erm_phrase_codec:fingerprint(Sample),
    case Split of
        train -> true=A=/=unknown andalso Speaker,ok=validate_model(Model);
        _ -> true=Model=:= <<>>
    end, ok.
validate_rows(Rows) ->
    true=is_list(Rows) andalso length(Rows)=<150,
    lists:foreach(fun validate_row/1,Rows),
    Ids=[maps:get(id,R)||R<-Rows],true=length(Ids)=:=length(lists:usort(Ids)),ok.
insert(R,Rows) ->
    try
        ok=validate_row(R),Id=maps:get(id,R),
        false=lists:any(fun(X)->maps:get(id,X)=:=Id end,Rows),
        A=maps:get(expected,R),Split=maps:get(split,R),
        Count=length([ok||#{expected:=B,split:=S}<-Rows,B=:=A,S=:=Split]),
        Limit=case {Split,A} of {train,_}->5;{_,unknown}->20;_->10 end,
        true=Count<Limit,New=Rows++[R],ok=validate_rows(New),{ok,New}
    catch _:_->{error,duplicate_cross_split_invalid_or_full_corpus} end.
load(Path,Binding) ->
    case private_read(Path,?MAX_FILE) of
        {error,enoent}->{ok,[]};
        {ok,<<"ELAB",1,Binding:32/binary,N:32,Rest/binary>>} when N=< ?MAX_FILE ->
            try
                <<Body:N/binary,Hash:32/binary>>=Rest,
                Prefix= <<"ELAB",1,Binding/binary,N:32,Body/binary>>,
                true=crypto:hash(sha256,Prefix)=:=Hash,
                false=case Body of <<131,80,_/binary>>->true;_->false end,
                Rows=binary_to_term(Body,[safe]),ok=validate_rows(Rows),{ok,Rows}
            catch _:_->{error,invalid_lab_corpus} end;
        {ok,_}->{error,invalid_or_different_speaker_device_lab_corpus};
        Error->Error
    end.
save(Path,Binding,Rows) when byte_size(Binding)=:=32 ->
    try
        ok=validate_rows(Rows),Body=term_to_binary(Rows,[deterministic]),
        true=byte_size(Body)< ?MAX_FILE-100,
        Prefix= <<"ELAB",1,Binding/binary,(byte_size(Body)):32,Body/binary>>,
        atomic_write(Path,<<Prefix/binary,(crypto:hash(sha256,Prefix))/binary>>)
    catch C:R->{error,{lab_corpus_save,C,R}} end.
write_report(Path,Report) ->
    try atomic_write(Path,iolist_to_binary(io_lib:format("~tp.~n",[Report])))
    catch C:R->{error,{lab_report_save,C,R}} end.

private_read(Path, Max) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size, mode = Mode, inode = Inode, major_device = Dev}}
            when Size =< Max, Mode band 8#077 =:= 0 ->
            case file:open(Path, [read, binary, raw]) of
                {ok, F} ->
                    try
                        case file:read_file_info(F) of
                            {ok, #file_info{type = regular, inode = Inode, major_device = Dev}} ->
                                case file:read(F, Max+1) of
                                    {ok, B} when byte_size(B) =< Max -> {ok, B};
                                    eof -> {ok, <<>>};
                                    _ -> {error, profile_too_large_or_unreadable}
                                end;
                            _ -> {error, profile_changed_during_open}
                        end
                    after file:close(F) end;
                Error -> Error
            end;
        {ok, _} -> {error, profile_must_be_private_regular_file};
        Error -> Error
    end.

atomic_write(Path, B) ->
    absolute = filename:pathtype(Path),
    Dir = filename:dirname(Path),
    case file:read_link_info(Dir) of
        {error, enoent} ->
            ok = filelib:ensure_dir(filename:join(Dir, "unused")),
            ok = file:change_mode(Dir, 8#700);
        {ok, #file_info{type = directory, mode = Mode}} when Mode band 8#077 =:= 0 -> ok;
        _ -> error(phrase_directory_must_be_private)
    end,
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, #file_info{type = regular, mode = M}} when M band 8#077 =:= 0 -> ok;
        _ -> error(unsafe_phrase_profile_destination)
    end,
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Temp = Path ++ ".tmp." ++ Suffix,
    try
        {ok, F} = file:open(Temp, [write, binary, raw, exclusive]),
        try
            ok = file:change_mode(Temp, 8#600),
            ok = file:write(F, B), ok = file:sync(F)
        after file:close(F) end,
        ok = file:rename(Temp, Path), ok
    after _ = file:delete(Temp) end.
