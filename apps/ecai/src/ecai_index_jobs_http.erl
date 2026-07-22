%%--------------------------------------------------------------------
%% REST control plane for durable indexing jobs.
%%--------------------------------------------------------------------
-module(ecai_index_jobs_http).

-export([
    init/2,
    trails/0,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_json/2,
    from_json/2
]).

-define(JSON, <<"application/json">>).
-define(TRAILS_TAG, ["ECAI Index Jobs"]).
-define(MAX_BODY_BYTES, 1048576).

trails() ->
    CollectionMeta = #{
        get => #{tags => ?TRAILS_TAG, produces => ["application/json"]},
        post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}
    },
    [
        trails:trail(
            "/ecai/index-jobs",
            ?MODULE,
            #{action => collection},
            CollectionMeta
        ),
        trails:trail(
            "/ecai/index-jobs/",
            ?MODULE,
            #{action => collection},
            CollectionMeta
        ),
        trails:trail(
            "/ecai/index-jobs/status",
            ?MODULE,
            #{action => status},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/index-jobs/:id",
            ?MODULE,
            #{action => get},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        control_trail("pause", pause),
        control_trail("resume", resume),
        control_trail("cancel", cancel),
        control_trail("retry", retry),
        trails:trail(
            "/ecai/index-jobs/:id/artifact",
            ?MODULE,
            #{action => artifact},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/index-jobs/:id/events",
            ecai_index_jobs_sse,
            #{action => events},
            #{get => #{tags => ?TRAILS_TAG, produces => ["text/event-stream"]}}
        )
    ].

control_trail(Name, Action) ->
    trails:trail(
        "/ecai/index-jobs/:id/" ++ Name,
        ?MODULE,
        #{action => Action},
        #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
    ).

init(Req, State) ->
    {cowboy_rest, Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, #{action := collection} = State) ->
    {[<<"GET">>, <<"POST">>], Req, State};
allowed_methods(Req, #{action := Action} = State) when
    Action =:= pause;
    Action =:= resume;
    Action =:= cancel;
    Action =:= retry
->
    {[<<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, #{action := collection} = State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State};
content_types_accepted(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, '*'}, from_json},
        {{<<"application">>, <<"octet-stream">>, '*'}, from_json},
        {{<<"text">>, <<"plain">>, '*'}, from_json}
    ], Req, State}.

to_json(Req0, #{action := collection} = State) ->
    Filter0 = query_filter(cowboy_req:parse_qs(Req0)),
    Filter = scope_filter(Filter0, State),
    case safe_call(fun() -> ecai_index_jobs_srv:list(Filter) end) of
        {ok, {ok, Jobs}} ->
            reply_json(Req0, 200, #{ok => true, jobs => Jobs}, State);
        {ok, {error, Reason}} ->
            reply_error(Req0, 400, Reason, State);
        {error, Reason} ->
            reply_error(Req0, 503, Reason, State)
    end;
to_json(Req0, #{action := status} = State) ->
    case safe_call(fun ecai_index_jobs_srv:status/0) of
        {ok, Status} -> reply_json(Req0, 200, #{ok => true, status => Status}, State);
        {error, Reason} -> reply_error(Req0, 503, Reason, State)
    end;
to_json(Req0, #{action := get} = State) ->
    with_job(Req0, State, fun(Job) ->
        reply_json(Req0, 200, #{ok => true, job => Job}, State)
    end);
to_json(Req0, #{action := artifact} = State) ->
    with_job(Req0, State, fun(Job) ->
        case maps:get(<<"artifact">>, Job, null) of
            null ->
                reply_error(Req0, 409, artifact_not_ready, State);
            Artifact ->
                JobId = maps:get(<<"id">>, Job),
                NftMetadata = case safe_call(fun() ->
                    ecai_index_jobs_srv:nft_metadata(JobId)
                end) of
                    {ok, {ok, Metadata}} -> Metadata;
                    _ -> null
                end,
                reply_json(
                    Req0,
                    200,
                    #{ok => true, artifact => Artifact, nft_metadata => NftMetadata},
                    State
                )
        end
    end);
to_json(Req0, State) ->
    reply_error(Req0, 404, not_found, State).

from_json(Req0, #{action := collection} = State) ->
    case read_json_map(Req0) of
        {ok, Spec0, Req1} ->
            Spec = bind_authenticated_owner(Spec0, State),
            IdempotencyKey = cowboy_req:header(<<"idempotency-key">>, Req1, <<>>),
            case safe_call(fun() ->
                ecai_index_jobs_srv:enqueue(
                    Spec,
                    #{idempotency_key => IdempotencyKey}
                )
            end) of
                {ok, {ok, Job}} ->
                    reply_json(Req1, 202, #{
                        ok => true,
                        job => Job,
                        events => events_path(maps:get(<<"id">>, Job))
                    }, State);
                {ok, {error, Reason}} ->
                    reply_error(Req1, enqueue_error_code(Reason), Reason, State);
                {error, Reason} ->
                    reply_error(Req1, 503, Reason, State)
            end;
        {error, Code, Reason, Req1} ->
            reply_error(Req1, Code, Reason, State)
    end;
from_json(Req0, #{action := Action} = State) when
    Action =:= pause;
    Action =:= resume;
    Action =:= cancel;
    Action =:= retry
->
    JobId = cowboy_req:binding(id, Req0),
    Function = control_function(Action),
    case safe_call(fun() -> ecai_index_jobs_srv:get(JobId) end) of
        {ok, {ok, ExistingJob}} ->
            case authorized_for_job(ExistingJob, State) of
                true ->
                    case safe_call(fun() -> Function(JobId) end) of
                        {ok, {ok, Job}} ->
                            reply_json(Req0, 202, #{ok => true, job => Job}, State);
                        {ok, {error, Reason}} ->
                            reply_error(Req0, 409, Reason, State);
                        {error, Reason} ->
                            reply_error(Req0, 503, Reason, State)
                    end;
                false ->
                    reply_error(Req0, 403, forbidden, State)
            end;
        {ok, {error, not_found}} ->
            reply_error(Req0, 404, not_found, State);
        {ok, {error, Reason}} ->
            reply_error(Req0, 400, Reason, State);
        {error, Reason} ->
            reply_error(Req0, 503, Reason, State)
    end;
from_json(Req0, State) ->
    reply_error(Req0, 404, bad_action, State).

with_job(Req0, State, Fun) ->
    JobId = cowboy_req:binding(id, Req0),
    case safe_call(fun() -> ecai_index_jobs_srv:get(JobId) end) of
        {ok, {ok, Job}} ->
            case authorized_for_job(Job, State) of
                true -> Fun(Job);
                false -> reply_error(Req0, 403, forbidden, State)
            end;
        {ok, {error, not_found}} -> reply_error(Req0, 404, not_found, State);
        {ok, {error, Reason}} -> reply_error(Req0, 400, Reason, State);
        {error, Reason} -> reply_error(Req0, 503, Reason, State)
    end.

read_json_map(Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_BODY_BYTES, period => 5000}) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _Other -> {error, 400, json_object_required, Req1}
            catch
                error:Reason -> {error, 400, {invalid_json, Reason}, Req1}
            end;
        {more, _Partial, Req1} ->
            {error, 413, payload_too_large, Req1}
    end.

query_filter(Query) ->
    lists:foldl(
        fun
            ({<<"state">>, Value}, Acc) -> Acc#{state => Value};
            ({<<"kind">>, Value}, Acc) -> Acc#{kind => Value};
            ({<<"owner">>, Value}, Acc) -> Acc#{owner => Value};
            ({<<"limit">>, Value}, Acc) -> Acc#{limit => Value};
            (_Other, Acc) -> Acc
        end,
        #{},
        Query
    ).

enqueue_error_code({idempotency_conflict, _Existing, _Requested}) -> 409;
enqueue_error_code({queue_capacity_exceeded, _Current, _Limit}) -> 429;
enqueue_error_code({owner_queue_capacity_exceeded, _Owner, _Current, _Limit}) -> 429;
enqueue_error_code(_Reason) -> 422.

control_function(pause) -> fun ecai_index_jobs_srv:pause/1;
control_function(resume) -> fun ecai_index_jobs_srv:resume/1;
control_function(cancel) -> fun ecai_index_jobs_srv:cancel/1;
control_function(retry) -> fun ecai_index_jobs_srv:retry/1.

bind_authenticated_owner(Spec, State) ->
    case authenticated_owner(State) of
        undefined -> Spec;
        Owner -> Spec#{<<"owner">> => Owner}
    end.

scope_filter(Filter, State) ->
    case authenticated_owner(State) of
        undefined -> Filter;
        Owner -> Filter#{owner => Owner}
    end.

authorized_for_job(Job, State) ->
    case authenticated_owner(State) of
        undefined -> true;
        Owner ->
            Spec = maps:get(<<"spec">>, Job, #{}),
            maps:get(<<"owner">>, Spec, <<>>) =:= Owner
    end.

authenticated_owner(State) ->
    case maps:get(ae_account, State, maps:get(owner, State, undefined)) of
        AuthBin when is_binary(AuthBin), byte_size(AuthBin) > 0 -> AuthBin;
        List when is_list(List), List =/= [] ->
            try unicode:characters_to_binary(List) of
                Converted when is_binary(Converted), byte_size(Converted) > 0 -> Converted
            catch
                _Class:_Reason -> undefined
            end;
        _ -> undefined
    end.

safe_call(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        exit:Reason -> {error, {index_jobs_unavailable, Reason}};
        Class:Reason -> {error, {index_jobs_failed, Class, Reason}}
    end.

reply_error(Req, Code, Reason, State) ->
    reply_json(Req, Code, #{
        ok => false,
        error => ecai_index_job_codec:externalize(Reason)
    }, State).

reply_json(Req0, Code, Map, State) ->
    Req1 = cowboy_req:reply(
        Code,
        #{<<"content-type">> => ?JSON},
        jsx:encode(Map),
        Req0
    ),
    {stop, Req1, State}.

events_path(JobId) ->
    <<"/ecai/index-jobs/", JobId/binary, "/events">>.
