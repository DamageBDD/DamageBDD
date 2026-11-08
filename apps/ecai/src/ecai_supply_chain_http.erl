%% Managed workspaces retain bearer auth. Public demo routes only access temporary
%% cookie-isolated ETS workspaces; they never resolve or fall back to an account.
-module(ecai_supply_chain_http).
-export([trails/0,init/2,authenticate/2,public_guard/4]).
trails() ->
    [trail("/ecai/supply-chain",state,[get]),
     trail("/ecai/supply-chain/reset",reset,[post]),
     trail("/ecai/supply-chain/event",event,[post]),
     trail("/ecai/supply-chain/plan",plan,[post]),
     trail("/ecai/supply-chain/approve",approve,[post]),
     trail("/ecai/supply-chain/benchmark",benchmark,[post]),
     trail("/ecai/supply-chain/evidence",evidence,[get]),
     public_trail("/ecai/supply-chain/public",state,[get]),
     public_trail("/ecai/supply-chain/public/reset",reset,[post]),
     public_trail("/ecai/supply-chain/public/event",event,[post]),
     public_trail("/ecai/supply-chain/public/plan",plan,[post]),
     public_trail("/ecai/supply-chain/public/approve",approve,[post]),
     public_trail("/ecai/supply-chain/public/benchmark",benchmark,[post]),
     public_trail("/ecai/supply-chain/public/evidence",evidence,[get])].
trail(Path,Action,Methods) -> trails:trail(Path,?MODULE,#{action => Action,methods => Methods},
    maps:from_list([{M,#{tags => ["Supply Chain Recovery Lab"],produces => ["application/json"]}} || M <- Methods])).
public_trail(Path,Action,Methods) -> trails:trail(Path,?MODULE,#{action => Action,methods => Methods,access => public},
    maps:from_list([{M,#{tags => ["Public Supply Chain Demo"],produces => ["application/json"]}} || M <- Methods])).
init(Req,#{action := Action,methods := Methods}=State) ->
    Method=cowboy_req:method(Req),Allowed=[string:uppercase(atom_to_binary(M,utf8)) || M <- Methods],
    case lists:member(Method,Allowed) of
        false -> respond(405,#{ok => false,error => method_not_allowed},
            cowboy_req:set_resp_header(<<"allow">>,lists:join(<<", ">>,Allowed),Req),State);
        true -> case maps:get(access,State,managed) of
            public -> public_route(Action,Method,Req,State);
            managed -> managed_route(Action,Method,Req,State)
        end
    end.
managed_route(Action,Method,Req,State) ->
        case authenticate(Req,Method) of
            {error,Why} -> respond(401,#{ok => false,error => Why},Req,State);
            {ok,Owner} -> case ecai_supply_chain_srv:enabled() of
                false -> result({error,feature_disabled},Req,State);
                true -> route(Action,Method,Owner,Req,State)
            end
        end.
authenticate(Req,Method) ->
    try
        case cowboy_req:header(<<"sec-fetch-site">>,Req,<<>>) of
            <<"cross-site">> -> {error,cross_site_rejected};
            _ -> case cowboy_req:header(<<"authorization">>,Req,<<>>) of
                <<"Bearer ",Token/binary>> when byte_size(Token)>=10,byte_size(Token)=<8192 -> actor(damage_auth:resolve_oauth(Token,#{}));
                <<>> when Method=:= <<"GET">> -> actor(damage_auth:authenticate(Req,#{}));
                _ -> {error,explicit_bearer_required}
            end
        end
    catch _:_ -> {error,auth_unavailable} end.
actor({ok,#{auth_mode := custodial,authenticated := true}=Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok,Owner} when is_binary(Owner),byte_size(Owner)>0 -> {ok,Owner};
        _ -> {error,authenticated_account_required}
    end;
actor(_) -> {error,managed_account_required}.
%% A non-simple header is mandatory even for bootstrap; no CORS is offered.
%% Reject sibling-site requests too, and check Origin independently of Fetch Metadata.
public_guard(Site,Origin,Expected,Header) ->
    case (Site=:= <<>> orelse Site=:= <<"same-origin">> orelse Site=:= <<"none">>)
         andalso (Origin=:=undefined orelse Origin=:=Expected)
         andalso Header=:= <<"1">> of
        true -> ok;
        false -> {error,public_origin_rejected}
    end.
public_route(Action,Method,Req,State) ->
    case ecai_supply_chain_srv:enabled() andalso application:get_env(ecai,supply_chain_public_enabled,true)=:=true of
        false -> result({error,feature_disabled},Req,State);
        true ->
            Expected=public_origin(Req),
            Guard=public_guard(cowboy_req:header(<<"sec-fetch-site">>,Req,<<>>),
                cowboy_req:header(<<"origin">>,Req),Expected,
                cowboy_req:header(<<"x-ecai-lab-request">>,Req,<<>>)),
            case Guard of
                {error,Why} -> respond(403,#{ok => false,error => Why},Req,State);
                ok -> public_session(Action,Method,Req,State)
            end
    end.
%% TLS termination may need a configured external origin. Never trust arbitrary
%% X-Forwarded-* headers for CSRF policy or cookie security.
public_origin(Req) ->
    case application:get_env(ecai,supply_chain_public_origin,undefined) of
        Origin when is_binary(Origin),byte_size(Origin)>0 -> Origin;
        _ -> iolist_to_binary(cowboy_req:uri(Req,#{path => undefined,qs => undefined}))
    end.
public_secure(Req) ->
    case public_origin(Req) of <<"https://",_/binary>> -> true;_ -> false end.
public_session(Action,Method,Req0,State) ->
    try
        Cookies=cowboy_req:parse_cookies(Req0),
        Token=proplists:get_value(<<"ecai_sc_demo">>,Cookies,undefined),
        {Peer,_Port}=cowboy_req:peer(Req0),
        Create=Action=:=state andalso Method=:= <<"GET">>,
        case ecai_supply_chain_srv:guest_session(Token,Peer,Create,Action) of
            {ok,Owner,NewToken,TTL} ->
                Req=cowboy_req:set_resp_cookie(<<"ecai_sc_demo">>,NewToken,Req0,
                    #{path => <<"/ecai/supply-chain/public">>,http_only => true,same_site => strict,
                      secure => public_secure(Req0),max_age => TTL}),
                route(Action,Method,Owner,Req,State);
            {error,Why} -> result({error,Why},Req0,State)
        end
    catch
        exit:_ -> result({error,service_unavailable},Req0,State);
        error:badarg -> respond(400,#{ok => false,error => invalid_guest_cookie},Req0,State)
    end.
route(Action,<<"GET">>,Owner,Req,State) -> result(call(Action,Owner,#{}),Req,State);
route(Action,<<"POST">>,Owner,Req0,State) ->
    CT=string:lowercase(string:trim(hd(binary:split(cowboy_req:header(<<"content-type">>,Req0,<<>>),<<";">>)))),
    case CT of
        <<"application/json">> ->
            case read_body(Req0,[],0,erlang:monotonic_time(millisecond)+5000) of
                {ok,Body,Req} -> result(call(Action,Owner,Body),Req,State);
                {error,Code,Why,Req} -> respond(Code,#{ok => false,error => Why},Req,State)
            end;
        _ -> respond(415,#{ok => false,error => json_required},Req0,State)
    end.
read_body(Req0,Acc,N,Deadline) ->
    Remaining=Deadline-erlang:monotonic_time(millisecond),
    case Remaining>0 of
        false -> {error,408,body_timeout,Req0};
        true ->
            {Tag,Chunk,Req}=cowboy_req:read_body(Req0,#{length => 8192,period => Remaining,timeout => Remaining}),
            Size=N+byte_size(Chunk),
            case {Size=<8192,Tag} of
                {false,_} -> {error,413,request_too_large,Req};
                {true,more} -> read_body(Req,[Chunk|Acc],Size,Deadline);
                {true,ok} ->
                    try json:decode(iolist_to_binary(lists:reverse([Chunk|Acc]))) of
                        B when is_map(B) -> {ok,B,Req};_ -> {error,400,json_object_required,Req}
                    catch _:_ -> {error,400,invalid_json,Req} end
            end
    end.
call(Action,Owner,Body) ->
    try ecai_supply_chain_srv:request(Action,Owner,Body)
    catch exit:{timeout,_} -> {error,result_unknown_refresh};exit:_ -> {error,service_unavailable} end.
result({ok,Data},Req,State) -> respond(200,#{ok => true,data => Data},Req,State);
result({error,Why},Req,State) ->
    Code=case Why of revision_conflict -> 409;stale_plan -> 409;proposal_changed -> 409;
        no_proposal -> 409;guest_session_expired -> 410;
        guest_capacity -> 429;guest_rate_limited -> 429;guest_worker_capacity -> 429;owner_busy -> 429;worker_capacity -> 429;workspace_capacity -> 429;
        feature_disabled -> 503;service_unavailable -> 503;storage_unavailable -> 503;
        result_unknown_refresh -> 503;planning_timeout -> 503;planning_failed -> 500;_ -> 422 end,
    Req1=case Code of 429 -> cowboy_req:set_resp_header(<<"retry-after">>,<<"5">>,Req);_ -> Req end,
    respond(Code,#{ok => false,error => Why},Req1,State).
respond(Code,Body,Req,State) ->
    H=#{<<"content-type">> => <<"application/json; charset=utf-8">>,<<"cache-control">> => <<"no-store, private">>,
        <<"vary">> => <<"Authorization, Cookie">>,<<"x-content-type-options">> => <<"nosniff">>},
    {ok,cowboy_req:reply(Code,H,ecai_supply_chain_util:json(Body),Req),State}.
