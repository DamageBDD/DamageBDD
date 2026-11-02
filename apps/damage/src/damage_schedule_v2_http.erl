-module(damage_schedule_v2_http).

-export([
    init/2,
    trails/0,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    is_authorized/2,
    to_json/2,
    from_json/2
]).

-include_lib("kernel/include/logger.hrl").

-define(TRAILS_TAG, ["Schedules"]).

trails() ->
    [
        trails:trail(
            "/api/schedules/v2/templates",
            ?MODULE,
            #{action => templates},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/templates/render",
            ?MODULE,
            #{action => render_template},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/operations", ?MODULE, #{action => operations},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/operations/:operation_id", ?MODULE, #{action => operation},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2",
            ?MODULE,
            #{action => schedules},
            #{
                get => #{tags => ?TRAILS_TAG, produces => ["application/json"]},
                post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}
            }
        ),
        trails:trail(
            "/api/schedules/v2/status",
            ?MODULE,
            #{action => status},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/setup",
            ?MODULE,
            #{action => setup},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/preview",
            ?MODULE,
            #{action => preview},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/analytics",
            ?MODULE,
            #{action => analytics},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/tx/submit",
            ?MODULE,
            #{action => submit_tx},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id/runs",
            ?MODULE,
            #{action => runs},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id",
            ?MODULE,
            #{action => schedule},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id/pause",
            ?MODULE,
            #{action => pause},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id/resume",
            ?MODULE,
            #{action => resume},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id/cancel",
            ?MODULE,
            #{action => cancel},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/schedules/v2/:schedule_id/run",
            ?MODULE,
            #{action => run_now},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, #{action := setup} = State) ->
    case damage_http:is_authorized(Req, State) of
        {true, Req1, AuthState} ->
            Owner = maps:get(public_key, AuthState, undefined),
            NodeAdmin = maps:get(node_admin, AuthState, false),
            Custodial = is_custodial_request(AuthState, Owner),
            case NodeAdmin orelse Custodial of
                true -> {true, Req1, AuthState};
                false -> {{false, <<"Custodial wallet or node admin required">>}, Req1, AuthState}
            end;
        Other ->
            Other
    end;
is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, #{action := schedules} = State) ->
    {[<<"GET">>, <<"POST">>], Req, State};
allowed_methods(Req, #{action := Action} = State) when
    Action =:= operations; Action =:= operation; Action =:= templates; Action =:= status; Action =:= analytics; Action =:= schedule; Action =:= runs
->
    {[<<"GET">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

to_json(Req, #{action := operations, public_key := Owner} = State) ->
    reply_result(damage_schedule_v2:operations(Owner), Req, State);
to_json(Req, #{action := operation, public_key := Owner} = State) ->
    Id = cowboy_req:binding(operation_id, Req),
    reply_result(damage_schedule_v2:operation(Owner, Id), Req, State);
to_json(Req0, #{action := templates} = State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req0),
    {jsx:encode(#{status => <<"ok">>, data => damage_schedule_templates:catalog()}), Req, State};
to_json(Req, #{action := status, public_key := Owner} = State) ->
    Custodial = is_custodial_request(State, Owner),
    Body =
        case damage_schedule_v2_contract:contract_address() of
            {ok, Contract} ->
                #{
                    status => <<"ok">>,
                    version => 2,
                    custodial => Custodial,
                    contract => Contract,
                    token_contract => damage_schedule_v2_contract:token_contract()
                };
            {error, Reason} ->
                #{
                    status => <<"not_configured">>,
                    version => 2,
                    custodial => Custodial,
                    auto_setup => Custodial,
                    reason => term_bin(Reason),
                    token_contract => damage_schedule_v2_contract:token_contract()
                }
        end,
    {jsx:encode(Body), Req, State};
to_json(Req, #{action := schedules, public_key := Owner} = State) ->
    json_result(damage_schedule_v2:list(Owner), Req, State);
to_json(Req, #{action := schedule, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    json_result(damage_schedule_v2:get(Owner, Id), Req, State);
to_json(Req, #{action := runs, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    Qs = cowboy_req:parse_qs(Req),
    Limit = qs_int(<<"limit">>, Qs, 20),
    json_result(damage_schedule_v2:runs(Owner, Id, Limit), Req, State);
to_json(Req, #{action := analytics, public_key := Owner} = State) ->
    Qs = cowboy_req:parse_qs(Req),
    From = qs_int(<<"from">>, Qs, undefined),
    To = qs_int(<<"to">>, Qs, undefined),
    json_result(damage_schedule_v2:analytics(Owner, From, To), Req, State);
to_json(Req, State) ->
    {jsx:encode(#{status => <<"notok">>, error => <<"unsupported_get">>}), Req, State}.

from_json(Req0, #{action := render_template} = State) ->
    %% Binary keys only; never intern untrusted parameter names as atoms.
    %% This route builds a draft and cannot schedule, contact a host or spend.
    case cowboy_req:read_body(Req0, #{length => 8192, period => 5000}) of
        {ok, Raw, Req} when byte_size(Raw) =< 8192 ->
            Parsed = try jsx:decode(Raw, [return_maps]) catch _:_ -> invalid end,
            case Parsed of
                #{<<"template_id">> := Id, <<"params">> := Params} ->
                    case damage_schedule_templates:render(Id, Params) of
                        {ok, Draft} -> reply_json(200, Draft#{status => <<"ok">>}, Req, State);
                        {error, Why} -> reply_json(400,
                            #{status => <<"notok">>, error => Why}, Req, State)
                    end;
                _ -> reply_json(400, #{status => <<"notok">>, error => <<"invalid_json">>}, Req, State)
            end;
        {_, _, Req} -> reply_json(413,
            #{status => <<"notok">>, error => <<"body_too_large">>}, Req, State)
    end;
from_json(Req, #{action := setup, public_key := Owner} = State) ->
    Reply0 =
        case maps:get(node_admin, State, false) orelse is_custodial_request(State, Owner) of
            true -> damage_schedule_v2:setup_vault();
            false -> {error, forbidden}
        end,
    Reply =
        case Reply0 of
            {ok, Contract} ->
                {ok, #{
                    contract => Contract,
                    token_contract => damage_schedule_v2_contract:token_contract()
                }};
            {error, _} = Error ->
                Error
        end,
    reply_result(Reply, Req, State);
from_json(Req0, #{action := preview, public_key := Owner} = State) ->
    with_json_body(Req0, State, fun(Json, Req) ->
        reply_result(damage_schedule_v2:preview(Owner, Json), Req, State)
    end);
from_json(Req0, #{action := schedules, public_key := Owner} = State) ->
    with_json_body(Req0, State, fun(Json, Req) ->
        %% Setup and chain waits belong to the journalled worker.
        reply_result(damage_schedule_v2:create(Owner, Json), Req, State)
    end);
from_json(Req0, #{action := submit_tx, public_key := Owner} = State) ->
    with_json_body(Req0, State, fun(Json, Req) ->
        reply_result(damage_schedule_v2:submit_tx(Owner, Json), Req, State)
    end);
from_json(Req, #{action := pause, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    reply_result(damage_schedule_v2:action(Owner, Id, pause), Req, State);
from_json(Req, #{action := resume, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    reply_result(damage_schedule_v2:action(Owner, Id, resume), Req, State);
from_json(Req, #{action := cancel, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    reply_result(damage_schedule_v2:action(Owner, Id, cancel), Req, State);
from_json(Req, #{action := run_now, public_key := Owner} = State) ->
    Id = cowboy_req:binding(schedule_id, Req),
    reply_result(damage_schedule_v2:run_now(Owner, Id), Req, State);
from_json(Req, State) ->
    reply_json(400, #{status => <<"notok">>, error => <<"unsupported_action">>}, Req, State).

with_json_body(Req0, State, Fun) ->
    case cowboy_req:read_body(Req0) of
        {ok, <<>>, Req} -> invoke_json_handler(Fun, #{}, Req, State);
        {ok, Raw, Req} ->
            %% Never intern untrusted keys; normalize_input/1 handles known keys.
            Decoded = try jsx:decode(Raw, [return_maps]) of
                Json when is_map(Json) -> {ok, Json};
                _ -> {error, invalid_json}
            catch _:_ -> {error, invalid_json}
            end,
            case Decoded of
                {ok, JsonMap} -> invoke_json_handler(Fun, JsonMap, Req, State);
                {error, _} -> reply_json(400,
                    #{status => <<"notok">>, error => <<"invalid_json">>}, Req, State)
            end;
        {more, _Raw, Req} ->
            reply_json(413, #{status => <<"notok">>, error => <<"body_too_large">>}, Req, State)
    end.

invoke_json_handler(Fun, Json, Req, State) ->
    try Fun(Json, Req) of
        Reply -> Reply
    catch
        exit:{timeout, _} ->
            reply_result({error, schedule_operation_outcome_unknown}, Req, State);
        exit:{noproc, _} ->
            reply_result({error, schedule_service_unavailable}, Req, State);
        _:_ -> reply_json(500,
            #{status => <<"notok">>, error => <<"schedule_request_failed">>}, Req, State)
    end.

json_result({ok, Value}, Req, State) ->
    {jsx:encode(#{status => <<"ok">>, data => Value}), Req, State};
json_result({error, Reason}, Req, State) ->
    {jsx:encode(#{status => <<"notok">>, error => term_bin(Reason)}), Req, State}.

reply_result({ok, #{operation_id := _, status := running} = Op}, Req, State) ->
    reply_json(202, Op, Req, State);
reply_result({ok, #{operation_id := _} = Op}, Req, State) ->
    reply_json(200, Op, Req, State);
reply_result({error, Reason}, Req, State) when
    Reason =:= schedule_operation_in_progress;
    Reason =:= pending_schedule_requires_reconciliation;
    Reason =:= idempotency_conflict
->
    reply_json(409, #{status => <<"notok">>, error => atom_to_binary(Reason, utf8)}, Req, State);
reply_result({error, Reason}, Req, State) when
    Reason =:= schedule_service_unavailable; Reason =:= schedule_service_busy
->
    reply_json(503, #{status => <<"notok">>, error => atom_to_binary(Reason, utf8)}, Req, State);
reply_result({error, schedule_operation_outcome_unknown}, Req, State) ->
    reply_json(504, #{status => <<"notok">>, error => <<"schedule_operation_outcome_unknown">>}, Req, State);
reply_result({ok, Value}, Req, State) ->
    reply_json(200, normalize_ok(Value), Req, State);
reply_result({error, forbidden}, Req, State) ->
    reply_json(403, #{status => <<"notok">>, error => <<"forbidden">>}, Req, State);
reply_result({error, not_found}, Req, State) ->
    reply_json(404, #{status => <<"notok">>, error => <<"not_found">>}, Req, State);
reply_result({error, schedule_v2_contract_not_configured}, Req, State) ->
    reply_json(
        503,
        #{status => <<"notok">>, error => <<"schedule_v2_contract_not_configured">>},
        Req,
        State
    );
reply_result({error, Reason}, Req, State) ->
    reply_json(400, #{status => <<"notok">>, error => term_bin(Reason)}, Req, State).

is_custodial_request(State, Owner) ->
    case maps:get(auth_mode, State, undefined) of
        custodial -> true;
        <<"custodial">> -> true;
        "custodial" -> true;
        _ -> damage_schedule_v2_contract:is_custodial_wallet(Owner)
    end.

normalize_ok(#{status := signing_required} = M) ->
    maps:put(status, <<"signing_required">>, jsonable(M));
normalize_ok(M) when is_map(M) ->
    maps:put(status, <<"ok">>, jsonable(M));
normalize_ok(V) ->
    #{status => <<"ok">>, data => jsonable(V)}.

reply_json(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>
        },
        jsx:encode(jsonable(Body)),
        Req0
    ),
    {stop, Req, State}.

qs_int(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, Value} ->
            try
                binary_to_integer(Value)
            catch
                _:_ -> Default
            end;
        false ->
            Default
    end.

jsonable(M) when is_map(M) ->
    maps:from_list([{json_key(K), jsonable(V)} || {K, V} <- maps:to_list(M)]);
jsonable([]) -> [];
jsonable(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> [jsonable(V) || V <- L]
    end;
jsonable(A) when is_atom(A) -> atom_to_binary(A, utf8);
jsonable(T) when is_tuple(T) -> [jsonable(V) || V <- tuple_to_list(T)];
jsonable(V) ->
    V.

json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) -> K.

term_bin(B) when is_binary(B) -> B;
term_bin(Term) -> iolist_to_binary(io_lib:format("~p", [Term])).
