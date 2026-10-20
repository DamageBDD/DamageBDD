%% Node-admin-only API for code learning, repair inspection and gated publication.
%% Authentication comes exclusively from DamageBDD, roles from a fail-closed
%% allowlist of authenticated account IDs, never client-supplied JSON fields.
-module(ecai_code_admin_http).
-export([
    trails/0,
    init/2,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_json/2,
    from_json/2
]).

-ifdef(TEST).
-export([externalize/1]).
-endif.

-define(TAG, ["ECAI Code Administration"]).
-define(LIMIT, 8192).

trails() ->
    [
        trail("/ecai/admin/code/status", status, get),
        trail("/ecai/admin/code/settings", settings, get),
        trail("/ecai/admin/code/model-internals", model_internals, get),
        trail("/ecai/admin/code/model-internals/update", model_internals_update, post),
        trail("/ecai/admin/code/model-internals/preview", model_internals_preview, post),
        trail("/ecai/admin/code/settings/update", settings_update, post),
        trail("/ecai/admin/code/repository/fetch", repository_fetch, post),
        trail("/ecai/admin/code/repository/pull", repository_pull, post),
        trail("/ecai/admin/code/reviewers/add", reviewer_add, post),
        trail("/ecai/admin/code/reviewers/remove", reviewer_remove, post),
        trail("/ecai/admin/code/publishers/add", publisher_add, post),
        trail("/ecai/admin/code/publishers/remove", publisher_remove, post),
        trail("/ecai/admin/code/learning/export", learning_export, post),
        trail("/ecai/admin/code/learning/bundles", learning_bundles, get),
        trail("/ecai/admin/code/repairs", repairs, get),
        trail("/ecai/admin/code/learn", learn, post),
        trail("/ecai/admin/code/scan", scan, post),
        trail("/ecai/admin/code/propose", propose, post),
        trail("/ecai/admin/code/integrate", integrate, post),
        trail("/ecai/admin/code/reviews", reviews, get),
        trail("/ecai/admin/code/reviews/:id", review, get),
        trail("/ecai/admin/code/reviews/:id/approve", approve, post),
        trail("/ecai/admin/code/reviews/:id/reject", reject, post),
        trail("/ecai/admin/code/reviews/:id/publish", publish, post)
    ].
trail(Path, Action, Method) ->
    trails:trail(
        Path,
        ?MODULE,
        #{action => Action},
        #{Method => #{tags => ?TAG, produces => ["application/json"]}}
    ).

init(Req, State) -> {cowboy_rest, Req, State}.
is_authorized(Req, State) -> damage_http:is_authorized(Req, State).
allowed_methods(Req, #{action := Action} = State) when
    Action =:= learn;
    Action =:= settings_update;
    Action =:= model_internals_update;
    Action =:= model_internals_preview;
    Action =:= repository_fetch;
    Action =:= repository_pull;
    Action =:= reviewer_add;
    Action =:= reviewer_remove;
    Action =:= publisher_add;
    Action =:= publisher_remove;
    Action =:= learning_export;
    Action =:= scan;
    Action =:= integrate;
    Action =:= propose;
    Action =:= approve;
    Action =:= reject;
    Action =:= publish
->
    {[<<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

to_json(Req, State) ->
    case actor(State) of
        {ok, Actor} -> safely(fun() -> respond_get(Req, State, Actor) end, Req, State);
        {error, Reason} -> reply(Req, 403, #{ok => false, error => Reason}, State)
    end.
from_json(Req, State) ->
    case actor(State) of
        {ok, Actor} ->
            %% Require an explicit bearer header for all mutations; a cookie
            %% automatically attached by a cross-site request is insufficient.
            case cowboy_req:header(<<"authorization">>, Req, <<>>) of
                <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
                    %% Bind this exact bearer token, not merely its presence,
                    %% to the already authorized principal. No cookie fallback.
                    case damage_auth:resolve_oauth(Token, #{}) of
                        {ok, TokenAuth} ->
                            case actor(TokenAuth) of
                                {ok, Actor} ->
                                    case read_json(Req) of
                                        {ok, Body, Req1} ->
                                            safely(
                                                fun() -> respond_post(Req1, State, Actor, Body) end,
                                                Req1,
                                                State
                                            );
                                        {error, Code, Error, Req1} ->
                                            reply(Req1, Code, #{ok => false, error => Error}, State)
                                    end;
                                _ ->
                                    reply(
                                        Req,
                                        403,
                                        #{ok => false, error => bearer_identity_rejected},
                                        State
                                    )
                            end;
                        _ ->
                            reply(Req, 403, #{ok => false, error => invalid_bearer}, State)
                    end;
                _ ->
                    reply(Req, 403, #{ok => false, error => bearer_required}, State)
            end;
        {error, Reason} ->
            reply(Req, 403, #{ok => false, error => Reason}, State)
    end.

actor(State) ->
    case application:get_env(ecai, code_admin_enabled, false) of
        true -> actor_enabled(State);
        _ -> {error, admin_console_disabled}
    end.
actor_enabled(State) ->
    %% State holds the authenticated principal assigned by DamageBDD. Never
    %% trust an owner/admin/account field from request JSON or headers.
    case damage_auth:authenticated_account(State) of
        {ok, Account} when is_binary(Account), byte_size(Account) > 0 ->
            case
                ecai_node_admin:session_is_node_admin(State) andalso
                    ecai_node_admin:can_manage_code(Account)
            of
                true -> {ok, Account};
                false -> {error, admin_role_required}
            end;
        _ ->
            {error, authenticated_admin_required}
    end.

respond_get(Req, #{action := status} = State, _Actor) ->
    Data = #{
        learning => ecai_codebase_learning:status(),
        reviews => ecai_code_review_queue:status(),
        runtime => ecai_code_runtime_config:status()
    },
    reply(Req, 200, #{ok => true, status => Data}, State);
respond_get(Req, #{action := model_internals} = State, _Actor) ->
    reply(Req, 200, #{ok => true, model_internals => ecai_model_internals:status()}, State);
respond_get(Req, #{action := settings} = State, _Actor) ->
    reply(
        Req,
        200,
        #{
            ok => true,
            settings => ecai_code_runtime_config:get(),
            repository => ecai_code_runtime_config:repository_status()
        },
        State
    );
respond_get(Req, #{action := learning_bundles} = State, _Actor) ->
    case ecai_learning_exchange:list_bundles() of
        {ok, Bundles} -> reply(Req, 200, #{ok => true, bundles => Bundles}, State);
        {error, Reason} -> reply(Req, 409, #{ok => false, error => Reason}, State)
    end;
respond_get(Req, #{action := repairs} = State, _Actor) ->
    Repairs = ecai_learning_store:repairs(),
    Fields = [
        status,
        stage,
        fingerprint,
        finding_version,
        application,
        module,
        summary,
        security_property,
        patch_sha256,
        base_commit,
        created_at,
        updated_at,
        completed_at,
        failure_class,
        last_error
    ],
    Sorted = lists:sort(
        fun(A, B) ->
            maps:get(updated_at, A, <<>>) >=
                maps:get(updated_at, B, <<>>)
        end,
        Repairs
    ),
    reply(
        Req,
        200,
        #{
            ok => true,
            repairs =>
                [maps:with(Fields, R) || R <- lists:sublist(Sorted, 200)],
            total => length(Repairs)
        },
        State
    );
respond_get(Req, #{action := reviews} = State, _Actor) ->
    case ecai_code_review_queue:list() of
        {ok, Reviews} ->
            reply(
                Req,
                200,
                #{
                    ok => true,
                    reviews => Reviews,
                    queue => ecai_code_review_queue:status()
                },
                State
            );
        Error ->
            as_result(Req, State, Error, 503)
    end;
respond_get(Req, #{action := review} = State, Actor) ->
    as_result(Req, State, ecai_code_review_queue:get(cowboy_req:binding(id, Req), Actor), 200).

respond_post(Req, #{action := model_internals_update} = State, Actor, Body) ->
    model_internals_result(Req, State, ecai_model_internals:update(Body, Actor));
respond_post(Req, #{action := model_internals_preview} = State, _Actor, Body) ->
    model_internals_result(Req, State, ecai_model_internals:preview(Body));
respond_post(Req, #{action := settings_update} = State, _Actor, Body) ->
    case ecai_code_runtime_config:update(Body) of
        {ok, Settings} ->
            reply(
                Req,
                200,
                #{
                    ok => true,
                    settings => Settings,
                    repository => ecai_code_runtime_config:repository_status()
                },
                State
            );
        {error, Reason} ->
            reply(Req, 422, #{ok => false, error => Reason}, State)
    end;
respond_post(Req, #{action := repository_fetch} = State, _Actor, Body) ->
    empty_admin_action(
        Req, State, Body, fun ecai_code_runtime_config:fetch/0, repository
    );
respond_post(Req, #{action := repository_pull} = State, _Actor, Body) ->
    empty_admin_action(
        Req, State, Body, fun ecai_code_runtime_config:pull_ff/0, repository
    );
respond_post(Req, #{action := learning_export} = State, _Actor, Body) ->
    empty_admin_action(
        Req, State, Body, fun ecai_learning_exchange:export_bundle/0, bundle
    );
respond_post(Req, #{action := Action} = State, _Actor, Body) when
    Action =:= reviewer_add;
    Action =:= reviewer_remove;
    Action =:= publisher_add;
    Action =:= publisher_remove
->
    case {maps:keys(Body), maps:get(<<"account">>, Body, undefined)} of
        {[<<"account">>], Account} when is_binary(Account), byte_size(Account) > 0 ->
            Result =
                case Action of
                    reviewer_add -> ecai_code_runtime_config:add_reviewer(Account);
                    reviewer_remove -> ecai_code_runtime_config:remove_reviewer(Account);
                    publisher_add -> ecai_code_runtime_config:add_publisher(Account);
                    publisher_remove -> ecai_code_runtime_config:remove_publisher(Account)
                end,
            case Result of
                {ok, Settings} ->
                    reply(Req, 200, #{ok => true, settings => Settings}, State);
                {error, Reason} ->
                    reply(Req, 422, #{ok => false, error => Reason}, State)
            end;
        _ ->
            reply(Req, 400, #{ok => false, error => account_field_required}, State)
    end;
respond_post(Req, #{action := Action} = State, _Actor, Body) when
    Action =:= learn; Action =:= scan; Action =:= integrate
->
    case map_size(Body) =:= 0 of
        false ->
            reply(Req, 400, #{ok => false, error => unexpected_fields}, State);
        true ->
            {Process, Fun} =
                case Action of
                    learn -> {ecai_codebase_learner, fun ecai_codebase_learning:refresh/0};
                    scan -> {ecai_patch_manager, fun ecai_code_repair:scan_now/0};
                    integrate -> {ecai_patch_integration, fun ecai_code_repair:integrate/0}
                end,
            case whereis(Process) of
                undefined ->
                    reply(Req, 503, #{ok => false, error => worker_unavailable}, State);
                _Pid ->
                    case Fun() of
                        ok ->
                            reply(
                                Req,
                                202,
                                #{
                                    ok => true,
                                    action => Action,
                                    message => <<"Requested; see status for progress">>
                                },
                                State
                            );
                        {error, Reason} ->
                            reply(Req, 409, #{ok => false, error => Reason}, State);
                        Other ->
                            reply(Req, 503, #{ok => false, error => unexpected_action_result, result => Other}, State)
                    end
            end
    end;
respond_post(Req, #{action := propose} = State, _Actor, Body) ->
    App0 = maps:get(<<"application">>, Body, undefined),
    Module0 = maps:get(<<"module">>, Body, undefined),
    Fingerprint = maps:get(<<"fingerprint">>, Body, undefined),
    case valid_target(App0, Module0, Fingerprint) of
        {ok, App, Module} ->
            case ecai_code_repair:propose(App, Module, Fingerprint) of
                {ok, _Pid} ->
                    reply(
                        Req,
                        202,
                        #{
                            ok => true,
                            status => proposed,
                            message => <<"Proposal worker accepted; track it in the repair queue">>
                        },
                        State
                    );
                {ok, blocked, _Repair} ->
                    reply(Req, 409, #{ok => false, error => repair_blocked}, State);
                {ok, superseded, _Repair} ->
                    reply(Req, 409, #{ok => false, error => repair_superseded}, State);
                {error, Reason} ->
                    reply(Req, 409, #{ok => false, error => Reason}, State)
            end;
        {error, Reason} ->
            reply(Req, 422, #{ok => false, error => Reason}, State)
    end;
respond_post(Req, #{action := Action} = State, Actor, Body) when
    Action =:= approve; Action =:= reject
->
    Id = cowboy_req:binding(id, Req),
    Sha = maps:get(<<"patch_sha256">>, Body, undefined),
    Note = maps:get(<<"note">>, Body, undefined),
    Result =
        case Action of
            approve -> ecai_code_review_queue:approve(Id, Actor, Sha, Note);
            reject -> ecai_code_review_queue:reject(Id, Actor, Sha, Note)
        end,
    as_result(Req, State, Result, 200);
respond_post(Req, #{action := publish} = State, Actor, Body) ->
    case maps:get(<<"confirm">>, Body, undefined) of
        Confirm when Confirm =:= <<"push to origin">>;
                     Confirm =:= <<"push reviewed branch">> ->
            as_result(
                Req,
                State,
                ecai_code_review_queue:publish(
                    cowboy_req:binding(id, Req),
                    Actor,
                    maps:get(<<"patch_sha256">>, Body, undefined),
                    maps:get(<<"revision">>, Body, undefined)
                ),
                202
            );
        _ ->
            reply(Req, 400, #{ok => false, error => explicit_push_confirmation_required}, State)
    end.

model_internals_result(Req, State, {ok, Data}) ->
    reply(Req, 200, #{ok => true, model_internals => Data}, State);
model_internals_result(Req, State, {error, stale_revision}) ->
    reply(Req, 409, #{ok => false, error => stale_revision}, State);
model_internals_result(Req, State, {error, persistence_failed}) ->
    reply(Req, 503, #{ok => false, error => persistence_failed}, State);
model_internals_result(Req, State, {error, Reason}) ->
    reply(Req, 422, #{ok => false, error => Reason}, State).

empty_admin_action(Req, State, Body, Fun, Key) ->
    case map_size(Body) of
        0 ->
            case Fun() of
                {ok, Data} -> reply(Req, 200, #{ok => true, Key => Data}, State);
                ok -> reply(Req, 200, #{ok => true}, State);
                {error, Reason} -> reply(Req, 409, #{ok => false, error => Reason}, State)
            end;
        _ ->
            reply(Req, 400, #{ok => false, error => unexpected_fields}, State)
    end.

%% Never call binary_to_atom on user-controlled strings. The target must be an
%% existing module atom in the known application set, and the fingerprint must
%% already exist in the scanner's findings before ecai_code_repair proposes it.
valid_target(App0, Module0, Fp) when
    is_binary(App0),
    is_binary(Module0),
    is_binary(Fp),
    byte_size(Module0) > 0,
    byte_size(Module0) =< 128,
    byte_size(Fp) > 0,
    byte_size(Fp) =< 256
->
    case
        lists:member(App0, [<<"damage">>, <<"ecai">>, <<"erm">>]) andalso
            re:run(Module0, <<"^[a-z][a-zA-Z0-9_@]*$">>, [{capture, none}]) =:= match
    of
        true ->
            try
                {ok, binary_to_existing_atom(App0, utf8), binary_to_existing_atom(Module0, utf8)}
            catch
                error:badarg -> {error, unknown_module}
            end;
        false ->
            {error, unsupported_target}
    end;
valid_target(_, _, _) ->
    {error, invalid_target}.

as_result(Req, State, {ok, Data}, Code) ->
    reply(Req, Code, #{ok => true, review => Data}, State);
as_result(Req, State, {error, not_found}, _Code) ->
    reply(Req, 404, #{ok => false, error => not_found}, State);
as_result(Req, State, {error, Error}, _Code) ->
    reply(Req, 409, #{ok => false, error => Error}, State).

read_json(Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?LIMIT, period => 5000}) of
        {ok, Bin, Req1} when byte_size(Bin) =< ?LIMIT ->
            try jsx:decode(Bin, [return_maps]) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _ -> {error, 400, json_object_required, Req1}
            catch
                error:_ -> {error, 400, invalid_json, Req1}
            end;
        {ok, _, Req1} ->
            {error, 413, request_too_large, Req1};
        {more, _, Req1} ->
            {error, 413, request_too_large, Req1}
    end.

safely(Fun, Req, State) ->
    try
        Fun()
    catch
        Class:Reason ->
            logger:warning("ECAI code admin request failed class=~p reason=~p", [Class, Reason]),
            reply(Req, 503, #{ok => false, error => service_unavailable}, State)
    end.

reply(Req0, Code, Data, State) ->
    Req = cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(externalize(Data)),
        Req0
    ),
    {stop, Req, State}.

externalize(Map) when is_map(Map) ->
    maps:from_list([{to_binary(K), externalize(V)} || {K, V} <- maps:to_list(Map)]);
externalize(L) when is_list(L) -> [externalize(V) || V <- L];
externalize(T) when is_tuple(T) -> to_binary(io_lib:format("~0tp", [T]));
externalize(P) when is_pid(P) -> <<"<pid>">>;
%% Keep JSON authority/eligibility flags boolean, not the truthy string "false".
externalize(true) ->
    true;
externalize(false) ->
    false;
externalize(null) ->
    null;
externalize(undefined) ->
    null;
externalize(A) when is_atom(A) -> atom_to_binary(A, utf8);
externalize(V) ->
    V.

to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(V) -> iolist_to_binary(io_lib:format("~0tp", [V])).
