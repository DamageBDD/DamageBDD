%% Feature files are the only catalog records. The deployed, administrator-owned
%% directory is an execution allowlist, not an upload directory. Tags never grant authority.
-module(damage_verification_catalog).
-include_lib("kernel/include/file.hrl").
-export([list/0, get/1, parse/2, from_ast/3, placeholders/1, input_fields/2,
         validate_inputs/3, fingerprint/1, public/1, sha256/1]).
-define(MAX_BYTES, 65536).
-define(MAX_FILES, 200).

list() ->
    Root = case application:get_env(damage, verification_feature_dir) of
        {ok,Configured} -> Configured;
        undefined -> filename:join(code:priv_dir(damage), "features/verification")
    end,
    case walk(Root, "", 0) of
        {ok, Paths} when length(Paths) =< ?MAX_FILES ->
            {ok, [read_feature(Root, P) || P <- lists:sort(Paths)]};
        {ok, _} -> {error, catalog_limit};
        Error -> Error
    end.
get(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    case list() of
        {ok, Entries} ->
            case [E || E <- Entries, maps:get(id,E) =:= Id] of
                [#{error := _}] -> {error, invalid_feature};
                [E] -> {ok,E};
                _ -> {error, not_found}
            end;
        Error -> Error
    end;
get(_) -> {error, not_found}.

%% Do not follow symlinks, recurse without a bound, or publish absolute paths.
walk(_, _, Depth) when Depth > 6 -> {error, catalog_depth};
walk(Root, Rel, Depth) ->
    Dir = filename:join(Root,Rel),
    case file:read_link_info(Dir) of
        {ok,#file_info{type=directory}} ->
            case file:list_dir(Dir) of
                {ok,Names} when length(Names) =< ?MAX_FILES ->
                    walk_names(lists:sort(Names),Root,Rel,Depth,[]);
                {ok,_} -> {error,catalog_limit};
                _ -> {error,catalog_unavailable}
            end;
        _ -> {error,catalog_unavailable}
    end.
walk_names([],_,_,_,Acc) -> {ok,lists:append(lists:reverse(Acc))};
walk_names([Name|Rest],Root,Rel,Depth,Acc) ->
    %% filename:join("", Name) creates "/Name", not a relative child path.
    %% Keep first-level paths relative so the next join cannot discard Root.
    Sub = case Rel of
        "" -> Name;
        _ -> filename:join(Rel,Name)
    end,
    Part = case file:read_link_info(filename:join(Root,Sub)) of
        {ok,#file_info{type=directory}} -> walk(Root,Sub,Depth+1);
        {ok,#file_info{type=regular,size=Size}} when Size =< ?MAX_BYTES ->
            case filename:extension(Name) of ".feature" -> {ok,[Sub]}; _ -> {ok,[]} end;
        {ok,#file_info{type=regular}} ->
            case filename:extension(Name) of ".feature" -> {error,feature_too_large}; _ -> {ok,[]} end;
        _ -> {ok,[]}
    end,
    case Part of
        {ok,Found} ->
            Next = [Found|Acc],
            case lists:sum([length(X)||X<-Next]) =< ?MAX_FILES of
                true -> walk_names(Rest,Root,Rel,Depth,Next);
                false -> {error,catalog_limit}
            end;
        Error -> Error
    end.
read_feature(Root,Rel) ->
    Id = sha256(unicode:characters_to_binary(Rel)),
    case file:read_file(filename:join(Root,Rel)) of
        {ok,Source} when byte_size(Source) =< ?MAX_BYTES ->
            case parse(Id,Source) of
                {ok,E} -> E;
                {error,Reason} -> #{id=>Id,title=>unicode:characters_to_binary(filename:basename(Rel)),
                    error=>Reason,available=>false}
            end;
        _ -> #{id=>Id,title=><<"Unavailable feature">>,error=>read_failed,available=>false}
    end.
parse(Id,Source) when is_binary(Source), byte_size(Source) =< ?MAX_BYTES ->
    case unicode:characters_to_binary(Source,utf8,utf8) of
        Source ->
            try egherkin:parse(Source) of
                {ok,AST} -> from_ast(Id,Source,AST);
                AST when is_tuple(AST),tuple_size(AST)=:=6 -> from_ast(Id,Source,AST);
                _ -> {error,gherkin_syntax}
            catch _:_ -> {error,parser_unavailable} end;
        _ -> {error,invalid_utf8}
    end;
parse(_,_) -> {error,feature_too_large}.
from_ast(Id,Source,{_Line,Tags,Name,Description,Background,Scenarios}) when
    is_list(Scenarios), Scenarios =/= [] ->
    try
        Parsed = [scenario(S) || S <- Scenarios],
        BG = steps(Background),
        AllSteps = BG ++ lists:append([maps:get(steps,S) || S<-Parsed]),
        true = length(AllSteps)>0 andalso length(AllSteps)=<512,
        {ok,#{id=>Id,title=>first_line(bin(Name)),description=>description(Description),
              tags=>tags(Tags),scenarios=>Parsed,background=>BG,source=>Source,
              sha256=>sha256(Source),inputs=>placeholders(AllSteps),available=>true}}
    catch _:_ -> {error,unsupported_structure} end;
from_ast(_,_,_) -> {error,empty_feature}.
scenario([S]) -> scenario(S);
scenario(T) when is_tuple(T) ->
    [Line,Name|Tail] = tuple_to_list(T),
    true = is_integer(Line),
    {Ts,Body}=case Tail of [Only]->{[],Only}; [T0|Rest]->{T0,Rest} end,
    Ss=steps(Body), true=Ss=/=[],
    #{line=>Line,title=>first_line(bin(Name)),tags=>tags(Ts),steps=>Ss}.
steps({Line,K,Body}) when is_integer(Line),is_binary(K) -> step_or_children(Line,K,Body,[]);
steps({Line,K,Body,Args}=T) when is_integer(Line),is_binary(K) ->
    case keyword(K) of true -> [#{line=>Line,keyword=>K,text=>body_text(Body),args=>{Body,Args}}];
        false -> steps(tl(tuple_to_list(T))) end;
steps({datatable,_}) -> [];
steps(L) when is_list(L) -> lists:append([steps(X)||X<-L]);
steps(T) when is_tuple(T) -> steps(tuple_to_list(T));
steps(_) -> [].
step_or_children(Line,K,Body,Args) ->
    case keyword(K) of true->[#{line=>Line,keyword=>K,text=>body_text(Body),args=>{Body,Args}}]; false->steps(Body) end.
keyword(K) -> lists:member(K,[<<"Given">>,<<"When">>,<<"Then">>,<<"And">>,<<"But">>,<<"*">>]).
tags(Ts) when is_list(Ts) -> lists:usort(lists:append([tag(T)||T<-Ts]));
tags(_) -> [].
tag(B) when is_binary(B) -> [string:trim(B,leading,"@")];
tag({_,B}) when is_binary(B) -> tag(B);
tag(L) when is_list(L) -> case io_lib:printable_list(L) of true->tag(bin(L));false->tags(L) end;
tag(_) -> [].
description(B) when is_binary(B) -> string:trim(B);
description(L) when is_list(L) ->
    case lists:all(fun is_integer/1,L) of
        true -> string:trim(bin(L));
        false -> try string:trim(iolist_to_binary(lists:join(<<"\n">>,[bin(X)||X<-L])))
                 catch _:_ -> <<>> end
    end;
description(_) -> <<>>.
body_text(B) when is_binary(B) -> B;
body_text(L) when is_list(L) ->
    case lists:all(fun is_integer/1,L) of
        true -> bin(L);
        false -> iolist_to_binary(lists:join(<<" ">>,[B||B<-L,is_binary(B)]))
    end;
body_text(_) -> <<>>.
first_line(B) -> hd(binary:split(B,<<"\n">>)).
bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(_) -> <<>>.

%% Only ordinary Mustache variables in executable text become inputs. Sections,
%% partials and triple braces are not an input schema. They remain runner concerns.
placeholders(Steps) ->
    Text = iolist_to_binary(lists:join(<<"\n">>,[variables_text(S) || S<-Steps])),
    case re:run(Text,<<"(?<!\\{)\\{\\{\\s*([A-Za-z][A-Za-z0-9_]{0,63})\\s*\\}\\}(?!\\})">>,
        [global,{capture,[1],binary}]) of
        {match,Ms} -> lists:usort([K || [K]<-Ms]);
        nomatch -> []
    end.
variables_text(S) when is_map(S) -> variables_text({maps:get(text,S,<<>>),maps:get(args,S,[])});
variables_text(B) when is_binary(B) -> B;
variables_text(L) when is_list(L) ->
    case lists:all(fun is_integer/1,L) of
        true -> bin(L);
        false -> lists:join(<<"\n">>,[variables_text(X)||X<-L])
    end;
variables_text(T) when is_tuple(T) -> variables_text(tuple_to_list(T));
variables_text(_) -> <<>>.
public(E) ->
    E1=maps:without([source,inputs],E),
    Clean=fun(S)->maps:without([args],S) end,
    E1#{background=>[Clean(S)||S<-maps:get(background,E,[])],
        scenarios=>[S#{steps=>[Clean(X)||X<-maps:get(steps,S,[])]}||S<-maps:get(scenarios,E,[])]}.
input_fields(Keys,#{entries:=Entries}) ->
    [field(K,maps:get(K,Entries,undefined)) || K<-Keys].
field(K,undefined) -> #{key=>K,label=>label(K),editable=>allowed_input(K),configured=>false,
                       sensitive=>false,value=><<>>};
field(K,E) ->
    Sensitive=maps:get(sensitive,E,true)=:=true,
    Locked=maps:get(locked,E,false)=:=true orelse maps:get(inheritance,E,default)=:=locked,
    Editable=allowed_input(K) andalso not Sensitive andalso not Locked,
    #{key=>K,label=>label(K),editable=>Editable,configured=>true,sensitive=>Sensitive,
      value=>case Sensitive of true-><<>>; false->scalar(maps:get(value,E,<<>>)) end}.
label(K) -> iolist_to_binary(string:replace(K,<<"_">>,<<" ">>,all)).
scalar(B) when is_binary(B) -> B;
scalar(N) when is_integer(N) -> integer_to_binary(N);
scalar(true) -> <<"true">>; scalar(false) -> <<"false">>; scalar(_) -> <<>>.
allowed_input(K) ->
    %% Runtime controls and identities are never browser-editable. New inputs
    %% use a non-reserved variable name and an ordinary context placeholder.
    re:run(K,<<"^(verification_[a-z][a-z0-9_]*|input_[a-z][a-z0-9_]*)$">>,[{capture,none}]) =:= match
    andalso re:run(K,<<"(secret|password|passphrase|token|private|rune|macaroon|nsec)">>,
        [caseless,{capture,none}]) =:= nomatch.
validate_inputs(Keys,Inputs,Snapshot) when is_map(Inputs), map_size(Inputs)=<32 ->
    Fields=input_fields(Keys,Snapshot),
    Editable=[maps:get(key,F)||F<-Fields,maps:get(editable,F)],
    Required=[maps:get(key,F)||F<-Fields,not maps:get(configured,F)],
    Valid=lists:all(fun({K,V})->lists:member(K,Editable) andalso valid_value(V) end,maps:to_list(Inputs)),
    Missing=[K||K<-Required,not maps:is_key(K,Inputs)],
    case {Valid,Missing} of
        {true,[]} -> {ok,Inputs};
        {true,_} -> {error,context_required};
        _ -> {error,invalid_inputs}
    end;
validate_inputs(_,_,_) -> {error,invalid_inputs}.
valid_value(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<1024 ->
    unicode:characters_to_binary(B,utf8,utf8)=:=B andalso
      re:run(B,<<"[\\x00-\\x1f\\x7f]">>,[{capture,none}])=:=nomatch andalso
      binary:match(B,<<34>>)=:=nomatch andalso
      binary:match(B,<<"{{">>)=:=nomatch;
valid_value(_) -> false.
fingerprint(#{proofs:=P}) -> sha256(term_to_binary(P,[deterministic]));
fingerprint(_) -> error(context_proofs_required).
sha256(B) -> string:lowercase(binary:encode_hex(crypto:hash(sha256,B))).
