-module(damage_nsecbunker_handoff_http).
-export([init/2, trails/0, authorized_context/1, same_origin/2, decode_action/1]).
-define(HEADERS, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
    <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>}).
trails() -> [trails:trail("/api/admin/bunker", ?MODULE, #{}, #{
    get => #{tags => ["Node administration"], produces => ["application/json"]},
    post => #{tags => ["Node administration"], produces => ["application/json"]}})].
init(Req, Opts) ->
    Reply = try
        case damage_auth:authenticate(Req, #{action => admin_bunker}) of
            {ok, Ctx} ->
                case authorized_context(Ctx) andalso steps_utils:is_admin(maps:get(public_key, Ctx, <<>>)) of
                    true -> dispatch(Req, Ctx);
                    false -> json(403, #{error => node_admin_required}, Req)
                end;
            _ -> json(403, #{error => node_admin_required}, Req)
        end
    catch _:_ -> json(503, #{error => bunker_admin_unavailable}, Req) end,
    {ok, Reply, Opts}.

authorized_context(#{authenticated := true, node_admin := true, public_key := Key} = Ctx) ->
    is_binary(Key) andalso byte_size(Key) > 0 andalso maps:get(auth_mode, Ctx, legacy) =/= wallet;
authorized_context(_) -> false.

dispatch(Req, Ctx) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> json(200, damage_nsecbunker_handoff:status(), Req);
        <<"POST">> ->
            case csrf(Req) of
                true -> read_action(Req, Ctx);
                false -> json(403, #{error => same_origin_admin_action_required}, Req)
            end;
        _ -> cowboy_req:reply(405, maps:put(<<"allow">>, <<"GET, POST">>, ?HEADERS), <<>>, Req)
    end.
csrf(Req) ->
    Header = cowboy_req:header(<<"x-damage-bunker-action">>, Req),
    Origin = cowboy_req:header(<<"origin">>, Req),
    Expected = application:get_env(damage, nsecbunker_admin_origin,
        cowboy_req:uri(Req, #{path => <<>>, qs => <<>>})),
    Header =:= <<"1">> andalso case Origin of
        undefined -> case cowboy_req:header(<<"authorization">>, Req, <<>>) of
            <<"Bearer ", Token/binary>> when byte_size(Token) > 0 -> true;
            _ -> false
        end;
        _ -> same_origin(Origin, Expected)
    end.
same_origin(A, B) ->
    try origin(A) =:= origin(B) andalso origin(A) =/= invalid catch _:_ -> false end.
origin(U) ->
    case uri_string:parse(U) of
        #{scheme := S, host := H} = Parts when S =:= <<"http">>; S =:= <<"https">> ->
            case maps:is_key(userinfo, Parts) orelse maps:is_key(query, Parts) orelse maps:is_key(fragment, Parts) of
                true -> invalid;
                false -> {S, string:lowercase(H), maps:get(port, Parts, case S of <<"https">> -> 443; _ -> 80 end)}
            end;
        _ -> invalid
    end.
read_action(Req, Ctx) ->
    CT = hd(binary:split(cowboy_req:header(<<"content-type">>, Req, <<>>), <<";">>)),
    case CT of
        <<"application/json">> ->
            case cowboy_req:read_body(Req, #{length => 32768, period => 5000, timeout => 5000}) of
                {ok, B, Req1} ->
                    try jsx:decode(B, [return_maps]) of
                        M when is_map(M) -> action(M, Req1, Ctx);
                        _ -> json(400, #{error => invalid_request}, Req1)
                    catch _:_ -> json(400, #{error => invalid_request}, Req1) end;
                {more, _, Req1} -> json(413, #{error => request_too_large}, Req1)
            end;
        _ -> json(415, #{error => json_required}, Req)
    end.
action(#{<<"action">> := <<"accept">>, <<"report_sha256">> := Hash,
    <<"references">> := References} = M, Req, Ctx) when map_size(M) =:= 3 ->
    reply_result(damage_nsecbunker_handoff:accept(Hash, References, maps:get(public_key, Ctx)), Req);
action(#{<<"action">> := Name} = M, Req, _Ctx) when map_size(M) =< 2 ->
    case decode_action(Name) of
        {ok, A} ->
            Maintenance = lists:member(A, [restart, recovery, pending]),
            case not Maintenance orelse maps:get(<<"confirmed">>, M, false) =:= true of
                true -> reply_result(damage_nsecbunker_handoff:start(A), Req);
                false -> json(409, #{error => maintenance_confirmation_required}, Req)
            end;
        error -> json(400, #{error => unknown_action}, Req)
    end;
action(_, Req, _) -> json(400, #{error => invalid_request}, Req).
decode_action(<<"health">>) -> {ok, health};
decode_action(<<"verify">>) -> {ok, verify};
decode_action(<<"restart">>) -> {ok, restart};
decode_action(<<"recovery">>) -> {ok, recovery};
decode_action(<<"pending">>) -> {ok, pending};
decode_action(_) -> error.
reply_result({ok, M}, Req) -> json(202, M, Req);
reply_result({error, E}, Req) -> json(409, #{error => E}, Req).
json(Code, Body, Req) -> cowboy_req:reply(Code, ?HEADERS, jsx:encode(Body), Req).
