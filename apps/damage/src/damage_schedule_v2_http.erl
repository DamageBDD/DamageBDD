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
    Action =:= status; Action =:= analytics; Action =:= schedule; Action =:= runs
->
    {[<<"GET">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

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
        Reply =
            case ensure_request_vault(State, Owner) of
                ok -> damage_schedule_v2:create(Owner, Json);
                {error, _} = Error -> Error
            end,
        reply_result(Reply, Req, State)
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
        {ok, <<>>, Req} ->
            Fun(#{}, Req);
        {ok, Raw, Req} ->
            try jsx:decode(Raw, [{labels, atom}, return_maps]) of
                Json when is_map(Json) -> Fun(Json, Req);
                _ ->
                    reply_json(
                        400, #{status => <<"notok">>, error => <<"invalid_json">>}, Req, State
                    )
            catch
                _:_ ->
                    reply_json(
                        400, #{status => <<"notok">>, error => <<"invalid_json">>}, Req, State
                    )
            end;
        {more, _Raw, Req} ->
            reply_json(413, #{status => <<"notok">>, error => <<"body_too_large">>}, Req, State)
    end.

json_result({ok, Value}, Req, State) ->
    {jsx:encode(#{status => <<"ok">>, data => Value}), Req, State};
json_result({error, Reason}, Req, State) ->
    {jsx:encode(#{status => <<"notok">>, error => term_bin(Reason)}), Req, State}.

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

ensure_request_vault(State, Owner) ->
    case damage_schedule_v2_contract:contract_address() of
        {ok, _Contract} ->
            ok;
        {error, schedule_v2_contract_not_configured} ->
            case is_custodial_request(State, Owner) of
                true ->
                    case damage_schedule_v2:setup_vault() of
                        {ok, _Contract} -> ok;
                        {error, _} = Error -> Error
                    end;
                false ->
                    {error, schedule_v2_contract_not_configured}
            end;
        {error, _} = Error ->
            Error
    end.

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
