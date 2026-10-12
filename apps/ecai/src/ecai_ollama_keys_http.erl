%% Managed-account dashboard API for issuing and revoking Ollama bearer keys.
%% These routes never accept an Ollama API key as authority to manage keys.
-module(ecai_ollama_keys_http).

-export([trails/0, init/2]).

-define(MAX_BODY, 16384).

trails() ->
    [
        trails:trail("/ecai/keys/ollama", ?MODULE, #{action => collection}, #{
            get => #{tags => ["ECAI Ollama API Keys"], produces => ["application/json"]},
            post => #{
                tags => ["ECAI Ollama API Keys"],
                consumes => ["application/json"],
                produces => ["application/json"]
            }
        }),
        trail("/ecai/keys/ollama/:id/rotate", rotate, post),
        trail("/ecai/keys/ollama/:id/revoke", revoke, post),
        trails:trail("/ecai/keys/ollama/quick-config", ?MODULE, #{action => quick_config}, #{
            get => #{tags => ["ECAI Ollama API Keys"], produces => ["application/json"]},
            post => #{
                tags => ["ECAI Ollama API Keys"],
                consumes => ["application/json"],
                produces => ["application/json"]
            }
        })
    ].

trail(Path, Action, Method) ->
    trails:trail(Path, ?MODULE, #{action => Action}, #{
        Method => #{
            tags => ["ECAI Ollama API Keys"],
            consumes => ["application/json"],
            produces => ["application/json"]
        }
    }).

init(Req0, #{action := Action} = State) ->
    Method = cowboy_req:method(Req0),
    case allowed(Action, Method) of
        false ->
            respond(Req0, State, 405, #{ok => false, error => method_not_allowed});
        true ->
            Mutation = Method =/= <<"GET">>,
            case authenticate_manager(Req0, Mutation) of
                {error, Why} -> respond(Req0, State, 401, #{ok => false, error => Why});
                {ok, Owner} -> dispatch(Action, Method, Owner, Req0, State)
            end
    end.

allowed(collection, <<"GET">>) -> true;
allowed(collection, <<"POST">>) -> true;
allowed(quick_config, <<"GET">>) -> true;
allowed(quick_config, <<"POST">>) -> true;
allowed(rotate, <<"POST">>) -> true;
allowed(revoke, <<"POST">>) -> true;
allowed(_, _) -> false.

dispatch(collection, <<"GET">>, Owner, Req, State) ->
    result(ecai_ollama_api_keys:list(Owner), Req, State);
dispatch(collection, <<"POST">>, Owner, Req0, State) ->
    with_json_body(Req0, State, fun(Body, Req) ->
        case ecai_ollama_api_keys:create(Owner, Body) of
            {ok, Issued} -> respond_issued(201, Issued, Req, State);
            {error, Why} -> result({error, Why}, Req, State)
        end
    end);
dispatch(rotate, <<"POST">>, Owner, Req0, State) ->
    with_empty_json_body(Req0, State, fun(Req) ->
        Id = cowboy_req:binding(id, Req),
        case ecai_ollama_api_keys:rotate(Owner, Id) of
            {ok, Issued} -> respond_issued(200, Issued, Req, State);
            {error, Why} -> result({error, Why}, Req, State)
        end
    end);
dispatch(revoke, <<"POST">>, Owner, Req0, State) ->
    with_empty_json_body(Req0, State, fun(Req) ->
        Id = cowboy_req:binding(id, Req),
        result(ecai_ollama_api_keys:revoke(Owner, Id), Req, State)
    end);
dispatch(quick_config, <<"GET">>, _Owner, Req, State) ->
    Config = quick_config(Req, <<"<YOUR_ECAI_OLLAMA_API_KEY>">>),
    respond(Req, State, 200, #{ok => true, data => Config});
dispatch(quick_config, <<"POST">>, Owner, Req0, State) ->
    with_json_body(Req0, State, fun(Body0, Req) ->
        Body =
            case maps:is_key(<<"label">>, Body0) of
                true -> Body0;
                false -> Body0#{<<"label">> => <<"Quick Ollama client">>}
            end,
        case ecai_ollama_api_keys:create(Owner, Body) of
            {ok, Issued} -> respond_issued(201, Issued, Req, State);
            {error, Why} -> result({error, Why}, Req, State)
        end
    end).

respond_issued(Code, #{key := Key, secret := Secret} = Issued, Req, State) ->
    Data0 = #{
        <<"key">> => Key,
        <<"secret">> => Secret,
        <<"quick_config">> => quick_config(Req, Secret)
    },
    Data =
        case maps:get(replaced_key_id, Issued, undefined) of
            undefined -> Data0;
            Id -> Data0#{<<"replaced_key_id">> => Id}
        end,
    respond(Req, State, Code, #{ok => true, data => Data}).

quick_config(Req, Token) ->
    Base = public_base_url(Req),
    Model = to_binary(application:get_env(ecai, ollama_api_quick_model, <<"ecai/chat:latest">>)),
    Auth = <<"Bearer ", Token/binary>>,
    Curl = iolist_to_binary([
        "curl ",
        Base,
        "/api/chat \\\n",
        "  -H 'Authorization: ",
        Auth,
        "' \\\n",
        "  -H 'Content-Type: application/json' \\\n",
        "  -d '{\"model\":\"",
        Model,
        "\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello from ECAI\"}],\"stream\":false}'"
    ]),
    Python = iolist_to_binary([
        "import os\nfrom ollama import Client\n\n",
        "client = Client(\n",
        "    host=os.environ[\"OLLAMA_HOST\"],\n",
        "    headers={\"Authorization\": \"Bearer \" + os.environ[\"OLLAMA_API_KEY\"]},\n",
        ")\n",
        "response = client.chat(model=\"",
        Model,
        "\", messages=[{\"role\": \"user\", \"content\": \"Hello from ECAI\"}], stream=False)\n",
        "print(response.message.content)\n"
    ]),
    Javascript = iolist_to_binary([
        "import { Ollama } from 'ollama'\n\n",
        "const client = new Ollama({\n",
        "  host: process.env.OLLAMA_HOST,\n",
        "  headers: { Authorization: `Bearer ${process.env.OLLAMA_API_KEY}` },\n",
        "})\n",
        "const response = await client.chat({\n",
        "  model: '",
        Model,
        "',\n",
        "  messages: [{ role: 'user', content: 'Hello from ECAI' }],\n",
        "  stream: false,\n",
        "})\nconsole.log(response.message.content)\n"
    ]),
    Shell = iolist_to_binary([
        "export OLLAMA_HOST=\"",
        Base,
        "\"\n",
        "export OLLAMA_API_KEY=\"",
        Token,
        "\""
    ]),
    #{
        <<"base_url">> => Base,
        <<"api_route">> => <<"/api/chat">>,
        <<"default_model">> => Model,
        <<"auth_required">> => application:get_env(ecai, ollama_api_auth_required, true) =:= true,
        <<"environment">> => Shell,
        <<"curl">> => Curl,
        <<"python">> => Python,
        <<"javascript">> => Javascript,
        <<"note">> =>
            <<"Keep API keys out of browser bundles, logs and source control. Revoke or rotate them from Dashboard > Keys.">>
    }.

public_base_url(Req) ->
    case application:get_env(ecai, ollama_api_public_base_url) of
        {ok, Value} -> strip_trailing_slash(to_binary(Value));
        undefined -> request_origin(Req)
    end.

request_origin(Req) ->
    Scheme = to_binary(cowboy_req:scheme(Req)),
    Host0 = cowboy_req:host(Req),
    Host = maybe_bracket_ipv6(Host0),
    Port = cowboy_req:port(Req),
    Default =
        (Scheme =:= <<"http">> andalso Port =:= 80) orelse
            (Scheme =:= <<"https">> andalso Port =:= 443),
    case Default of
        true -> <<Scheme/binary, "://", Host/binary>>;
        false -> <<Scheme/binary, "://", Host/binary, ":", (integer_to_binary(Port))/binary>>
    end.

maybe_bracket_ipv6(Host) when is_binary(Host) ->
    case {binary:match(Host, <<":">>), binary:match(Host, <<"[">>)} of
        {{_, _}, nomatch} -> <<"[", Host/binary, "]">>;
        _ -> Host
    end.

strip_trailing_slash(<<>>) ->
    <<>>;
strip_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.

authenticate_manager(Req, Mutation) ->
    %% Key administration requires the managed DamageBDD account identity.
    %% Ollama API keys themselves never authorize creation/rotation/revocation.
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
            actor(damage_auth:resolve_oauth(Token, #{}));
        _ when Mutation =:= false -> actor(damage_auth:authenticate(Req, #{}));
        _ ->
            {error, explicit_bearer_required}
    end.

actor({ok, #{auth_mode := custodial} = Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        Owner when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        _ -> {error, authenticated_account_required}
    end;
actor(_) ->
    {error, managed_account_required}.

with_json_body(Req0, State, Fun) ->
    case read_json_body(Req0) of
        {ok, Body, Req} -> Fun(Body, Req);
        {error, Code, Why, Req} -> respond(Req, State, Code, #{ok => false, error => Why})
    end.

with_empty_json_body(Req0, State, Fun) ->
    case read_json_body(Req0) of
        {ok, Body, Req} when map_size(Body) =:= 0 -> Fun(Req);
        {ok, _, Req} -> respond(Req, State, 400, #{ok => false, error => unexpected_fields});
        {error, Code, Why, Req} -> respond(Req, State, Code, #{ok => false, error => Why})
    end.

read_json_body(Req0) ->
    case cowboy_req:header(<<"content-type">>, Req0, <<>>) of
        <<>> ->
            {ok, #{}, Req0};
        <<"application/json", _/binary>> ->
            case cowboy_req:read_body(Req0, #{length => ?MAX_BODY, period => 5000}) of
                {ok, Bytes, Req} when byte_size(Bytes) =< ?MAX_BODY ->
                    case Bytes of
                        <<>> -> {ok, #{}, Req};
                        _ -> decode_body(Bytes, Req)
                    end;
                {_, _, Req} ->
                    {error, 413, request_too_large, Req}
            end;
        _ ->
            {error, 415, json_required, Req0}
    end.

decode_body(Bytes, Req) ->
    try jsx:decode(Bytes, [return_maps]) of
        M when is_map(M) -> {ok, M, Req};
        _ -> {error, 400, json_object_required, Req}
    catch
        _:_ -> {error, 400, invalid_json, Req}
    end.

result({ok, Value}, Req, State) ->
    respond(Req, State, 200, #{ok => true, data => Value});
result({error, key_not_found}, Req, State) ->
    respond(Req, State, 404, #{ok => false, error => key_not_found});
result({error, Why}, Req, State) ->
    respond(Req, State, 409, #{ok => false, error => Why});
result(_, Req, State) ->
    respond(Req, State, 503, #{ok => false, error => unexpected_result}).

respond(Req0, State, Code, Value) ->
    Req = cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"pragma">> => <<"no-cache">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(ecai_index_job_codec:externalize(Value)),
        Req0
    ),
    {ok, Req, State}.

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
