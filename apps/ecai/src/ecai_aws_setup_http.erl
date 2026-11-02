%% Explicit bearer + managed owner + TLS/origin checks. This separate endpoint is
%% the ONLY dashboard route accepting temporary AWS setup credentials. Never log
%% request bodies here or enable body capture at a reverse proxy/APM middleware.
-module(ecai_aws_setup_http).
-export([trails/0, init/2, secure_transport/3]).

trails() -> [
    route("/ecai/compute/aws/setup", status, get),
    route("/ecai/compute/aws/setup/connect", connect, post),
    route("/ecai/compute/aws/setup/disconnect", disconnect, post),
    route("/ecai/compute/aws/setup/plan", plan, post),
    route("/ecai/compute/aws/setup/:id/discard", <<"discard">>, post),
    route("/ecai/compute/aws/setup/:id/deploy", <<"deploy">>, post),
    route("/ecai/compute/aws/setup/:id/reconcile", <<"reconcile">>, post),
    route("/ecai/compute/aws/setup/:id/verify", <<"verify">>, post),
    route("/ecai/compute/aws/setup/:id/probe", <<"probe">>, post),
    route("/ecai/compute/aws/setup/:id/probe-status", <<"probe-status">>, post),
    route("/ecai/compute/aws/setup/:id/delete", <<"delete">>, post),
    route("/ecai/compute/aws/setup/:id", operation, get)
].
route(Path, Action, Method) -> trails:trail(Path, ?MODULE, #{action => Action, method => Method},
    #{Method => #{tags => ["ECAI Automatic AWS Setup"], produces => ["application/json"]}}).

init(Req0, #{method := Method, action := Action} = State) ->
    process_flag(sensitive, true),
    try
        Expected = case Method of get -> <<"GET">>; post -> <<"POST">> end,
        case cowboy_req:method(Req0) of
            Expected ->
                case authenticate(Req0) of
                    {ok, Owner, Binding} ->
                        case Method =:= get orelse allowed_request(Req0) of
                            true ->
                                case body(Req0, Method) of
                                    {ok, Input, Req} -> dispatch(Action, Owner, Binding, Input, Req, State);
                                    {error, Code, Error, Req} -> reply(Code, #{ok => false, error => Error}, Req, State)
                                end;
                            false -> reply(403, #{ok => false, error => https_same_origin_required}, Req0, State)
                        end;
                    {error, Why} -> reply(401, #{ok => false, error => Why}, Req0, State)
                end;
            _ -> reply(405, #{ok => false, error => method_not_allowed}, Req0, State)
        end
    catch
        _:_ -> reply(503, #{ok => false, error => automatic_aws_unavailable}, Req0, State)
    end.
authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
            case damage_auth:resolve_oauth(Token, #{}) of
                {ok, #{auth_mode := custodial} = Auth} ->
                    case damage_auth:authenticated_account(Auth) of
                        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner, crypto:hash(sha256, Token)};
                        _ -> {error, managed_account_required}
                    end;
                _ -> {error, managed_account_required}
            end;
        _ -> {error, explicit_bearer_required}
    end.
allowed_request(Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    TLS = secure_transport(cowboy_req:scheme(Req), Peer, cowboy_req:header(<<"x-forwarded-proto">>, Req, <<>>)),
    Origin = cowboy_req:header(<<"origin">>, Req, undefined),
    TLS andalso (Origin =:= undefined orelse Origin =:= ecai_aws_setup_config:origin()).
secure_transport(<<"https">>, _Peer, _Forwarded) -> true;
secure_transport(_, Peer, <<"https">>) ->
    %% Never trust arbitrary X-Forwarded-Proto. Only exact operator-listed peer
    %% addresses may attest TLS; the listener must not be publicly reachable.
    case application:get_env(ecai, aws_setup_trusted_proxy_ips, []) of
        IPs when is_list(IPs) -> lists:member(Peer, IPs);
        _ -> false
    end;
secure_transport(_, _, _) -> false.
body(Req, get) -> {ok, #{}, Req};
body(Req, post) ->
    case cowboy_req:header(<<"content-type">>, Req, <<>>) of
        <<"application/json", _/binary>> ->
            case cowboy_req:read_body(Req, #{length => 16384, period => 5000}) of
                {ok, Bytes, R} when byte_size(Bytes) =< 16384 ->
                    try jsx:decode(Bytes, [return_maps]) of
                        Map when is_map(Map) -> {ok, Map, R};
                        _ -> {error, 400, json_object_required, R}
                    catch _:_ -> {error, 400, invalid_json, R} end;
                {_, _, R} -> {error, 413, request_too_large, R}
            end;
        _ -> {error, 415, json_required, Req}
    end.

dispatch(status, Owner, Binding, _Input, Req, State) -> result(ecai_aws_setup:snapshot(Owner, Binding), Req, State);
dispatch(operation, Owner, _Binding, _Input, Req, State) -> result(ecai_aws_setup:operation(Owner, cowboy_req:binding(id, Req)), Req, State);
dispatch(connect, Owner, Binding, Input, Req, State) ->
    case only(Input, [<<"region">>, <<"credentials">>]) andalso ecai_aws_setup_config:allowed(Owner) andalso ecai_aws_setup_config:ready() =:= ok of
        true -> result(ecai_aws_setup:connect(Owner, Binding, maps:get(<<"region">>, Input, <<>>), maps:get(<<"credentials">>, Input, #{})), Req, State);
        false -> result({error, <<"node_setup_required_or_invalid_request">>}, Req, State)
    end;
dispatch(disconnect, Owner, Binding, Input, Req, State) ->
    case only(Input, [<<"session_id">>]) of
        true -> result(ecai_aws_setup:disconnect(Owner, Binding, maps:get(<<"session_id">>, Input, <<>>)), Req, State);
        false -> result({error, <<"unexpected_fields">>}, Req, State)
    end;
dispatch(plan, Owner, Binding, Input, Req, State) ->
    case only(Input, [<<"session_id">>, <<"options">>]) of
        true -> result(ecai_aws_setup:plan(Owner, Binding, maps:get(<<"session_id">>, Input, <<>>),
            cowboy_req:header(<<"idempotency-key">>, Req, <<>>), maps:get(<<"options">>, Input, #{})), Req, State);
        false -> result({error, <<"unexpected_fields">>}, Req, State)
    end;
dispatch(Action, Owner, Binding, Input, Req, State) when is_binary(Action) ->
    Allowed = case Action of
        <<"deploy">> -> [<<"session_id">>, <<"plan_sha256">>, <<"confirm">>, <<"acknowledge_costs_and_iam">>, <<"replace_connection">>];
        <<"reconcile">> -> [<<"session_id">>];
        <<"delete">> -> [<<"session_id">>, <<"confirm">>, <<"retain_artifacts">>];
        <<"probe">> -> [<<"confirm">>];
        _ -> []
    end,
    case only(Input, Allowed) of
        true -> result(ecai_aws_setup:action(Owner, Binding, cowboy_req:binding(id, Req), Action, Input), Req, State);
        false -> result({error, <<"unexpected_fields">>}, Req, State)
    end.
only(Map, Keys) -> lists:all(fun(K) -> lists:member(K, Keys) end, maps:keys(Map)).
result({ok, Data}, Req, State) -> reply(200, #{ok => true, data => Data}, Req, State);
result({error, Error}, Req, State) -> reply(409, #{ok => false, error => Error}, Req, State).
reply(Code, Data, Req, State) ->
    R = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>}, jsx:encode(Data), Req),
    {ok, R, State}.
