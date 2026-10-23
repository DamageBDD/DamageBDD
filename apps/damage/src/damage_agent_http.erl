-module(damage_agent_http).
-license("Apache-2.0").
-export([trails/0,init/2,is_authorized/2,allowed_methods/2,content_types_provided/2,
         content_types_accepted/2,to_json/2,to_html/2,from_json/2]).

trails() -> [trails:trail(Path,?MODULE,#{action => Action},#{}) || {Path,Action} <- [
    {"/automated-tasks",ui},{"/api/agents/templates",templates},
    {"/api/agents/tasks",tasks},{"/api/agents/tasks/:id",task},
    {"/api/agents/tasks/:id/events",events},{"/api/agents/tasks/:id/command",command},
    {"/api/agents/tasks/:id/learning",learning}]].
init(Req,Opts) -> {cowboy_rest,Req,Opts}.
is_authorized(Req,#{action := ui}=State) -> {true,Req,State};
is_authorized(Req,State) ->
    case damage_http:is_authorized(Req,State) of
        {true,R,S=#{public_key := Owner}} ->
            case damage_agent_policy:owner(damage_agent_codec:bin(Owner)) of
                true -> {true,R,S};
                false -> {{false,<<"Bearer">>},R,S}
            end;
        Other -> Other
    end.
allowed_methods(Req,#{action := tasks}=S) -> {[<<"GET">>,<<"POST">>],Req,S};
allowed_methods(Req,#{action := command}=S) -> {[<<"POST">>],Req,S};
allowed_methods(Req,S) -> {[<<"GET">>],Req,S}.
content_types_provided(Req,#{action := ui}=S) ->
    {[{{<<"text">>,<<"html">>,[]},to_html}],Req,S};
content_types_provided(Req,S) -> {[{{<<"application">>,<<"json">>,[]},to_json}],Req,S}.
content_types_accepted(Req,S) -> {[{{<<"application">>,<<"json">>,[]},from_json}],Req,S}.

to_html(Req,S) ->
    {ok,HTML} = file:read_file(filename:join(code:priv_dir(damage),"static/agent-tasks.html")),
    {HTML,headers(Req),S}.
to_json(Req,S=#{action := Action}) ->
    try
        O = owner(S), Id = cowboy_req:binding(id,Req,<<>>),
        Result = case Action of
            templates -> {ok,#{templates => damage_agent_policy:templates(O)}};
            tasks -> {ok,#{tasks => damage_agent:list(O)}};
            task -> damage_agent:status(O,Id);
            events -> case damage_agent:events(O,Id) of
                {ok,Es} -> {ok,#{events => Es}}; E -> E end;
            learning -> damage_agent:learning(O,Id)
        end,
        case Result of
            {ok,Value} ->
                Req1 = case Action of
                    learning -> cowboy_req:set_resp_header(<<"content-disposition">>,
                                    <<"attachment; filename=agent-experience.json">>,Req);
                    _ -> Req
                end,
                {jsx:encode(Value),headers(Req1),S};
            {error,R} -> stop(error_status(R),#{error => R},Req,S)
        end
    catch _:_ -> stop(503,#{error => agent_service_unavailable},Req,S) end.

from_json(Req0,S) ->
    case csrf_ok(Req0) of
        false -> stop(403,#{error => same_origin_required},Req0,S);
        true ->
            Deadline = erlang:monotonic_time(millisecond)+10000,
            case read_body(Req0,16384,[],Deadline) of
                {error,too_large,Req} -> stop(413,#{error => request_too_large},Req,S);
                {error,timeout,Req} -> stop(408,#{error => request_timeout},Req,S);
                {ok,Body,Req} ->
                    try
                        M = jsx:decode(Body,[return_maps]),
                        true = is_map(M),
                        dispatch(M,Req,S)
                    catch _:_ -> stop(400,#{error => invalid_request},Req,S) end
            end
    end.
dispatch(M,Req,S=#{action := tasks}) ->
    true = lists:sort(maps:keys(M)) =:= [<<"goal">>,<<"template">>],
    Key = cowboy_req:header(<<"idempotency-key">>,Req,<<>>),
    respond(damage_agent:start(owner(S),maps:get(<<"template">>,M),
                              maps:get(<<"goal">>,M),Key),202,Req,S);
dispatch(M,Req,S=#{action := command}) ->
    true = lists:all(fun(K) -> lists:member(K,[<<"command">>,<<"proposal_hash">>]) end,maps:keys(M)),
    Command = maps:get(<<"command">>,M),
    true = lists:member(Command,[<<"pause">>,<<"resume">>,<<"cancel">>,<<"approve">>,<<"reject">>,<<"reconcile">>]),
    respond(damage_agent:command(owner(S),cowboy_req:binding(id,Req),Command,
                                 maps:get(<<"proposal_hash">>,M,<<>>)),200,Req,S).
respond({ok,V},Status,Req,S) -> stop(Status,V,Req,S);
respond({error,R},_,Req,S) -> stop(error_status(R),#{error => R},Req,S).
stop(Code,Body,Req,S) -> {stop,cowboy_req:reply(Code,
    #{<<"content-type">> => <<"application/json">>,<<"cache-control">> => <<"no-store">>,
      <<"x-content-type-options">> => <<"nosniff">>},jsx:encode(Body),Req),S}.
headers(Req) -> cowboy_req:set_resp_headers(#{<<"cache-control">> => <<"no-store">>,
    <<"x-content-type-options">> => <<"nosniff">>,<<"referrer-policy">> => <<"same-origin">>,
    <<"content-security-policy">> => <<"default-src 'self'; script-src 'self'; style-src 'self'; "
                                     "object-src 'none'; base-uri 'none'; frame-ancestors 'self'">>},Req).
owner(S) -> damage_agent_codec:bin(maps:get(public_key,S)).
csrf_ok(Req) ->
    Custom = cowboy_req:header(<<"x-damage-agent">>,Req) =:= <<"1">>,
    Origin = cowboy_req:header(<<"origin">>,Req),
    Expected = damage_agent_policy:env(origin,undefined),
    Bearer = case cowboy_req:header(<<"authorization">>,Req,<<>>) of
        <<"Bearer ",T/binary>> when byte_size(T)>0 -> true;
        _ -> false
    end,
    Custom andalso case Origin of
        undefined -> Bearer;
        _ -> is_binary(Expected) andalso Origin =:= Expected
    end.
read_body(Req,Remaining,Acc,Deadline) ->
    Left = Deadline-erlang:monotonic_time(millisecond),
    case Left > 0 of
        false -> {error,timeout,Req};
        true ->
            case cowboy_req:read_body(Req,#{length => 16384,period => min(5000,Left)}) of
                {ok,B,R} when byte_size(B) =< Remaining ->
                    case erlang:monotonic_time(millisecond) =< Deadline of
                        true -> {ok,iolist_to_binary(lists:reverse([B|Acc])),R};
                        false -> {error,timeout,R}
                    end;
                {more,B,R} when byte_size(B) =< Remaining ->
                    read_body(R,Remaining-byte_size(B),[B|Acc],Deadline);
                {_,_,R} -> {error,too_large,R}
            end
    end.
error_status(not_found) -> 404;
error_status(forbidden) -> 403;
error_status(task_quota_exceeded) -> 429;
error_status(agent_service_unavailable) -> 503;
error_status(idempotency_conflict) -> 409;
error_status(stale_or_invalid_approval) -> 409;
error_status(reconciliation_required) -> 409;
error_status(accounting_operation_in_flight) -> 409;
error_status(execution_reconciliation_required) -> 409;
error_status(accounting_required) -> 409;
error_status(task_terminal) -> 409;
error_status(_) -> 400.
