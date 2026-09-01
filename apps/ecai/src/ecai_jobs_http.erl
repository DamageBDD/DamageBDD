%%--------------------------------------------------------------------
%% Marketplace HTTP API for economic chunk jobs.
%%
%% This is deliberately separate from the operational indexing queue at
%% /ecai/index-jobs.  Marketplace jobs represent publish/claim/submit/pay
%% workflows; they do not execute index builds.
%%--------------------------------------------------------------------
-module(ecai_jobs_http).

-export([
    init/2,
    trails/0,
    is_authorized/2,
    allowed_methods/2,
    content_types_accepted/2,
    content_types_provided/2,
    from_json/2,
    to_json/2
]).

-define(JSON, <<"application/json">>).
-define(MAX_BODY_BYTES, 1048576).
-define(TRAILS_TAG, ["ECAI Marketplace Jobs"]).

trails() ->
    [
        get_trail("/ecai/market/jobs", list),
        post_trail("/ecai/market/jobs/publish", publish),
        get_trail("/ecai/market/jobs/:id", get),
        post_trail("/ecai/market/jobs/:id/claim", claim),
        post_trail("/ecai/market/jobs/:id/submit", submit),
        post_trail("/ecai/market/jobs/:id/pay", pay)
    ].

get_trail(Path, Action) ->
    trails:trail(
        Path,
        ?MODULE,
        #{action => Action},
        #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
    ).

post_trail(Path, Action) ->
    trails:trail(
        Path,
        ?MODULE,
        #{action => Action},
        #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
    ).

init(Req, State) ->
    {cowboy_rest, Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, #{action := Action} = State) when
    Action =:= publish;
    Action =:= claim;
    Action =:= submit;
    Action =:= pay
->
    {[<<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, #{action := Action} = State) when
    Action =:= publish;
    Action =:= claim;
    Action =:= submit;
    Action =:= pay
->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State};
content_types_accepted(Req, State) ->
    {[], Req, State}.

to_json(Req0, #{action := list} = State) ->
    Query = maps:from_list(cowboy_req:parse_qs(Req0)),
    case parse_status(maps:get(<<"status">>, Query, <<"any">>)) of
        {ok, Status} ->
            case safe_call(fun() -> ecai_jobs_srv:list(#{status => Status}) end) of
                {ok, {ok, Jobs}} ->
                    reply_json(Req0, 200, #{ok => true, jobs => Jobs}, State);
                {ok, {error, Reason}} ->
                    reply_error(Req0, 422, Reason, State);
                {error, Reason} ->
                    reply_error(Req0, 503, Reason, State)
            end;
        error ->
            reply_error(Req0, 400, invalid_status, State)
    end;
to_json(Req0, #{action := get} = State) ->
    case request_job_id(Req0) of
        {ok, Id} ->
            case safe_call(fun() -> ecai_jobs_srv:get(Id) end) of
                {ok, {ok, Job}} ->
                    reply_json(Req0, 200, #{ok => true, job => Job}, State);
                {ok, {error, not_found}} ->
                    reply_error(Req0, 404, not_found, State);
                {ok, {error, Reason}} ->
                    reply_error(Req0, 422, Reason, State);
                {error, Reason} ->
                    reply_error(Req0, 503, Reason, State)
            end;
        error ->
            reply_error(Req0, 400, invalid_job_id, State)
    end;
to_json(Req0, State) ->
    reply_error(Req0, 404, not_found, State).

from_json(Req0, #{action := publish} = State) ->
    with_body(Req0, State, fun(Body, Req1) ->
        case
            required_fields(Body, [
                <<"owner_ak">>, <<"market_ct">>, <<"reward_damage">>, <<"ttl_blocks">>
            ])
        of
            ok ->
                OwnerAk = maps:get(<<"owner_ak">>, Body),
                MarketCt = maps:get(<<"market_ct">>, Body),
                Paths = maps:get(<<"paths">>, Body, []),
                Reward = maps:get(<<"reward_damage">>, Body),
                Ttl = maps:get(<<"ttl_blocks">>, Body),
                case
                    safe_call(fun() ->
                        ecai_jobs_srv:publish_chunks(OwnerAk, MarketCt, Paths, Reward, Ttl)
                    end)
                of
                    {ok, {ok, Ids}} ->
                        reply_json(Req1, 202, #{ok => true, job_ids => Ids}, State);
                    {ok, {error, Reason}} ->
                        reply_error(Req1, 422, Reason, State);
                    {error, Reason} ->
                        reply_error(Req1, 503, Reason, State)
                end;
            {error, Reason} ->
                reply_error(Req1, 400, Reason, State)
        end
    end);
from_json(Req0, #{action := claim} = State) ->
    with_id_and_body(Req0, State, fun(Id, Body, Req1) ->
        case maps:get(<<"miner_ak">>, Body, undefined) of
            undefined -> reply_error(Req1, 400, {missing_field, miner_ak}, State);
            MinerAk -> marketplace_call(Req1, State, fun() -> ecai_jobs_srv:claim(Id, MinerAk) end)
        end
    end);
from_json(Req0, #{action := submit} = State) ->
    with_id_and_body(Req0, State, fun(Id, Body, Req1) ->
        case required_fields(Body, [<<"miner_ak">>, <<"attestation">>]) of
            ok ->
                MinerAk = maps:get(<<"miner_ak">>, Body),
                Attestation = maps:get(<<"attestation">>, Body),
                Evidence = maps:get(<<"evidence_ref">>, Body, undefined),
                marketplace_call(
                    Req1,
                    State,
                    fun() -> ecai_jobs_srv:submit(Id, MinerAk, Attestation, Evidence) end
                );
            {error, Reason} ->
                reply_error(Req1, 400, Reason, State)
        end
    end);
from_json(Req0, #{action := pay} = State) ->
    with_id_and_body(Req0, State, fun(Id, Body, Req1) ->
        case maps:get(<<"admin_ak">>, Body, undefined) of
            undefined -> reply_error(Req1, 400, {missing_field, admin_ak}, State);
            AdminAk -> marketplace_call(Req1, State, fun() -> ecai_jobs_srv:pay(Id, AdminAk) end)
        end
    end);
from_json(Req0, State) ->
    reply_error(Req0, 404, bad_action, State).

marketplace_call(Req, State, Fun) ->
    case safe_call(Fun) of
        {ok, {ok, Job}} -> reply_json(Req, 200, #{ok => true, job => Job}, State);
        {ok, {error, not_found}} -> reply_error(Req, 404, not_found, State);
        {ok, {error, Reason}} -> reply_error(Req, 409, Reason, State);
        {error, Reason} -> reply_error(Req, 503, Reason, State)
    end.

with_id_and_body(Req0, State, Fun) ->
    case request_job_id(Req0) of
        {ok, Id} ->
            with_body(Req0, State, fun(Body, Req1) -> Fun(Id, Body, Req1) end);
        error ->
            reply_error(Req0, 400, invalid_job_id, State)
    end.

with_body(Req0, State, Fun) ->
    case read_json_map(Req0) of
        {ok, Body, Req1} -> Fun(Body, Req1);
        {error, Code, Reason, Req1} -> reply_error(Req1, Code, Reason, State)
    end.

read_json_map(Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_BODY_BYTES, period => 5000}) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _ -> {error, 400, json_object_required, Req1}
            catch
                error:Reason -> {error, 400, {invalid_json, Reason}, Req1}
            end;
        {more, _Partial, Req1} ->
            {error, 413, payload_too_large, Req1}
    end.

request_job_id(Req) ->
    case cowboy_req:binding(id, Req) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            try
                {ok, binary_to_integer(Bin)}
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end.

parse_status(<<"any">>) -> {ok, any};
parse_status(<<"open">>) -> {ok, open};
parse_status(<<"claimed">>) -> {ok, claimed};
parse_status(<<"submitted">>) -> {ok, submitted};
parse_status(<<"paid">>) -> {ok, paid};
parse_status(<<"cancelled">>) -> {ok, cancelled};
parse_status(_) -> error.

required_fields(_Map, []) ->
    ok;
required_fields(Map, [Key | Rest]) ->
    case maps:is_key(Key, Map) of
        true -> required_fields(Map, Rest);
        false -> {error, {missing_field, Key}}
    end.

safe_call(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        exit:Reason -> {error, {market_jobs_unavailable, Reason}};
        Class:Reason -> {error, {market_jobs_failed, Class, Reason}}
    end.

reply_error(Req, Code, Reason, State) ->
    reply_json(
        Req,
        Code,
        #{ok => false, error => ecai_index_job_codec:externalize(Reason)},
        State
    ).

reply_json(Req0, Code, Map, State) ->
    Req1 = cowboy_req:reply(
        Code,
        #{<<"content-type">> => ?JSON},
        jsx:encode(ecai_index_job_codec:externalize(Map)),
        Req0
    ),
    {stop, Req1, State}.
