%% Read-only route disclosure for authenticated users; mutation uses the same
%% fail-closed admin permission and exact bearer identity as ECAI LLM settings.
-module(damage_bdd_routing_http).
-export([trails/0, init/2, is_authorized/2, allowed_methods/2,
    content_types_provided/2, content_types_accepted/2, to_json/2, from_json/2, can_manage/1]).
trails() -> [trails:trail("/ai/bdd/routing", ?MODULE, #{}, #{})].
init(R,S) -> {cowboy_rest,R,S}.
is_authorized(R,S) -> damage_bdd_access:is_authorized(R,S).
allowed_methods(R,S) -> {[<<"GET">>,<<"POST">>],R,S}.
content_types_provided(R,S) -> {[{{<<"application">>,<<"json">>,[]},to_json}],R,S}.
content_types_accepted(R,S) -> {[{{<<"application">>,<<"json">>,[]},from_json}],R,S}.
can_manage(S) ->
    try
        {ok,A} = damage_auth:authenticated_account(S),
        application:get_env(ecai,code_admin_enabled,false) =:= true andalso
            ecai_node_admin:session_is_node_admin(S) andalso ecai_node_admin:can_manage_code(A)
    catch _:_ -> false end.
to_json(R,S) ->
    try
        Status = ecai_llm_settings:bdd_status(),
        {jsx:encode(Status#{can_manage => can_manage(S),
            pool_available => damage_bdd_inference:available()}),
         cowboy_req:set_resp_headers(headers(),R),S}
    catch _:_ -> reply(503,#{error => routing_unavailable},R,S) end.
from_json(R,S) ->
    case mutation_authorized(R,S) of
        false -> reply(403,#{error => admin_bearer_required},R,S);
        true ->
            case cowboy_req:read_body(R,#{length => 4096,period => 5000}) of
                {ok,B,R1} when byte_size(B) =< 4096 ->
                    try
                        M = jsx:decode(B,[return_maps]),
                        {ok,A} = damage_auth:authenticated_account(S),
                        case ecai_llm_settings:update_bdd(M,A) of
                            {ok,Revision} -> reply(200,#{revision => Revision},R1,S);
                            {error,stale_revision} -> reply(409,#{error => stale_revision},R1,S);
                            {error,E} -> reply(400,#{error => E},R1,S)
                        end
                    catch _:_ -> reply(503,#{error => routing_update_unavailable},R1,S) end;
                {_,_,R1} -> reply(413,#{error => request_too_large},R1,S)
            end
    end.
mutation_authorized(R,S) ->
    try
        true = can_manage(S),
        <<"1">> = cowboy_req:header(<<"x-damage-bdd">>,R),
        true = cowboy_req:header(<<"sec-fetch-site">>,R) =/= <<"cross-site">>,
        <<"Bearer ",T/binary>> = cowboy_req:header(<<"authorization">>,R,<<>>),
        true = byte_size(T) >= 10 andalso byte_size(T) =< 8192,
        {ok,TokenState} = damage_auth:resolve_oauth(T,#{}),
        {ok,A} = damage_auth:authenticated_account(S),
        {ok,A} = damage_auth:authenticated_account(TokenState),
        can_manage(TokenState)
    catch _:_ -> false end.
headers() -> #{<<"content-type">> => <<"application/json; charset=utf-8">>,
    <<"cache-control">> => <<"private, no-store">>, <<"vary">> => <<"Authorization, Cookie">>,
    <<"x-content-type-options">> => <<"nosniff">>}.
reply(Code,Body,R,S) -> {stop,cowboy_req:reply(Code,headers(),jsx:encode(Body),R),S}.
