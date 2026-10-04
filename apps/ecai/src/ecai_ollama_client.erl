-module(ecai_ollama_client).

-export([
    generate_json/1,
    generate_json/2,
    generate_text/1,
    generate_text/2,
    generate_json_with_meta/2,
    generate_text_with_meta/2,
    tags/1,
    probe/1,
    defaults/0,
    public_auth/1
]).

-ifdef(TEST).
-export([decode_json/1]).
-endif.

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 11434).
-define(DEFAULT_MODEL, "qwen3-coder:30b").
-define(DEFAULT_TIMEOUT, 180000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

%% Backwards-compatible raw inference client. Despite the historical module name,
%% requests can target either native Ollama or the OpenAI Responses API. Pool
%% selection belongs in ecai_ollama_pool.

defaults() ->
    #{
        provider => ollama,
        host => application:get_env(ecai, code_ollama_host, ?DEFAULT_HOST),
        port => application:get_env(ecai, code_ollama_port, ?DEFAULT_PORT),
        model => application:get_env(ecai, code_ollama_model, ?DEFAULT_MODEL),
        timeout => application:get_env(ecai, code_ollama_timeout_ms, ?DEFAULT_TIMEOUT),
        connect_timeout => application:get_env(
            ecai, code_ollama_connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT
        ),
        transport => tcp,
        proxy => direct
    }.

generate_json(Prompt) ->
    generate_json(Prompt, #{}).

generate_json(Prompt, Opts) when is_map(Opts) ->
    case generate_json_with_meta(Prompt, Opts) of
        {ok, Value, _Meta} -> {ok, Value};
        {error, _} = Error -> Error
    end.

generate_text(Prompt) ->
    generate_text(Prompt, #{}).

generate_text(Prompt, Opts) when is_map(Opts) ->
    case generate_text_with_meta(Prompt, Opts) of
        {ok, Value, _Meta} -> {ok, Value};
        {error, _} = Error -> Error
    end.

generate_json_with_meta(Prompt, Opts) when is_map(Opts) ->
    request(Prompt, true, Opts).

generate_text_with_meta(Prompt, Opts) when is_map(Opts) ->
    request(Prompt, false, Opts).

%% Historical API retained for Ollama callers.
tags(Opts) when is_map(Opts) ->
    probe(Opts#{provider => ollama}).

probe(Opts0) when is_map(Opts0) ->
    Opts = provider_defaults(Opts0),
    case maps:get(provider, Opts) of
        ollama -> ollama_probe(Opts);
        openai -> openai_probe(Opts);
        Provider -> {error, {unsupported_inference_provider, Provider}}
    end.

request(Prompt0, JsonMode, Opts0) ->
    Opts = provider_defaults(Opts0),
    Prompt = to_binary(Prompt0),
    case maps:get(provider, Opts) of
        ollama -> ollama_request(Prompt, JsonMode, Opts);
        openai -> openai_request(Prompt, JsonMode, Opts);
        Provider -> {error, {unsupported_inference_provider, Provider}}
    end.

provider_defaults(Opts0) ->
    Provider = normalize_provider(maps:get(provider, Opts0, ollama)),
    Base =
        case Provider of
            ollama -> defaults();
            openai -> openai_defaults()
        end,
    maps:merge(Base, Opts0#{provider => Provider}).

openai_defaults() ->
    #{
        provider => openai,
        host => "api.openai.com",
        port => 443,
        timeout => application:get_env(ecai, code_openai_timeout_ms, ?DEFAULT_TIMEOUT),
        connect_timeout => application:get_env(
            ecai, code_openai_connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT
        ),
        transport => tls,
        proxy => auto,
        base_path => "/v1",
        auth => #{type => bearer_env, env => "OPENAI_API_KEY"},
        store => false
    }.

normalize_provider(ollama) -> ollama;
normalize_provider(openai) -> openai;
normalize_provider(<<"ollama">>) -> ollama;
normalize_provider(<<"openai">>) -> openai;
normalize_provider("ollama") -> ollama;
normalize_provider("openai") -> openai;
normalize_provider(Other) -> Other.

ollama_probe(Opts) ->
    case auth_headers(Opts) of
        {error, _} = Error ->
            Error;
        {ok, AuthHeaders} ->
            Headers = [{<<"accept">>, <<"application/json">>} | AuthHeaders],
            case
                damage_gun:get(
                    maps:get(host, Opts),
                    maps:get(port, Opts),
                    "/api/tags",
                    Headers,
                    request_opts(Opts, maps:get(health_timeout, Opts, 5000))
                )
            of
                {ok, #{status := Status, json := Json, body := RawBody}} when
                    Status >= 200, Status < 300
                ->
                    decode_ollama_tags(Json, RawBody);
                {ok, #{status := Status, json := Json, body := RawBody}} ->
                    {error, {ollama_http_status, Status, provider_error(Json, RawBody)}};
                {ok, #{status := Status, body := RawBody}} ->
                    {error, {ollama_http_status, Status, RawBody}};
                {error, Reason} ->
                    {error, {ollama_request_failed, Reason}}
            end
    end.

openai_probe(Opts) ->
    case auth_headers(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Headers0} ->
            Headers = [{<<"accept">>, <<"application/json">>} | Headers0],
            Path = api_path(Opts, "/models"),
            case
                damage_gun:get(
                    maps:get(host, Opts),
                    maps:get(port, Opts),
                    Path,
                    Headers,
                    request_opts(Opts, maps:get(health_timeout, Opts, 5000))
                )
            of
                {ok, #{status := Status, json := Json, body := RawBody}} when
                    Status >= 200, Status < 300
                ->
                    decode_openai_models(Json, RawBody);
                {ok, #{status := Status, json := Json, body := RawBody}} ->
                    {error, {openai_http_status, Status, provider_error(Json, RawBody)}};
                {ok, #{status := Status, body := RawBody}} ->
                    {error, {openai_http_status, Status, RawBody}};
                {error, Reason} ->
                    {error, {openai_request_failed, Reason}}
            end
    end.

ollama_request(Prompt, JsonMode, Opts) ->
    case auth_headers(Opts) of
        {error, _} = Error ->
            Error;
        {ok, AuthHeaders} ->
            Base = #{
                <<"model">> => to_binary(maps:get(model, Opts)),
                <<"prompt">> => Prompt,
                <<"stream">> => false,
                <<"options">> => #{<<"temperature">> => maps:get(temperature, Opts, 0)}
            },
            WithSystem = maybe_put_system(Base, <<"system">>, Opts),
            BodyMap =
                case JsonMode of
                    true -> WithSystem#{<<"format">> => <<"json">>};
                    false -> WithSystem
                end,
            Headers = [
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json">>}
                | AuthHeaders
            ],
            Body = jsx:encode(BodyMap),
            Started = erlang:monotonic_time(millisecond),
            case
                damage_gun:post(
                    maps:get(host, Opts),
                    maps:get(port, Opts),
                    "/api/generate",
                    Headers,
                    Body,
                    request_opts(Opts, maps:get(timeout, Opts))
                )
            of
                {ok, #{status := Status, json := Json, body := RawBody}} when
                    Status >= 200, Status < 300
                ->
                    decode_ollama_response(JsonMode, Json, RawBody, elapsed_ms(Started));
                {ok, #{status := Status, json := Json, body := RawBody}} ->
                    {error, {ollama_http_status, Status, provider_error(Json, RawBody)}};
                {ok, #{status := Status, body := RawBody}} ->
                    {error, {ollama_http_status, Status, RawBody}};
                {error, Reason} ->
                    {error, {ollama_request_failed, Reason}}
            end
    end.

openai_request(Prompt, JsonMode, Opts) ->
    case auth_headers(Opts) of
        {error, _} = Error ->
            Error;
        {ok, AuthHeaders} ->
            Base0 = #{
                <<"model">> => to_binary(maps:get(model, Opts)),
                <<"input">> => Prompt,
                <<"store">> => maps:get(store, Opts, false)
            },
            WithSystem = maybe_put_system(Base0, <<"instructions">>, Opts),
            Base1 = maybe_put_openai_reasoning(WithSystem, Opts),
            Base2 = maybe_put_openai_max_output(Base1, Opts),
            Base3 = maybe_put_openai_temperature(Base2, Opts),
            BodyMap =
                case JsonMode of
                    true ->
                        Base3#{
                            <<"text">> => #{
                                <<"format">> => #{<<"type">> => <<"json_object">>}
                            }
                        };
                    false ->
                        Base3
                end,
            Headers = [
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json">>}
                | AuthHeaders
            ],
            Body = jsx:encode(BodyMap),
            Started = erlang:monotonic_time(millisecond),
            case
                damage_gun:post(
                    maps:get(host, Opts),
                    maps:get(port, Opts),
                    api_path(Opts, "/responses"),
                    Headers,
                    Body,
                    request_opts(Opts, maps:get(timeout, Opts))
                )
            of
                {ok, #{status := Status, json := Json, body := RawBody} = HttpResult} when
                    Status >= 200, Status < 300
                ->
                    decode_openai_response(
                        JsonMode, Json, RawBody, elapsed_ms(Started), HttpResult
                    );
                {ok, #{status := Status, json := Json, body := RawBody}} ->
                    {error, {openai_http_status, Status, provider_error(Json, RawBody)}};
                {ok, #{status := Status, body := RawBody}} ->
                    {error, {openai_http_status, Status, RawBody}};
                {error, Reason} ->
                    {error, {openai_request_failed, Reason}}
            end
    end.

%% Preserve a distinct system/instructions channel for permissioned RAG.
maybe_put_system(Body, Key, Opts) ->
    case maps:get(system, Opts, undefined) of
        undefined ->
            Body;
        System when is_binary(System); is_list(System) ->
            Body#{Key => to_binary(System)}
    end.

maybe_put_openai_reasoning(Body, Opts) ->
    case maps:get(reasoning_effort, Opts, undefined) of
        undefined -> Body;
        Effort -> Body#{<<"reasoning">> => #{<<"effort">> => to_binary(Effort)}}
    end.

maybe_put_openai_max_output(Body, Opts) ->
    case maps:get(max_output_tokens, Opts, undefined) of
        N when is_integer(N), N > 0 -> Body#{<<"max_output_tokens">> => N};
        _ -> Body
    end.

%% Do not send a default temperature to OpenAI because some reasoning models do
%% not accept it. Operators can opt in explicitly per node/request.
maybe_put_openai_temperature(Body, Opts) ->
    case maps:find(temperature, Opts) of
        {ok, T} when is_number(T) -> Body#{<<"temperature">> => T};
        _ -> Body
    end.

request_opts(Opts, Timeout) ->
    Transport = maps:get(transport, Opts, tcp),
    Base = #{
        timeout => Timeout,
        connect_timeout => maps:get(connect_timeout, Opts),
        decode => json,
        proxy => maps:get(proxy, Opts, direct),
        transport => Transport
    },
    case {Transport, maps:is_key(tls_opts, Opts)} of
        {tls, false} -> Base#{tls_opts => damage_gun:tls_opts(maps:get(host, Opts))};
        _ -> maps:merge(Base, maps:with([tls_opts], Opts))
    end.

api_path(Opts, Suffix) ->
    Base0 = maps:get(base_path, Opts, "/v1"),
    Base = string:trim(path_to_list(Base0), trailing, "/"),
    Base ++ Suffix.

auth_headers(Opts) ->
    Auth = maps:get(auth, Opts, default_auth(maps:get(provider, Opts, ollama))),
    case resolve_auth(Auth) of
        {error, _} = Error -> Error;
        {ok, AuthHeaders} -> {ok, AuthHeaders ++ optional_openai_headers(Opts)}
    end.

default_auth(openai) -> #{type => bearer_env, env => "OPENAI_API_KEY"};
default_auth(_) -> none.

resolve_auth(none) ->
    {ok, []};
resolve_auth(undefined) ->
    {ok, []};
resolve_auth(#{type := bearer_env, env := Env0}) ->
    Env = path_to_list(Env0),
    case os:getenv(Env) of
        false -> {error, {missing_auth_environment_variable, Env}};
        [] -> {error, {empty_auth_environment_variable, Env}};
        Token -> bearer_header(Token)
    end;
resolve_auth(#{type := bearer_file, path := Path0}) ->
    Path = path_to_list(Path0),
    case file:read_file(Path) of
        {ok, Token0} ->
            Token = trim_binary(Token0),
            case Token of
                <<>> -> {error, {empty_auth_file, Path}};
                _ -> bearer_header(Token)
            end;
        {error, Reason} ->
            {error, {cannot_read_auth_file, Path, Reason}}
    end;
resolve_auth(#{type := bearer_secret, scope := node, name := Name}) ->
    resolve_node_secret_auth(Name);
resolve_auth(#{type := bearer_secret, scope := Scope}) ->
    {error, {unsupported_auth_secret_scope, Scope}};
resolve_auth(#{type := bearer, token := Token}) ->
    bearer_header(Token);
resolve_auth({bearer_env, Env}) ->
    resolve_auth(#{type => bearer_env, env => Env});
resolve_auth({bearer_file, Path}) ->
    resolve_auth(#{type => bearer_file, path => Path});
resolve_auth({bearer_secret, node, Name}) ->
    resolve_auth(#{type => bearer_secret, scope => node, name => Name});
resolve_auth({bearer, Token}) ->
    resolve_auth(#{type => bearer, token => Token});
resolve_auth(Other) ->
    {error, {unsupported_auth_configuration, public_auth(Other)}}.

resolve_node_secret_auth(Name) ->
    try secrets:retrieve_decrypt(node, Name) of
        {ok, Token} ->
            bearer_header(Token);
        error ->
            {error, {auth_secret_not_found, node, normalize_secret_ref(Name)}};
        {error, Reason} ->
            {error, {
                auth_secret_lookup_failed,
                node,
                normalize_secret_ref(Name),
                sanitize_secret_error(Reason)
            }};
        Other ->
            {error, {
                invalid_auth_secret_result,
                node,
                normalize_secret_ref(Name),
                result_tag(Other)
            }}
    catch
        Class:Reason ->
            {error, {
                auth_secret_lookup_exception,
                node,
                normalize_secret_ref(Name),
                Class,
                sanitize_secret_error(Reason)
            }}
    end.

normalize_secret_ref(Name) when is_binary(Name) -> Name;
normalize_secret_ref(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
normalize_secret_ref(Name) when is_list(Name) -> unicode:characters_to_binary(Name);
normalize_secret_ref(_) -> invalid_secret_name.

sanitize_secret_error(Reason) when is_atom(Reason) -> Reason;
sanitize_secret_error({Tag, _}) when is_atom(Tag) -> Tag;
sanitize_secret_error({Tag, _, _}) when is_atom(Tag) -> Tag;
sanitize_secret_error(_) -> secret_lookup_failed.

result_tag(Term) when is_atom(Term) -> Term;
result_tag(Term) when is_binary(Term) -> binary;
result_tag(Term) when is_list(Term) -> list;
result_tag(Term) when is_map(Term) -> map;
result_tag(Term) when is_tuple(Term) -> {tuple, tuple_size(Term)};
result_tag(_) -> other.
bearer_header(Token0) ->
    Token = trim_binary(to_binary(Token0)),
    case Token of
        <<>> -> {error, empty_bearer_token};
        _ -> {ok, [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}
    end.

optional_openai_headers(Opts) ->
    lists:append([
        optional_header(<<"openai-organization">>, organization, organization_env, Opts),
        optional_header(<<"openai-project">>, project, project_env, Opts)
    ]).

optional_header(Name, DirectKey, EnvKey, Opts) ->
    case maps:get(DirectKey, Opts, undefined) of
        undefined ->
            case maps:get(EnvKey, Opts, undefined) of
                undefined ->
                    [];
                Env0 ->
                    Env = path_to_list(Env0),
                    case os:getenv(Env) of
                        false -> [];
                        [] -> [];
                        Value -> [{Name, to_binary(Value)}]
                    end
            end;
        Value ->
            [{Name, to_binary(Value)}]
    end.

public_auth(#{type := bearer, token := _}) ->
    #{type => bearer, token => redacted};
public_auth(#{type := bearer_env} = Auth) ->
    maps:without([token], Auth);
public_auth(#{type := bearer_file} = Auth) ->
    maps:without([token], Auth);
public_auth(#{type := bearer_secret, scope := node, name := Name}) ->
    #{type => bearer_secret, scope => node, name => normalize_secret_ref(Name)};
public_auth({bearer, _}) ->
    #{type => bearer, token => redacted};
public_auth({bearer_env, Env}) ->
    #{type => bearer_env, env => Env};
public_auth({bearer_file, Path}) ->
    #{type => bearer_file, path => Path};
public_auth({bearer_secret, node, Name}) ->
    #{type => bearer_secret, scope => node, name => normalize_secret_ref(Name)};
public_auth(none) ->
    none;
public_auth(undefined) ->
    undefined;
public_auth(Other) ->
    #{type => unknown, value => to_binary(io_lib:format("~p", [Other]))}.

decode_ollama_response(JsonMode, Json, RawBody, WallMs) when is_map(Json) ->
    case mget(<<"response">>, Json, undefined) of
        Response when is_binary(Response) ->
            Meta = ollama_response_meta(Json, WallMs),
            finish_decoded_response(JsonMode, Response, Meta);
        undefined ->
            {error, {missing_ollama_response, Json, RawBody}};
        Other ->
            {error, {bad_ollama_response, Other, Json}}
    end;
decode_ollama_response(_JsonMode, Json, RawBody, _WallMs) ->
    {error, {bad_ollama_generate_json, Json, RawBody}}.

decode_openai_response(JsonMode, Json, RawBody, WallMs, HttpResult) when is_map(Json) ->
    case openai_output_text(Json) of
        {ok, Response} ->
            Meta = openai_response_meta(Json, WallMs, HttpResult),
            finish_decoded_response(JsonMode, Response, Meta);
        {error, Reason} ->
            {error, {bad_openai_response, Reason, Json, RawBody}}
    end;
decode_openai_response(_JsonMode, Json, RawBody, _WallMs, _HttpResult) ->
    {error, {bad_openai_response_json, Json, RawBody}}.

finish_decoded_response(false, Response, Meta) ->
    {ok, Response, Meta};
finish_decoded_response(true, Response, Meta) ->
    case decode_json(Response) of
        {ok, Value} -> {ok, Value, Meta};
        {error, _} = Error -> Error
    end.

openai_output_text(Json) ->
    case mget(<<"output_text">>, Json, undefined) of
        Text when is_binary(Text), byte_size(Text) > 0 -> {ok, Text};
        _ ->
            Output = mget(<<"output">>, Json, []),
            Parts = [
                Text
             || Item <- Output,
                is_map(Item),
                mget(<<"type">>, Item, <<>>) =:= <<"message">>,
                Content <- ensure_list(mget(<<"content">>, Item, [])),
                is_map(Content),
                mget(<<"type">>, Content, <<>>) =:= <<"output_text">>,
                Text <- [mget(<<"text">>, Content, <<>>)],
                is_binary(Text),
                byte_size(Text) > 0
            ],
            case Parts of
                [] -> {error, output_text_not_found};
                _ -> {ok, iolist_to_binary(Parts)}
            end
    end.

ollama_response_meta(Json, WallMs) ->
    #{
        provider => ollama,
        model => to_binary(mget(<<"model">>, Json, <<>>)),
        created_at => mget(<<"created_at">>, Json, undefined),
        done_reason => mget(<<"done_reason">>, Json, undefined),
        total_duration_ns => mget(<<"total_duration">>, Json, undefined),
        load_duration_ns => mget(<<"load_duration">>, Json, undefined),
        prompt_eval_count => mget(<<"prompt_eval_count">>, Json, undefined),
        prompt_eval_duration_ns => mget(<<"prompt_eval_duration">>, Json, undefined),
        eval_count => mget(<<"eval_count">>, Json, undefined),
        eval_duration_ns => mget(<<"eval_duration">>, Json, undefined),
        wall_duration_ms => WallMs
    }.

openai_response_meta(Json, WallMs, HttpResult) ->
    Usage = mget(<<"usage">>, Json, #{}),
    #{
        provider => openai,
        response_id => mget(<<"id">>, Json, undefined),
        model => to_binary(mget(<<"model">>, Json, <<>>)),
        status => mget(<<"status">>, Json, undefined),
        service_tier => mget(<<"service_tier">>, Json, undefined),
        input_tokens => mget(<<"input_tokens">>, Usage, undefined),
        output_tokens => mget(<<"output_tokens">>, Usage, undefined),
        total_tokens => mget(<<"total_tokens">>, Usage, undefined),
        request_id => response_header(<<"x-request-id">>, HttpResult),
        wall_duration_ms => WallMs
    }.

response_header(Name, #{headers := Headers}) when is_list(Headers) ->
    Lower = string:lowercase(binary_to_list(Name)),
    case [V || {K, V} <- Headers, string:lowercase(binary_to_list(to_binary(K))) =:= Lower] of
        [V | _] -> to_binary(V);
        [] -> undefined
    end;
response_header(_Name, _HttpResult) ->
    undefined.

decode_ollama_tags(Json, _RawBody) when is_map(Json) ->
    Models0 = mget(<<"models">>, Json, []),
    Models = maps:from_list([
        begin
            Name = to_binary(mget(<<"name">>, M, mget(<<"model">>, M, <<>>))),
            {Name, #{
                provider => ollama,
                digest => to_binary(mget(<<"digest">>, M, <<>>)),
                size => mget(<<"size">>, M, undefined),
                modified_at => mget(<<"modified_at">>, M, undefined)
            }}
        end
     || M <- Models0,
        is_map(M),
        to_binary(mget(<<"name">>, M, mget(<<"model">>, M, <<>>))) =/= <<>>
    ]),
    {ok, #{provider => ollama, models => Models}};
decode_ollama_tags(Json, RawBody) ->
    {error, {bad_ollama_tags_json, Json, RawBody}}.

decode_openai_models(Json, _RawBody) when is_map(Json) ->
    Models0 = mget(<<"data">>, Json, []),
    Models = maps:from_list([
        begin
            Id = to_binary(mget(<<"id">>, M, <<>>)),
            {Id, #{
                provider => openai,
                digest => <<>>,
                created => mget(<<"created">>, M, undefined),
                owned_by => mget(<<"owned_by">>, M, undefined),
                shutdown_date => mget(<<"shutdown_date">>, M, undefined)
            }}
        end
     || M <- Models0,
        is_map(M),
        to_binary(mget(<<"id">>, M, <<>>)) =/= <<>>
    ]),
    {ok, #{provider => openai, models => Models}};
decode_openai_models(Json, RawBody) ->
    {error, {bad_openai_models_json, Json, RawBody}}.

decode_json(Response0) when is_binary(Response0) ->
    Response = normalize_json_response(Response0),
    try jsx:decode(Response, [return_maps]) of
        Map when is_map(Map) ->
            {ok, Map};
        Other ->
            {error, {response_not_json_object, Other}}
    catch
        Class:Reason ->
            {error, {
                invalid_json_response,
                Class,
                Reason,
                bounded_error_response(Response0)
            }}
    end;
decode_json(Response) ->
    {error, {invalid_json_response_type, response_type(Response)}}.

normalize_json_response(Response0) ->
    Response = trim_binary(Response0),
    case strip_outer_code_fence(Response) of
        {ok, Inner} -> trim_binary(Inner);
        no_fence -> Response
    end.

strip_outer_code_fence(<<"```json", Rest/binary>>) ->
    strip_code_fence_body(Rest);
strip_outer_code_fence(<<"```JSON", Rest/binary>>) ->
    strip_code_fence_body(Rest);
strip_outer_code_fence(<<"```", Rest/binary>>) ->
    strip_code_fence_body(Rest);
strip_outer_code_fence(_) ->
    no_fence.

strip_code_fence_body(Rest0) ->
    Rest = trim_leading_newline(trim_binary(Rest0)),
    case byte_size(Rest) >= 3 of
        false ->
            no_fence;
        true ->
            PayloadSize = byte_size(Rest) - 3,
            case Rest of
                <<Payload:PayloadSize/binary, "```">> ->
                    {ok, trim_binary(Payload)};
                _ ->
                    no_fence
            end
    end.

trim_leading_newline(<<"\r\n", Rest/binary>>) -> Rest;
trim_leading_newline(<<"\n", Rest/binary>>) -> Rest;
trim_leading_newline(Bin) -> Bin.

bounded_error_response(Response) when is_binary(Response) ->
    Max = 4096,
    case byte_size(Response) > Max of
        true ->
            <<Prefix:Max/binary, _/binary>> = Response,
            <<Prefix/binary, "...<truncated>">>;
        false ->
            Response
    end;
bounded_error_response(Response) ->
    Response.

response_type(Value) when is_binary(Value) -> binary;
response_type(Value) when is_list(Value) -> list;
response_type(Value) when is_map(Value) -> map;
response_type(Value) when is_tuple(Value) -> tuple;
response_type(Value) when is_atom(Value) -> atom;
response_type(Value) when is_number(Value) -> number;
response_type(_) -> other.

provider_error(Json, RawBody) when is_map(Json) ->
    case mget(<<"error">>, Json, undefined) of
        #{<<"message">> := Message} -> Message;
        #{message := Message} -> Message;
        undefined -> RawBody;
        Error -> Error
    end;
provider_error(_Json, RawBody) ->
    RawBody.

elapsed_ms(Started) ->
    max(0, erlang:monotonic_time(millisecond) - Started).

trim_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

mget(Key, Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) ->
    Default.

path_to_list(B) when is_binary(B) -> binary_to_list(B);
path_to_list(L) when is_list(L) -> L;
path_to_list(A) when is_atom(A) -> atom_to_list(A).

to_binary(undefined) -> <<>>;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F) -> float_to_binary(F, [compact]);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
