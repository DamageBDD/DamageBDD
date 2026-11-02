%% Only the speech/LLM models are fixtures. HTTP, auth, codecs and clients are real.
-module(nosternity_voice_provider_fixture).
-export([init/2]).
init(Req0, #{table := T} = State) ->
    Path=cowboy_req:path(Req0),
    {Body,Req}=case Path of
        <<"/inference">> -> parts(Req0,#{});
        _ -> {ok,B,R}=cowboy_req:read_body(Req0),{jsx:decode(B,[return_maps]),R}
    end,
    ets:insert(T,{Path,Body}),
    case ets:lookup(T,mode) of
        [{mode,wait}] -> [{notify,Parent}]=ets:lookup(T,notify),Parent!{provider_started,self()},receive proceed->ok after 5000->ok end;
        _ -> ok
    end,
    {Code,Response}=case ets:lookup(T,mode) of
        [{mode,error}] -> {500,#{error=><<"private-provider-error">>}};
        [{mode,cleanup_error}] when Path=:=<<"/api/generate">> -> {500,#{error=><<"private-provider-error">>}};
        _ when Path=:=<<"/inference">> -> {200,#{text=><<"hello voice world">>}};
        _ -> {200,#{response=><<"Hello, voice world.">>,done=>true}}
    end,
    {ok,cowboy_req:reply(Code,#{<<"content-type">>=><<"application/json">>},jsx:encode(Response),Req),State}.
parts(Req,Acc) ->
    case cowboy_req:read_part(Req) of
        {done,R} -> {Acc,R};
        {ok,H,R} ->
            Name=case cow_multipart:form_data(H) of {data,N}->N;{file,N,_,_}->N end,
            {Data,R1}=part_body(R,[]),parts(R1,Acc#{Name=>Data})
    end.
part_body(R,Acc) -> case cowboy_req:read_part_body(R) of
    {ok,B,R1}->{iolist_to_binary(lists:reverse([B|Acc])),R1};
    {more,B,R1}->part_body(R1,[B|Acc]) end.
