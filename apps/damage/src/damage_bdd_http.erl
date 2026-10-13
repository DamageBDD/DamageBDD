%% Authenticated composer API; no execution, billing or context-secret access.
-module(damage_bdd_http).
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

trails() ->
    [
        trails:trail(
            Path,
            ?MODULE,
            #{action => Action},
            #{Method => #{tags => ["BDD Composer"], produces => ["application/json"]}}
        )
     || {Path, Action, Method} <- [
            {"/ai/bdd/catalog", catalog, get},
            {"/ai/bdd/generate", generate, post},
            {"/ai/bdd/validate", validate, post},
            {"/ai/bdd/cancel", cancel, post}
        ]
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
is_authorized(Req, State) -> damage_http:is_authorized(Req, State).
allowed_methods(Req, #{action := catalog} = State) -> {[<<"GET">>], Req, State};
allowed_methods(Req, State) -> {[<<"POST">>], Req, State}.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

to_json(Req, State) ->
    Catalog = damage_bdd_catalog:snapshot(principal(State)),
    Modules = [maps:without([steps], M) || M <- maps:get(modules, Catalog)],
    Steps = [maps:without([parts], S) || S <- maps:get(steps, Catalog)],
    Body = Catalog#{modules := Modules, steps := Steps, engine => damage_bdd_generator:engine()},
    {jsx:encode(Body), cowboy_req:set_resp_headers(headers(), Req), State}.

from_json(Req, State) ->
    %% Non-simple custom header + JSON only: cross-origin forms cannot submit
    %% generation requests with cookie auth. No CORS opt-in is added here.
    case
        {cowboy_req:header(<<"x-damage-bdd">>, Req), cowboy_req:header(<<"sec-fetch-site">>, Req)}
    of
        {<<"1">>, Site} when Site =/= <<"cross-site">> -> read_request(Req, State);
        _ ->
            reply(
                403,
                #{
                    status => <<"error">>,
                    message =>
                        <<"Send same-origin JSON with X-Damage-BDD: 1.">>
                },
                Req,
                State
            )
    end.

read_request(Req0, State) ->
    case read_bounded(Req0, [], 0) of
        {error, Req} ->
            reply(
                413,
                #{
                    status => <<"error">>,
                    message =>
                        <<"Request body exceeds 128 KiB.">>
                },
                Req,
                State
            );
        {ok, Data, Req} ->
            Decoded =
                try
                    jsx:decode(Data, [return_maps])
                catch
                    _:_ -> invalid
                end,
            case is_map(Decoded) of
                true ->
                    dispatch(Decoded, Req, State);
                false ->
                    reply(
                        400,
                        #{
                            status => <<"error">>,
                            message =>
                                <<"Expected a JSON object.">>
                        },
                        Req,
                        State
                    )
            end
    end.

read_bounded(Req0, Acc, Size) ->
    case cowboy_req:read_body(Req0, #{length => 16384, period => 5000}) of
        {Flag, Part, Req} when Flag =:= ok; Flag =:= more ->
            NewSize = Size + byte_size(Part),
            case {NewSize =< 131072, Flag} of
                {false, _} -> {error, Req};
                {true, ok} -> {ok, iolist_to_binary(lists:reverse([Part | Acc])), Req};
                {true, more} -> read_bounded(Req, [Part | Acc], NewSize)
            end
    end.

dispatch(#{<<"feature">> := Feature}, Req, #{action := validate} = State) when
    is_binary(Feature), byte_size(Feature) =< 65536
->
    Catalog = damage_bdd_catalog:snapshot(principal(State)),
    Validation = damage_bdd_validator:validate(Feature, Catalog),
    reply(200, #{status => <<"ok">>, validation => Validation}, Req, State);
dispatch(
    #{<<"user_prompt">> := Prompt0, <<"request_id">> := Id},
    Req,
    #{action := generate} = State
) when is_binary(Prompt0), byte_size(Prompt0) =< 8000 ->
    Prompt =
        case valid_utf8(Prompt0) of
            true -> string:trim(Prompt0);
            false -> <<>>
        end,
    case byte_size(Prompt) > 0 andalso valid_id(Id) andalso valid_utf8(Prompt) of
        true ->
            Result =
                try
                    damage_bdd_service:generate(Id, Prompt, principal(State))
                catch
                    exit:_ ->
                        {error, service_unavailable,
                            <<"The BDD generation service is unavailable. Start the supervised service and retry.">>}
                end,
            case Result of
                {ok, Body} ->
                    reply(200, Body#{request_id => Id}, Req, State);
                {error, Code, Message} ->
                    reply(
                        error_status(Code),
                        #{
                            status => <<"error">>,
                            error => Code,
                            message => Message,
                            request_id => Id
                        },
                        Req,
                        State
                    )
            end;
        false ->
            bad_request(Req, State)
    end;
dispatch(#{<<"request_id">> := Id}, Req, #{action := cancel} = State) ->
    case valid_id(Id) of
        true ->
            try damage_bdd_service:cancel(Id, maps:get(public_key, State)) of
                {ok, Outcome} ->
                    reply(
                        200, #{status => <<"ok">>, cancelled => Outcome =:= cancelled}, Req, State
                    )
            catch
                exit:_ ->
                    reply(
                        503,
                        #{
                            status => <<"error">>,
                            message => <<"Generation service unavailable.">>
                        },
                        Req,
                        State
                    )
            end;
        false ->
            bad_request(Req, State)
    end;
dispatch(_, Req, State) ->
    bad_request(Req, State).

principal(State) -> maps:with([public_key], State).
valid_id(Id) when is_binary(Id), byte_size(Id) >= 1, byte_size(Id) =< 64 ->
    re:run(Id, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_id(_) ->
    false.
valid_utf8(B) -> unicode:characters_to_binary(B, utf8, utf8) =:= B.
bad_request(Req, State) ->
    reply(
        400,
        #{
            status => <<"error">>,
            message =>
                <<"Provide a feature (maximum 64 KiB), or user_prompt (maximum 8000 bytes) and request_id.">>
        },
        Req,
        State
    ).
error_status(generation_busy) -> 429;
error_status(generation_timeout) -> 504;
error_status(generation_cancelled) -> 409;
error_status(invalid_model_reply) -> 502;
error_status(generation_failed) -> 500;
error_status(_) -> 503.
headers() ->
    #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"private, no-store">>,
        <<"vary">> => <<"Authorization, Cookie">>,
        <<"x-content-type-options">> => <<"nosniff">>
    }.
reply(Status, Body, Req, State) ->
    {stop, cowboy_req:reply(Status, headers(), jsx:encode(Body), Req), State}.
