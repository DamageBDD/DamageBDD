%% Same-origin, authenticated API. No caller-selected paths, source, role,
%% account owner, action callback, executable module or secret values.
-module(damage_verification_http).
-export([trails/0,init/2,same_origin/2,decode/1]).
trails()->
    [trails:trail(P,?MODULE,#{action=>A},#{M=>#{tags=>["Verification"],produces=>["application/json"]}})
     ||{P,A,M}<-[{"/api/verification/catalog",catalog,get},
        {"/api/verification/features/:id",feature,get},
        {"/api/verification/preview",preview,post},
        {"/api/verification/run",run,post},
        {"/api/verification/jobs/:id",job,get},
        {"/api/verification/history",history,get}]].
init(Req0,#{action:=Action}=Opts)->
    Req=try
        case damage_auth:authenticate(Req0,#{action=>verification}) of
            {ok,Auth}->
                case damage_verification_service:authorized(Auth) of
                    true->dispatch(Action,Req0,damage_verification_runner:principal(Auth));
                    false->json(403,#{error=>managed_account_required},Req0)
                end;
            _->json(401,#{error=>authentication_required},Req0)
        end
    catch _:_ ->json(503,#{error=>verification_unavailable},Req0) end,
    {ok,Req,Opts}.
dispatch(Action,Req,Auth)->
    Method=cowboy_req:method(Req),
    Expected=case lists:member(Action,[preview,run]) of true-><<"POST">>;false-><<"GET">> end,
    case Method=:=Expected of
        false->cowboy_req:reply(405,(headers())#{<<"allow">>=>Expected},<<>>,Req);
        true when Method=:=<<"POST">> ->
            case csrf(Req) andalso json_type(cowboy_req:header(<<"content-type">>,Req,<<>>)) of
                true->body(Action,Req,Auth);
                false->json(403,#{error=>same_origin_json_required},Req)
            end;
        true->get(Action,Req,Auth)
    end.
get(catalog,Req,_)->
    case damage_verification_catalog:list() of
        {ok,Es}->json(200,#{features=>[damage_verification_catalog:public(E)||E<-Es],
            execution_scope=><<"Deployed features; authorization is checked again before execution.">>},Req);
        E->respond(E,Req)
    end;
get(feature,Req,Auth)->
    case damage_verification_catalog:get(cowboy_req:binding(id,Req)) of
        {ok,E}->
            case damage_context:public_effective_snapshot(maps:get(public_key,Auth)) of
                {ok,Snapshot}->
                    Catalog=damage_bdd_catalog:snapshot(Auth),
                    Validation=damage_bdd_validator:validate(maps:get(source,E),Catalog),
                    Body=(damage_verification_catalog:public(E))#{source=>maps:get(source,E),
                        fields=>damage_verification_catalog:input_fields(maps:get(inputs,E),Snapshot),
                        runnable=>maps:get(valid,Validation,false),
                        validation=>maps:with([valid,diagnostics,errors],Validation)},
                    json(200,Body,Req);
                _->json(503,#{error=>context_unavailable},Req)
            end;
        E->respond(E,Req)
    end;
get(job,Req,Auth)->respond(damage_verification_service:status(cowboy_req:binding(id,Req),Auth),Req);
get(history,Req,Auth)->
    case damage_verification_service:history(Auth) of {ok,Js}->json(200,#{jobs=>Js},Req);E->respond(E,Req) end.
body(Action,Req0,Auth)->
    case read_body(Req0,[],0) of
        {error,Req}->json(413,#{error=>request_too_large},Req);
        {ok,Bytes,Req}->
            case decode(Bytes) of
                {ok,M}->post(Action,M,Req,Auth);
                _->json(400,#{error=>invalid_json},Req)
            end
    end.
post(preview,#{<<"feature_id">>:=Id,<<"sha256">>:=Hash,<<"inputs">>:=Inputs,
               <<"request_id">>:=RequestId}=M,Req,Auth) when map_size(M)=:=4->
    respond(damage_verification_service:preview(Id,Hash,Inputs,RequestId,Auth),Req);
post(run,#{<<"preview_id">>:=Id,<<"approved">>:=true}=M,Req,Auth) when map_size(M)=:=2->
    respond(damage_verification_service:approve(Id,Auth),Req);
post(_,_,Req,_)->json(400,#{error=>invalid_request},Req).
read_body(Req0,Acc,Size)->
    case cowboy_req:read_body(Req0,#{length=>4096,period=>5000}) of
        {Flag,Part,Req} when Flag=:=ok;Flag=:=more->
            N=Size+byte_size(Part),
            case {N=<16384,Flag} of
                {false,_}->{error,Req};
                {true,ok}->{ok,iolist_to_binary(lists:reverse([Part|Acc])),Req};
                {true,more}->read_body(Req,[Part|Acc],N)
            end
    end.
decode(B)->try jsx:decode(B,[return_maps]) of M when is_map(M)->{ok,M};_->{error,bad_json}
    catch _:_->{error,bad_json} end.
csrf(Req)->
    Header=cowboy_req:header(<<"x-damage-verification">>,Req),
    Site=cowboy_req:header(<<"sec-fetch-site">>,Req),
    Expected=application:get_env(damage,verification_origin,
        cowboy_req:uri(Req,#{path=><<>>,qs=><<>>})),
    Origin=cowboy_req:header(<<"origin">>,Req),
    Header=:=<<"1">> andalso Site=/=<<"cross-site">> andalso case Origin of
        undefined->case cowboy_req:header(<<"authorization">>,Req,<<>>) of
            <<"Bearer ",Token/binary>> when byte_size(Token)>0->true;_->false end;
        _->same_origin(Origin,Expected)
    end.
same_origin(A,B)->
    try OA=origin(A),OA=/=invalid andalso OA=:=origin(B) catch _:_ ->false end.
origin(U) when is_list(U)->origin(unicode:characters_to_binary(U));
origin(U)->
    case uri_string:parse(U) of
        #{scheme:=S,host:=H}=M when S=:=<<"http">>;S=:=<<"https">> ->
            Invalid=maps:is_key(userinfo,M) orelse maps:is_key(query,M) orelse maps:is_key(fragment,M)
                orelse not lists:member(maps:get(path,M,<<>>),[<<>>,<<"/">>]),
            case Invalid of true->invalid;false->{S,string:lowercase(H),maps:get(port,M,
                case S of <<"https">>->443;_->80 end)} end;
        _->invalid
    end.
json_type(T)->hd(binary:split(string:lowercase(T),<<";">>))=:=<<"application/json">>.
respond({ok,M},Req)->json(200,M,Req);
respond({error,R},Req)->json(error_code(R),#{error=>R},Req).
error_code(not_found)->404;
error_code(forbidden)->403;
error_code(verification_busy)->429;
error_code(approval_expired)->409;
error_code(approval_consumed)->409;
error_code(preview_not_ready)->409;
error_code(idempotency_conflict)->409;
error_code(_)->400.
headers()->#{<<"content-type">>=><<"application/json; charset=utf-8">>,
    <<"cache-control">>=><<"no-store">>,<<"referrer-policy">>=><<"no-referrer">>,
    <<"x-content-type-options">>=><<"nosniff">>}.
json(Code,Body,Req)->cowboy_req:reply(Code,headers(),jsx:encode(Body),Req).
