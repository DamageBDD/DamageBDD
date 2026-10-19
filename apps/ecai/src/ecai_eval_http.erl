%% Evaluation endpoints on ECAI and Damage listeners; browser-managed accounts only.
-module(ecai_eval_http).
-export([trails/0, init/2]).
trails() ->
    [trail("/ecai/eval/settings", settings, [get, post]),
     trail("/ecai/eval/admin/settings", admin_settings, [get, post]),
     trail("/ecai/eval/suites", suites, [get, post]),
     trail("/ecai/eval/suites/:id/approve", approve_suite, [post]),
     trail("/ecai/eval/suites/:id", suite, [get]),
     trail("/ecai/eval/runs", runs, [get, post]),
     trail("/ecai/eval/runs/:id/cancel", cancel, [post]),
     trail("/ecai/eval/runs/:id/evidence", evidence, [get]),
     trail("/ecai/eval/runs/:id/attempts/:task_id", attempt, [get]),
     trail("/ecai/eval/runs/:id", run, [get]),
     trail("/ecai/eval/review-queue", review_queue, [get]),
     trail("/ecai/eval/review-detail", review_detail, [post]),
     trail("/ecai/eval/review", review, [post]),
     trail("/ecai/eval/compare", compare, [post])].
trail(Path, Action, Methods) ->
    Meta = maps:from_list([{M, #{tags => ["LLM evaluation"], produces => ["application/json"]}} || M <- Methods]),
    trails:trail(Path, ?MODULE, #{action => Action, methods => Methods}, Meta).
init(Req0, #{action := Action, methods := Methods} = State) ->
    Method = cowboy_req:method(Req0), Allowed = [string:uppercase(atom_to_binary(M, utf8)) || M <- Methods],
    case lists:member(Method, Allowed) of
        false -> respond(405, #{error => method_not_allowed}, cowboy_req:set_resp_header(<<"allow">>, lists:join(<<", ">>, Allowed), Req0), State);
        true ->
            case authenticate(Req0, Method) of
                {ok, Owner, Admin} ->
                    case Action =:= admin_settings andalso not Admin of
                        true -> respond(403, #{error => node_admin_required}, Req0, State);
                        false -> route(Action, Method, Owner, Admin, Req0, State)
                    end;
                {error, Why} -> respond(401, #{error => Why}, Req0, State)
            end
    end.
authenticate(Req, Method) ->
    try
        case cowboy_req:header(<<"sec-fetch-site">>, Req, <<>>) of
            <<"cross-site">> -> {error, cross_site_rejected};
            _ ->
                case cowboy_req:header(<<"authorization">>, Req, <<>>) of
                    <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 -> actor(damage_auth:resolve_oauth(Token, #{}));
                    <<>> when Method =:= <<"GET">> -> actor(damage_auth:authenticate(Req, #{}));
                    _ -> {error, explicit_bearer_required}
                end
        end
    catch _:_ -> {error, auth_unavailable} end.
actor({ok, #{auth_mode := custodial, authenticated := true} = Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner, ecai_node_admin:session_is_node_admin(Auth)};
        _ -> {error, authenticated_account_required}
    end;
actor(_) -> {error, managed_account_required}.
route(Action, <<"GET">>, O, Admin, Req, State) ->
    Body = bindings(Action, Req, #{}), result(call(Action, O, Admin, Body), Req, State);
route(Action, <<"POST">>, O, Admin, Req0, State) ->
    case read_json(Req0, case Action of suites -> 2*1024*1024; _ -> 65536 end) of
        {ok, Input, Req} ->
            Op = case Action of settings -> save_settings; suites -> import_suite; runs -> submit; _ -> Action end,
            %% Path IDs are authoritative; conflicting JSON IDs are rejected.
            try bindings(Op, Req, Input) of B -> result(call(Op, O, Admin, B), Req, State)
            catch throw:{eval_error, Why} -> result({error, Why}, Req, State) end;
        {error, Status, Why, Req} -> respond(Status, #{error => Why}, Req, State)
    end.
bindings(Action, Req, B) ->
    Keys = case Action of attempt -> [id, task_id];
        suite -> [id]; run -> [id]; evidence -> [id]; cancel -> [id]; approve_suite -> [id]; _ -> [] end,
    lists:foldl(fun(K, Acc) ->
        KB = atom_to_binary(K, utf8), V = cowboy_req:binding(K, Req),
        ecai_eval_util:require(not maps:is_key(KB, Acc) orelse maps:get(KB, Acc) =:= V, conflicting_resource_id),
        Acc#{KB => V} end, B, Keys).
call(admin_settings, _O, true, B) ->
    try
        ecai_eval_util:keys(B, [<<"version">>, <<"changes">>]),
        case map_size(B) of
            0 -> admin_snapshot();
            _ ->
                Changes = maps:get(<<"changes">>, B),
                Allowed = [atom_to_binary(maps:get(key, F), utf8) || F <- ecai_eval_policy:node_fields()],
                ecai_eval_util:keys(Changes, Allowed),
                case damage_settings:save(ecai, Changes, maps:get(<<"version">>, B)) of
                    {ok, _} -> admin_snapshot();
                    {error, version_conflict} -> {error, version_conflict};
                    {error, _} -> {error, invalid_node_settings}
                end
        end
    catch throw:{eval_error, Why} -> {error, Why}; exit:_ -> {error, service_unavailable}; _:_ -> {error, invalid_node_settings} end;
call(admin_settings, _, _, _) -> {error, node_admin_required};
call(Op, O, _, B) ->
    try ecai_eval_srv:request(Op, O, B)
    catch exit:{timeout, _} -> {error, result_unknown_do_not_retry_with_new_key};
          exit:_ -> {error, service_unavailable}; _:_ -> {error, evaluation_internal_error} end.
admin_snapshot() ->
    case damage_settings:get(ecai) of
        {ok, View} ->
            Names = [atom_to_binary(maps:get(key, F), utf8) || F <- ecai_eval_policy:node_fields()],
            {ok, #{<<"version">> => maps:get(version, View),
                   <<"fields">> => [F || F <- maps:get(fields, View), lists:member(maps:get(name, F), Names)]}};
        {error, _} -> {error, service_unavailable}
    end.
read_json(Req, Limit) ->
    CT = string:lowercase(string:trim(hd(binary:split(cowboy_req:header(<<"content-type">>, Req, <<>>), <<";">>)))),
    case CT of <<"application/json">> -> read_chunks(Req, Limit, [], 0, erlang:monotonic_time(millisecond)+5000);
               _ -> {error, 415, json_required, Req} end.
read_chunks(Req0, Limit, Acc, Size, Deadline) ->
    Remaining = Deadline-erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, 408, body_timeout, Req0};
        true ->
            case cowboy_req:read_body(Req0, #{length => 65536, period => Remaining, timeout => Remaining}) of
                {Tag, Chunk, Req} ->
                    N = Size+byte_size(Chunk),
                    case {N =< Limit, Tag} of
                        {false, _} -> {error, 413, request_too_large, Req};
                        {true, more} -> read_chunks(Req, Limit, [Chunk|Acc], N, Deadline);
                        {true, ok} ->
                            try ecai_eval_util:decode(iolist_to_binary(lists:reverse([Chunk|Acc]))) of
                                M when is_map(M) -> {ok, M, Req}; _ -> {error, 400, json_object_required, Req}
                            catch _:_ -> {error, 400, invalid_json, Req} end
                    end
            end
    end.
result({ok, Data}, Req, State) -> respond(200, #{ok => true, data => Data}, Req, State);
result({error, Why}, Req, State) ->
    Status = case Why of not_found -> 404; node_admin_required -> 403;
        version_conflict -> 409; idempotency_conflict -> 409; review_already_recorded -> 409;
        service_unavailable -> 503; result_unknown_do_not_retry_with_new_key -> 503;
        evidence_export_too_large -> 413; _ -> 422 end,
    respond(Status, #{ok => false, error => Why}, Req, State).
respond(Status, Payload, Req, State) ->
    Headers = #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>,
                <<"vary">> => <<"Authorization, Cookie">>},
    {ok, cowboy_req:reply(Status, Headers, ecai_eval_util:json(Payload), Req), State}.
