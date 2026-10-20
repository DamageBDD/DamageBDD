%% Public knowledge reads plus authenticated owner-only funded shard views.
-module(ecai_knowledge_http).
-export([trails/0, init/2]).

trails() ->
    [trails:trail(Path, ?MODULE, #{action => Action}, #{}) || {Path,Action} <- [
        {"/ecai/knowledge/search",search}, {"/ecai/knowledge/source",source},
        {"/ecai/knowledge/status",status}]].

init(Req0, #{action := Action} = State) ->
    try
        Method = cowboy_req:method(Req0),
        case {Action,Method} of
            {status,<<"GET">>} -> process_request(Action,Req0,State,#{});
            {search,<<"GET">>} -> process_request(Action,Req0,State,maps:from_list(cowboy_req:parse_qs(Req0)));
            {A,<<"POST">>} when A =:= search; A =:= source ->
                case cowboy_req:header(<<"content-type">>,Req0,<<>>) of
                    <<"application/json",_/binary>> ->
                        case cowboy_req:read_body(Req0,#{length => 16384,period => 5000}) of
                            {ok,Bytes,Req} when byte_size(Bytes) =< 16384 ->
                                case decode(Bytes) of
                                    {ok,Body} -> process_request(Action,Req,State,Body);
                                    error -> reply(Req,State,400,#{error => invalid_json})
                                end;
                            {_,_,Req} -> reply(Req,State,413,#{error => request_too_large})
                        end;
                    _ -> reply(Req0,State,415,#{error => json_required})
                end;
            _ -> reply(Req0,State,405,#{error => method_not_allowed})
        end
    catch _:_ -> reply(Req0,State,503,#{error => knowledge_unavailable}) end.

process_request(Action,Req,State,Body) ->
    case principal(Req) of
        {error,Why} -> reply(Req,State,401,#{error => Why});
        {ok,Principal} ->
            Result = case Action of
                status -> {ok,ecai_knowledge:status(Principal)};
                search ->
                    ecai_knowledge:search(maps:get(<<"q">>,Body,<<>>),
                        #{limit => limit(maps:get(<<"limit">>,Body,10)),principal => Principal});
                source ->
                    case source_ref(maps:get(<<"source_ref">>,Body,#{})) of
                        {ok,Ref} -> ecai_knowledge:source(Ref,Principal);
                        Error -> Error
                    end
            end,
            case Result of
                {ok,Data} -> reply(Req,State,200,Data#{ok => true});
                {error,Why} -> reply(Req,State,error_status(Why),#{ok => false,error => Why})
            end
    end.

principal(Req) ->
    %% Explicit bad credentials must not silently downgrade to guest reads.
    Auth = try
        case cowboy_req:header(<<"authorization">>,Req,undefined) of
            undefined -> damage_auth:authenticate(Req,#{});
            <<"Bearer ",Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
                damage_auth:resolve_oauth(Token,#{});
            _ -> {error,invalid_credentials}
        end
    catch _:_ -> {error,unavailable} end,
    case Auth of
        {ok,A} ->
            case damage_auth:authenticated_account(A) of
                {ok,Owner} when is_binary(Owner) -> {ok,Owner};
                _ -> {ok,undefined}
            end;
        _ ->
            case cowboy_req:header(<<"authorization">>,Req,undefined) of
                undefined -> {ok,undefined};
                _ -> {error,invalid_credentials}
            end
    end.

source_ref(#{<<"index">> := Id, <<"doc_id">> := DocId} = M) when
    is_binary(Id), byte_size(Id)>0, byte_size(Id)=<128 ->
    ValidId = (is_integer(DocId) andalso DocId>0) orelse
              (is_binary(DocId) andalso byte_size(DocId)>0 andalso byte_size(DocId)=<4096),
    Allowed = [<<"index">>,<<"doc_id">>,<<"sha256">>,<<"shard_ordinal">>],
    Sha = maps:get(<<"sha256">>,M,null),
    Ord = maps:get(<<"shard_ordinal">>,M,null),
    ValidSha = Sha =:= null orelse (is_binary(Sha) andalso byte_size(Sha) =:= 64 andalso
        lists:all(fun(C)->(C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
                  binary_to_list(Sha))),
    ValidOrd = Ord =:= null orelse (is_integer(Ord) andalso Ord >= 0),
    case ValidId andalso ValidSha andalso ValidOrd andalso
         lists:all(fun(K)->lists:member(K,Allowed) end,maps:keys(M)) of
        true ->
            Optional = maps:from_list([{A,V} || {B,A} <- [
                {<<"sha256">>,sha256},{<<"shard_ordinal">>,shard_ordinal}],
                {ok,V} <- [maps:find(B,M)], V =/= null]),
            {ok,Optional#{index => Id,doc_id => DocId}};
        false -> {error,invalid_source_reference}
    end;
source_ref(_) -> {error,invalid_source_reference}.
limit(B) when is_binary(B) -> try binary_to_integer(B) catch _:_ -> 10 end;
limit(N) -> N.
decode(Bytes) -> try jsx:decode(Bytes,[return_maps]) of
    M when is_map(M) -> {ok,M}; _ -> error catch _:_ -> error end.
error_status(source_not_found) -> 404;
error_status(source_not_retained) -> 404;
error_status(source_hash_mismatch) -> 409;
error_status(source_version_changed) -> 409;
error_status(_) -> 400.
reply(Req,State,Code,Data) ->
    Headers = #{<<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>},
    Bytes = jsx:encode(ecai_index_job_codec:externalize(Data)),
    {ok,cowboy_req:reply(Code,Headers,Bytes,Req),State}.
