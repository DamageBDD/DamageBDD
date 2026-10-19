%% Authenticated, same-origin math workspace API. No payable auth challenges.
-module(ecai_math_dashboard_http).
-export([trails/0, init/2]).

trails() ->
    [trail("/ecai/math/jobs", jobs, [get, post]),
     trail("/ecai/math/jobs/:id", job, [get]),
     trail("/ecai/math/jobs/:id/replay", replay, [post]),
     trail("/ecai/math/jobs/:id/path", path, [get]),
     trail("/ecai/math/jobs/:id/path/:model_id", model_path, [get])].
trail(Path, Action, Methods) ->
    Meta = maps:from_list([{M, #{tags => ["ECAI Mathematical Paths"],
                                produces => ["application/json"]}} || M <- Methods]),
    trails:trail(Path, ?MODULE, #{action => Action, methods => Methods}, Meta).

init(Req0, #{action := Action, methods := Methods} = State) ->
    Method = cowboy_req:method(Req0),
    Allowed = [string:uppercase(atom_to_binary(M, utf8)) || M <- Methods],
    case lists:member(Method, Allowed) of
        false -> respond(405, #{ok => false, error => method_not_allowed},
                         cowboy_req:set_resp_header(<<"allow">>, lists:join(<<", ">>, Allowed), Req0), State);
        true ->
            case authenticate(Req0, Method) of
                {ok, Owner} ->
                    case ecai_math_dashboard_srv:enabled() of
                        false -> result({error, math_dashboard_disabled}, Req0, State, 200);
                        true -> route(Action, Method, Owner, Req0, State)
                    end;
                {error, Why} -> respond(401, #{ok => false, error => Why}, Req0, State)
            end
    end.

authenticate(Req, Method) ->
    %% An explicit bearer is mandatory for computation/import/replay. Cookie-only
    %% GETs are read-only. Do not fall back to cookies for an invalid bearer.
    try
        case cowboy_req:header(<<"sec-fetch-site">>, Req, <<>>) of
            <<"cross-site">> -> {error, cross_site_rejected};
            _ ->
                case cowboy_req:header(<<"authorization">>, Req, <<>>) of
                    <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
                        actor(damage_auth:resolve_oauth(Token, #{}));
                    <<>> when Method =:= <<"GET">> -> actor(damage_auth:authenticate(Req, #{}));
                    _ -> {error, explicit_bearer_required}
                end
        end
    catch _:_ -> {error, auth_unavailable} end.
actor({ok, #{auth_mode := custodial} = Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        _ -> {error, authenticated_account_required}
    end;
actor(_) -> {error, managed_account_required}.

route(jobs, <<"GET">>, Owner, Req, State) ->
    result(ecai_math_dashboard_srv:list(Owner), Req, State, 200);
route(job, <<"GET">>, Owner, Req, State) ->
    result(ecai_math_dashboard_srv:get(Owner, cowboy_req:binding(id, Req)), Req, State, 200);
route(Action, <<"GET">>, Owner, Req, State) when Action =:= path; Action =:= model_path ->
    ModelId = case Action of model_path -> cowboy_req:binding(model_id,Req); path -> undefined end,
    case ecai_math_dashboard_srv:path(Owner, cowboy_req:binding(id, Req),ModelId) of
        {ok, Bin} ->
            Headers = (headers())#{<<"content-disposition">> => <<"attachment; filename=ecai-math-path.json">>},
            {ok, cowboy_req:reply(200, Headers, Bin, Req), State};
        Error -> result(Error, Req, State, 200)
    end;
route(Action, <<"POST">>, Owner, Req0, State) ->
    case read_json(Req0) of
        {ok, Body, Req} ->
            Reply = case Action of
                jobs -> ecai_math_dashboard_srv:submit(Owner, Body);
                replay when map_size(Body) =:= 0 -> ecai_math_dashboard_srv:replay(Owner, cowboy_req:binding(id, Req));
                replay when map_size(Body) =:= 1, is_map_key(<<"model_id">>,Body) ->
                    ecai_math_dashboard_srv:replay(Owner,cowboy_req:binding(id,Req),maps:get(<<"model_id">>,Body));
                _ -> {error, unexpected_fields}
            end,
            result(Reply, Req, State, 202);
        {error, Status, Why, Req} -> respond(Status, #{ok => false, error => Why}, Req, State)
    end.

read_json(Req) ->
    ContentType = hd(binary:split(cowboy_req:header(<<"content-type">>, Req, <<>>), <<";">>)),
    case string:trim(string:lowercase(ContentType)) of
        <<"application/json">> -> read_chunks(Req, [], 0, erlang:monotonic_time(millisecond) + 5000);
        _ -> {error, 415, json_required, Req}
    end.
read_chunks(Req0, Acc, Size, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, 408, body_timeout, Req0};
        true ->
            {Tag, Chunk, Req} = cowboy_req:read_body(Req0, #{length => 65536, period => Remaining}),
            N = Size + byte_size(Chunk),
            case {N =< ecai_math_dashboard_task:max_bytes(), Tag} of
                {false, _} -> {error, 413, request_too_large, Req};
                {true, more} -> read_chunks(Req, [Chunk | Acc], N, Deadline);
                {true, ok} ->
                    try json:decode(iolist_to_binary(lists:reverse([Chunk | Acc]))) of
                        M when is_map(M) -> {ok, M, Req};
                        _ -> {error, 400, json_object_required, Req}
                    catch _:_ -> {error, 400, invalid_json, Req} end
            end
    end.
result({ok, Data}, Req, State, Code) -> respond(Code, #{ok => true, data => Data}, Req, State);
result({error, Why}, Req, State, _) ->
    Code = case Why of
        not_found -> 404;
        result_not_ready -> 409;
        model_selection_required -> 409;
        owner_busy -> 429;
        rate_limited -> 429;
        math_capacity_full -> 429;
        math_dashboard_disabled -> 503;
        math_dashboard_unavailable -> 503;
        _ -> 400
    end,
    Error = case is_atom(Why) of true -> Why; false -> <<"invalid_math_request">> end,
    respond(Code, #{ok => false, error => Error}, Req, State).
respond(Code, Body, Req, State) ->
    H = case Code of 429 -> (headers())#{<<"retry-after">> => <<"2">>}; _ -> headers() end,
    {ok, cowboy_req:reply(Code, H, json:encode(Body), Req), State}.
headers() ->
    #{<<"content-type">> => <<"application/json; charset=utf-8">>,
      <<"cache-control">> => <<"no-store, private">>,
      <<"vary">> => <<"Authorization, Cookie">>,
      <<"x-content-type-options">> => <<"nosniff">>,
      <<"referrer-policy">> => <<"no-referrer">>}.
