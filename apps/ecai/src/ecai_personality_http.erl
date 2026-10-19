%% Public catalogue; account-scoped purchase and delivery routes.
-module(ecai_personality_http).
-export([trails/0, init/2]).

trails() ->
    [trail("/ecai/personalities", catalogue, [get]),
     trail("/ecai/personalities/orders", orders, [get, post]),
     trail("/ecai/personalities/orders/:id/reconcile", reconcile, [post]),
     trail("/ecai/personalities/orders/:id/package", package, [get]),
     trail("/ecai/personalities/orders/:id", order, [get])].

trail(Path, Action, Methods) ->
    Meta = maps:from_list([{M, #{tags => ["AI personalities"],
                              produces => ["application/json"]}} || M <- Methods]),
    trails:trail(Path, ?MODULE, #{action => Action, methods => Methods}, Meta).

init(Req0, #{action := Action, methods := Methods} = State) ->
    Method = cowboy_req:method(Req0),
    Allowed = [string:uppercase(atom_to_binary(M, utf8)) || M <- Methods],
    case lists:member(Method, Allowed) of
        false ->
            Req = cowboy_req:set_resp_header(<<"allow">>, lists:join(<<", ">>, Allowed), Req0),
            respond(405, #{ok => false, error => method_not_allowed}, Req, State);
        true when Action =:= catalogue ->
            result(invoke(fun ecai_personalities:catalogue/0), Req0, State);
        true ->
            case authenticate(Req0, Method) of
                {ok, Owner} -> route(Action, Method, Owner, Req0, State);
                {error, cross_site_rejected} ->
                    respond(403, #{ok => false, error => cross_site_rejected}, Req0, State);
                {error, Why} -> respond(401, #{ok => false, error => Why}, Req0, State)
            end
    end.

authenticate(Req, Method) ->
    try
        case cowboy_req:header(<<"sec-fetch-site">>, Req, <<>>) of
            <<"cross-site">> -> {error, cross_site_rejected};
            _ ->
                case cowboy_req:header(<<"authorization">>, Req, <<>>) of
                    <<"Bearer ", Token/binary>> when byte_size(Token) >= 10,
                                                    byte_size(Token) =< 8192 ->
                        actor(damage_auth:resolve_oauth(Token, #{}));
                    <<>> when Method =:= <<"GET">> -> actor(damage_auth:authenticate(Req, #{}));
                    _ -> {error, explicit_bearer_required}
                end
        end
    catch _:_ -> {error, auth_unavailable} end.

actor({ok, #{auth_mode := custodial, authenticated := true} = Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        _ -> {error, authenticated_account_required}
    end;
actor(_) -> {error, managed_account_required}.

route(orders, <<"GET">>, Owner, Req, State) ->
    result(invoke(fun() -> ecai_personalities:list_orders(Owner) end), Req, State);
route(order, <<"GET">>, Owner, Req, State) ->
    Id = cowboy_req:binding(id, Req),
    result(invoke(fun() -> ecai_personalities:get_order(Owner, Id) end), Req, State);
route(package, <<"GET">>, Owner, Req, State) ->
    Id = cowboy_req:binding(id, Req),
    case invoke(fun() -> ecai_personalities:package(Owner, Id) end) of
        {ok, #{filename := Filename, content := Content}}
                when is_binary(Filename), is_binary(Content) ->
            %% Reject unsafe filenames rather than allowing header injection.
            case re:run(Filename, <<"^[A-Za-z0-9_.-]{1,160}$">>, [{capture, none}]) of
                match ->
                    Headers = (headers())#{<<"content-disposition">> =>
                        <<"attachment; filename=\"", Filename/binary, "\"">>},
                    {ok, cowboy_req:reply(200, Headers, Content, Req), State};
                _ -> result({error, invalid_package_filename}, Req, State)
            end;
        {error, _} = Error -> result(Error, Req, State);
        _ -> result({error, invalid_package_response}, Req, State)
    end;
route(Action, <<"POST">>, Owner, Req0, State) ->
    case read_json(Req0, 16384) of
        {ok, Body, Req} ->
            Reply = case Action of
                orders -> invoke(fun() -> ecai_personalities:create_order(Owner, Body) end);
                reconcile when map_size(Body) =:= 0 ->
                    Id = cowboy_req:binding(id, Req),
                    invoke(fun() -> ecai_personalities:reconcile(Owner, Id) end);
                reconcile -> {error, unexpected_fields};
                _ -> {error, invalid_request}
            end,
            result(Reply, Req, State);
        {error, Status, Why, Req} ->
            respond(Status, #{ok => false, error => Why}, Req, State)
    end;
route(_, _, _, Req, State) ->
    respond(405, #{ok => false, error => method_not_allowed}, Req, State).

invoke(F) ->
    try F()
    catch exit:{timeout, _} -> {error, result_unknown_do_not_retry_with_new_key};
          exit:_ -> {error, service_unavailable};
          _:_ -> {error, personality_internal_error} end.

read_json(Req, Limit) ->
    CT = string:lowercase(string:trim(hd(binary:split(
        cowboy_req:header(<<"content-type">>, Req, <<>>), <<";">>)))),
    case CT of
        <<"application/json">> ->
            read_chunks(Req, Limit, [], 0, erlang:monotonic_time(millisecond) + 5000);
        _ -> {error, 415, json_required, Req}
    end.

read_chunks(Req0, Limit, Acc, Size, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, 408, body_timeout, Req0};
        true ->
            try cowboy_req:read_body(Req0, #{length => 16384, period => Remaining,
                                             timeout => Remaining}) of
                {Tag, Chunk, Req} ->
                    N = Size + byte_size(Chunk),
                    case {N =< Limit, Tag} of
                        {false, _} -> {error, 413, request_too_large, Req};
                        {true, more} -> read_chunks(Req, Limit, [Chunk | Acc], N, Deadline);
                        {true, ok} ->
                            try ecai_eval_util:decode(iolist_to_binary(
                                    lists:reverse([Chunk | Acc]))) of
                                M when is_map(M) -> {ok, M, Req};
                                _ -> {error, 400, json_object_required, Req}
                            catch _:_ -> {error, 400, invalid_json, Req} end
                    end
            catch exit:timeout -> {error, 408, body_timeout, Req0};
                  exit:{timeout, _} -> {error, 408, body_timeout, Req0};
                  _:_ -> {error, 400, invalid_request_body, Req0} end
    end.

result({ok, Data}, Req, State) -> respond(200, #{ok => true, data => Data}, Req, State);
result({error, Why}, Req, State) ->
    respond(error_status(Why), #{ok => false, error => Why}, Req, State);
result(_, Req, State) ->
    respond(500, #{ok => false, error => invalid_service_response}, Req, State).

error_status(not_found) -> 404;
error_status(order_not_found) -> 404;
error_status(personality_not_found) -> 404;
error_status(forbidden) -> 403;
error_status(idempotency_conflict) -> 409;
error_status(sold_out) -> 409;
error_status(checkout_busy) -> 409;
error_status(rate_limited) -> 429;
error_status(too_many_pending_orders) -> 429;
error_status(account_order_limit) -> 429;
error_status(payment_required) -> 402;
error_status(order_not_paid) -> 402;
error_status(purchase_not_fulfilled) -> 409;
error_status(sales_disabled) -> 503;
error_status(service_unavailable) -> 503;
error_status(manifest_not_configured) -> 503;
error_status(lightning_not_configured) -> 503;
error_status(cln_unavailable) -> 503;
error_status(cln_rpc_error) -> 503;
error_status(invoice_creation_uncertain) -> 503;
error_status(result_unknown_do_not_retry_with_new_key) -> 503;
error_status(result_unknown_retry_same_key) -> 503;
error_status(personality_internal_error) -> 500;
error_status(invalid_package_filename) -> 500;
error_status(invalid_package_response) -> 500;
error_status(_) -> 422.

headers() ->
    #{<<"content-type">> => <<"application/json; charset=utf-8">>,
      <<"cache-control">> => <<"no-store">>,
      <<"x-content-type-options">> => <<"nosniff">>,
      <<"vary">> => <<"Authorization, Cookie">>}.

respond(Status, Payload, Req, State) ->
    {ok, cowboy_req:reply(Status, headers(), ecai_eval_util:json(Payload), Req), State}.
