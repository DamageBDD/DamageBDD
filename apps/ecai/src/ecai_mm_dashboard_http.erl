%% Same-origin, node-admin-only market maker dashboard API.
%% Read requests use DamageBDD browser authentication; mutations require an
%% explicit bearer and the same server-derived node-admin allowlist.
-module(ecai_mm_dashboard_http).
-export([
    trails/0,
    init/2,
    method_allowed/2,
    authorization_policy/4,
    validate_control/1,
    history_limit/1
]).

-define(JSON_LIMIT, 8192).
-define(TAG, ["ECAI Market Maker"]).

trails() ->
    [
        trail("/ecai/mm/status", status, get),
        trail("/ecai/mm/quotes", quotes, get),
        trail("/ecai/mm/history", history, get),
        trail("/ecai/mm/config", config, both),
        trail("/ecai/mm/control", control, post),
        trail("/ecai/mm/audit", audit, get)
    ].

trail(Path, Action, Kind) ->
    G = #{get => #{tags => ?TAG, produces => ["application/json"]}},
    P = #{post => #{tags => ?TAG, produces => ["application/json"]}},
    Meta =
        case Kind of
            get -> G;
            post -> P;
            both -> maps:merge(G, P)
        end,
    trails:trail(Path, ?MODULE, #{action => Action}, Meta).

method_allowed(config, M) -> M =:= <<"GET">> orelse M =:= <<"POST">>;
method_allowed(control, M) -> M =:= <<"POST">>;
method_allowed(Action, <<"GET">>) -> lists:member(Action, [status, quotes, history, audit]);
method_allowed(_, _) -> false.

init(Req0, #{action := Action} = State) ->
    process_flag(sensitive, true),
    Method = cowboy_req:method(Req0),
    case method_allowed(Action, Method) of
        false ->
            response(Req0, 405, #{error => method_not_allowed}, State);
        true ->
            case safe_actor(Req0, Method) of
                {error, authentication_service_unavailable} ->
                    response(Req0, 503, #{error => authentication_service_unavailable}, State);
                {error, Reason} ->
                    response(Req0, 403, #{error => Reason}, State);
                {ok, _Account} ->
                    case whereis(ecai_mm) of
                        undefined ->
                            response(
                                Req0,
                                503,
                                #{error => market_maker_not_running},
                                State
                            );
                        _ ->
                            safely(
                                fun() -> dispatch(Action, Method, Req0, State) end,
                                Req0,
                                State
                            )
                    end
            end
    end.

safe_actor(Req, Method) ->
    try
        actor(Req, Method)
    catch
        _:_ -> {error, authentication_service_unavailable}
    end.

actor(Req, Method) ->
    Enabled = application:get_env(ecai, market_maker_admin_enabled, false),
    case Enabled of
        true ->
            %% Prefer explicit tokens on reads as the existing dashboard
            %% request() supplies them. A bad bearer never falls back to a
            %% session cookie, and writes always require an explicit bearer.
            Auth =
                case {Method, cowboy_req:header(<<"authorization">>, Req, <<>>)} of
                    {_, <<"Bearer ", Token/binary>>} when
                        byte_size(Token) >= 10, byte_size(Token) =< 8192
                    ->
                        damage_auth:resolve_oauth(Token, #{});
                    {<<"POST">>, _} ->
                        {error, bearer_required};
                    {_, <<"Bearer ", _/binary>>} ->
                        {error, invalid_bearer};
                    {_, _} ->
                        damage_auth:authenticate(Req, #{})
                end,
            case Auth of
                {ok, Context} when is_map(Context) ->
                    case damage_auth:authenticated_account(Context) of
                        {ok, Account} when is_binary(Account) ->
                            %% Reject mismatches between the validated session
                            %% and the effective account of the bearer.
                            case
                                maps:get(public_key, Context, undefined) =:= Account andalso
                                    authorization_policy(
                                        Context,
                                        true,
                                        application:get_env(damage, node_admins, []),
                                        application:get_env(ecai, market_maker_accounts, [])
                                    )
                            of
                                true -> {ok, Account};
                                false -> {error, node_admin_required}
                            end;
                        _ ->
                            {error, managed_account_required}
                    end;
                _ ->
                    {error, authentication_required}
            end;
        _ ->
            {error, market_maker_console_disabled}
    end.

%% Pure policy that can be tested without secrets, cookies or network.
%% Wallet proof never authorizes portfolio data or trading controls.
authorization_policy(
    #{
        authenticated := true,
        auth_mode := custodial,
        node_admin := true,
        public_key := Account
    },
    true,
    DamageAdmins,
    Scope
) ->
    ecai_node_admin:allowed_by_policy(Account, DamageAdmins, Scope);
authorization_policy(_, _, _, _) ->
    false.

dispatch(status, <<"GET">>, Req, State) ->
    response(Req, 200, #{ok => true, status => ecai_mm:status()}, State);
dispatch(quotes, <<"GET">>, Req, State) ->
    response(Req, 200, #{ok => true, quotes => ecai_mm:quotes()}, State);
dispatch(history, <<"GET">>, Req, State) ->
    Limit = history_limit(cowboy_req:parse_qs(Req)),
    response(Req, 200, #{ok => true, history => ecai_mm:history(Limit)}, State);
dispatch(config, <<"GET">>, Req, State) ->
    response(Req, 200, #{ok => true, config => ecai_mm:config()}, State);
dispatch(audit, <<"GET">>, Req, State) ->
    case ecai_mm:verify_audit() of
        ok ->
            response(Req, 200, #{ok => true, verified => true}, State);
        _ ->
            response(
                Req,
                409,
                #{
                    ok => false,
                    verified => false,
                    error => audit_verification_failed
                },
                State
            )
    end;
dispatch(config, <<"POST">>, Req0, State) ->
    with_body(Req0, State, fun(Req, Body) ->
        case Body of
            #{
                <<"expected_revision">> := Revision,
                <<"changes">> := Changes
            } when
                is_integer(Revision),
                Revision >= 0,
                map_size(Body) =:= 2
            ->
                case ecai_mm_config:from_json(Changes) of
                    {ok, Patch} ->
                        case ecai_mm:configure(Patch, Revision) of
                            {ok, Config} ->
                                response(
                                    Req,
                                    200,
                                    #{ok => true, config => Config},
                                    State
                                );
                            {error, stale_config_revision} ->
                                response(
                                    Req,
                                    409,
                                    #{error => stale_config_revision},
                                    State
                                );
                            {error, Reason} ->
                                response(Req, 422, #{error => Reason}, State)
                        end;
                    {error, Reason} ->
                        response(Req, 422, #{error => Reason}, State)
                end;
            _ ->
                response(Req, 400, #{error => invalid_configuration_request}, State)
        end
    end);
dispatch(control, <<"POST">>, Req0, State) ->
    with_body(Req0, State, fun(Req, Body) ->
        case validate_control(Body) of
            {ok, pause} ->
                ok = ecai_mm:pause(),
                response(Req, 200, #{ok => true, status => ecai_mm:status()}, State);
            {ok, resume} ->
                case ecai_mm:resume() of
                    ok -> response(Req, 200, #{ok => true, status => ecai_mm:status()}, State);
                    {error, Reason} -> response(Req, 409, #{error => Reason}, State)
                end;
            {ok, poll} ->
                ecai_mm:poll(),
                response(Req, 202, #{ok => true, message => feed_refresh_requested}, State);
            {error, Reason} ->
                response(Req, 400, #{error => Reason}, State)
        end
    end).

validate_control(#{<<"action">> := <<"pause">>} = M) when map_size(M) =:= 1 -> {ok, pause};
validate_control(#{<<"action">> := <<"resume">>} = M) when map_size(M) =:= 1 -> {ok, resume};
validate_control(#{<<"action">> := <<"poll">>} = M) when map_size(M) =:= 1 -> {ok, poll};
validate_control(_) -> {error, invalid_control_action}.

history_limit(Qs) when is_list(Qs) ->
    case proplists:get_value(<<"limit">>, Qs, <<"500">>) of
        Value when is_binary(Value), byte_size(Value) =< 5 ->
            try
                max(1, min(2000, binary_to_integer(Value)))
            catch
                _:_ -> 500
            end;
        _ ->
            500
    end;
history_limit(_) ->
    500.

with_body(Req0, State, Continue) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req0, <<>>),
    case binary:split(ContentType, <<";">>) of
        [<<"application/json">> | _] ->
            case cowboy_req:read_body(Req0, #{length => ?JSON_LIMIT, period => 5000}) of
                {ok, Bin, Req} ->
                    Decode =
                        try jsx:decode(Bin, [return_maps]) of
                            Obj when is_map(Obj) -> {ok, Obj};
                            _ -> {error, json_object_required}
                        catch
                            error:_ -> {error, malformed_json}
                        end,
                    case Decode of
                        {ok, Body} -> Continue(Req, Body);
                        {error, Why} -> response(Req, 400, #{error => Why}, State)
                    end;
                {more, _, Req} ->
                    response(Req, 413, #{error => body_too_large}, State)
            end;
        _ ->
            response(Req0, 415, #{error => json_required}, State)
    end.

safely(Fun, Req, State) ->
    try
        Fun()
    catch
        Class:Reason ->
            logger:warning("ECAI market maker API failure class=~p reason=~p", [Class, Reason]),
            response(Req, 503, #{error => market_maker_unavailable}, State)
    end.

response(Req0, Status, Body, State) ->
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"pragma">> => <<"no-cache">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(externalize(Body)),
        Req0
    ),
    {ok, Req, State}.

externalize(Map) when is_map(Map) ->
    maps:from_list([{externalize_key(K), externalize(V)} || {K, V} <- maps:to_list(Map)]);
externalize(List) when is_list(List) -> [externalize(V) || V <- List];
externalize(true) ->
    true;
externalize(false) ->
    false;
externalize(null) ->
    null;
externalize(undefined) ->
    null;
externalize(A) when is_atom(A) -> atom_to_binary(A, utf8);
externalize(P) when is_pid(P) -> <<"<pid>">>;
externalize(T) when is_tuple(T) -> iolist_to_binary(io_lib:format("~0tp", [T]));
externalize(V) ->
    V.

externalize_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
externalize_key(K) when is_binary(K) -> K;
externalize_key(K) -> iolist_to_binary(io_lib:format("~0tp", [K])).
