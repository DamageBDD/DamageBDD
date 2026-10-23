-module(ecai_ollama_client).

-export([
    generate_json/1,
    generate_json/2,
    generate_text/1,
    generate_text/2,
    generate_json_with_meta/2,
    generate_text_with_meta/2,
    native_chat_with_meta/2,
    evaluation_chat_with_meta/2,
    native_generate_with_meta/2,
    tags/1,
    probe/1,
    defaults/0,
    public_auth/1
]).

-ifdef(TEST).
-export([decode_json/1, ollama_generation_options/1, anthropic_payload/3,
         decode_anthropic_response/3, anthropic_headers/1, anthropic_native_options/1]).
-endif.

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 11434).
-define(DEFAULT_MODEL, "qwen3-coder:30b").
-define(DEFAULT_TIMEOUT, 180000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

%% Backwards-compatible raw inference client. Despite the historical module name,
%% requests can target native Ollama, OpenAI Responses or Anthropic Messages. Pool
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

native_chat_with_meta(Request, Opts) when is_map(Request), is_map(Opts) ->
    native_request(chat, Request, Opts).

%% Evaluations preserve explicit role messages and bypass pool retries/fallback.
%% The caller supplies a node-policy-resolved target; never browser host/options.
evaluation_chat_with_meta(Messages, Opts0) when is_list(Messages), is_map(Opts0) ->
    Opts = provider_defaults(Opts0#{response_decode => json_binary, store => false}),
    case maps:get(provider, Opts) of
        ollama ->
            Request = #{<<"messages">> => Messages, <<"model">> => to_binary(maps:get(model, Opts)),
                        <<"options">> => ollama_generation_options(Opts), <<"stream">> => false},
            case ollama_native_request(chat, Request, Opts) of
                {ok, Json, Meta} ->
                    Message = maps:get(<<"message">>, Json, #{}),
                    case maps:get(<<"tool_calls">>, Message, []) of
                        [] -> {ok, maps:get(<<"content">>, Message, <<>>), Meta};
                        _ -> {error, evaluation_native_tools_not_supported}
                    end;
                Error -> Error
            end;
        openai -> openai_request(Messages, false, Opts);
        anthropic -> anthropic_request(Messages, false, Opts);
        _ -> {error, evaluation_provider_not_supported}
    end.

native_generate_with_meta(Request, Opts) when is_map(Request), is_map(Opts) ->
    native_request(generate, Request, Opts).

%% Historical API retained for Ollama callers.
tags(Opts) when is_map(Opts) ->
    probe(Opts#{provider => ollama}).

probe(Opts0) when is_map(Opts0) ->
    Opts = provider_defaults(Opts0),
    case maps:get(provider, Opts) of
        ollama -> ollama_probe(Opts);
        openai -> openai_probe(Opts);
        anthropic -> anthropic_probe(Opts);
        Provider -> {error, {unsupported_inference_provider, Provider}}
    end.

request(Prompt0, JsonMode, Opts0) ->
    Opts = provider_defaults(Opts0),
    Prompt = to_binary(Prompt0),
    case maps:get(provider, Opts) of
        ollama -> ollama_request(Prompt, JsonMode, Opts);
        openai -> openai_request(Prompt, JsonMode, Opts);
        anthropic -> anthropic_request(Prompt, JsonMode, Opts);
        Provider -> {error, {unsupported_inference_provider, Provider}}
    end.

native_request(Kind, Request0, Opts0) ->
    Opts = provider_defaults(Opts0),
    case maps:get(provider, Opts) of
        ollama -> ollama_native_request(Kind, Request0, Opts);
        openai -> openai_native_request(Kind, Request0, Opts);
        anthropic ->
            case anthropic_native_options(Request0) of
                ok -> anthropic_native_request(Kind, Request0, Opts);
                {error, _} = Error -> Error
            end;
        Provider -> {error, {unsupported_inference_provider, Provider}}
    end.

provider_defaults(Opts0) ->
    Provider = normalize_provider(maps:get(provider, Opts0, ollama)),
    Base =
        case Provider of
            ollama -> defaults();
            openai -> openai_defaults();
            anthropic -> anthropic_defaults();
            _ -> #{}
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

anthropic_defaults() ->
    #{provider => anthropic, host => "api.anthropic.com", port => 443,
      transport => tls, proxy => direct, base_path => "/v1",
      timeout => ?DEFAULT_TIMEOUT, connect_timeout => ?DEFAULT_CONNECT_TIMEOUT,
      auth => #{type => bearer_env, env => "ANTHROPIC_API_KEY"},
      max_output_tokens => 4096, max_response_bytes => 8388608,
      response_decode => json_binary}.

normalize_provider(anthropic) -> anthropic;
normalize_provider(<<"anthropic">>) -> anthropic;
normalize_provider("anthropic") -> anthropic;
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
                <<"options">> => ollama_generation_options(Opts)
            },
            WithSystem = maybe_put_system(Base, <<"system">>, Opts),
            BodyMap =
                case JsonMode of
                    true -> WithSystem#{<<"format">> => maps:get(format, Opts, <<"json">>)};
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

ollama_native_request(Kind, Request0, Opts) ->
    case auth_headers(Opts) of
        {error, _} = Error ->
            Error;
        {ok, AuthHeaders} ->
            Model = to_binary(maps:get(model, Opts)),
            Request1 = json_put(<<"model">>, Model, Request0),
            %% Pool requests are deliberately non-streaming. The HTTP wrapper
            %% can still emit Ollama NDJSON, but backend capacity remains held
            %% until the complete provider response is known and accounted for.
            Request = json_put(<<"stream">>, false, Request1),
            Headers = [
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json">>}
                | AuthHeaders
            ],
            Path =
                case Kind of
                    chat -> "/api/chat";
                    generate -> "/api/generate"
                end,
            Started = erlang:monotonic_time(millisecond),
            case
                damage_gun:post(
                    maps:get(host, Opts),
                    maps:get(port, Opts),
                    Path,
                    Headers,
                    jsx:encode(Request),
                    request_opts(Opts, maps:get(timeout, Opts))
                )
            of
                {ok, #{status := Status, json := Json, body := _}} when
                    Status >= 200, Status < 300, is_map(Json)
                ->
                    Normalized = json_binary_keys(Json),
                    {ok, Normalized, native_ollama_meta(Normalized, elapsed_ms(Started))};
                {ok, #{status := Status, json := Json, body := RawBody}} ->
                    {error, {ollama_http_status, Status, provider_error(Json, RawBody)}};
                {ok, #{status := Status, body := RawBody}} ->
                    {error, {ollama_http_status, Status, RawBody}};
                {error, Reason} ->
                    {error, {ollama_request_failed, Reason}}
            end
    end.

openai_native_request(chat, Request, Opts0) ->
    case native_chat_input(Request) of
        {error, _} = Error ->
            Error;
        {ok, Prompt, System} ->
            Opts = maybe_native_system(Opts0, System),
            case openai_request(Prompt, false, provider_defaults(Opts)) of
                {ok, Text, Meta} ->
                    {ok, synthetic_chat_response(Text, Meta, maps:get(model, Opts)), Meta};
                {error, _} = Error ->
                    Error
            end
    end;
openai_native_request(generate, Request, Opts0) ->
    case mget(<<"prompt">>, Request, undefined) of
        Prompt when is_binary(Prompt) ->
            System = mget(<<"system">>, Request, <<>>),
            Opts = maybe_native_system(Opts0, System),
            case openai_request(Prompt, false, provider_defaults(Opts)) of
                {ok, Text, Meta} ->
                    {ok, synthetic_generate_response(Text, Meta, maps:get(model, Opts)), Meta};
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, invalid_native_generate_prompt}
    end.

native_chat_input(Request) ->
    case mget(<<"tools">>, Request, []) of
        [] -> native_chat_messages(mget(<<"messages">>, Request, []));
        _ -> {error, {unsupported_native_option, openai, tools}}
    end.

native_chat_messages(Messages) when is_list(Messages) ->
    Systems = [
        native_message_content(M)
     || M <- Messages,
        is_map(M),
        mget(<<"role">>, M, <<>>) =:= <<"system">>
    ],
    Conversation = [
        native_message_line(M)
     || M <- Messages,
        is_map(M),
        mget(<<"role">>, M, <<>>) =/= <<"system">>
    ],
    case [L || L <- Conversation, byte_size(L) > 0] of
        [] ->
            {error, invalid_native_chat_messages};
        Lines ->
            {ok, iolist_to_binary(lists:join(<<"\n">>, Lines)),
                iolist_to_binary(lists:join(<<"\n\n">>, Systems))}
    end;
native_chat_messages(_) ->
    {error, invalid_native_chat_messages}.

native_message_line(Message) ->
    Role = to_binary(mget(<<"role">>, Message, <<"user">>)),
    Content = native_message_content(Message),
    case Content of
        <<>> -> <<>>;
        _ -> <<Role/binary, ": ", Content/binary>>
    end.

native_message_content(Message) ->
    case mget(<<"content">>, Message, <<>>) of
        Content when is_binary(Content) -> Content;
        Parts when is_list(Parts) ->
            Text = [to_binary(mget(<<"text">>, P, <<>>)) || P <- Parts, is_map(P)],
            iolist_to_binary(lists:join(<<"\n">>, Text));
        Other ->
            to_binary(Other)
    end.

maybe_native_system(Opts, <<>>) -> Opts;
maybe_native_system(Opts, System) when is_binary(System) -> Opts#{system => System};
maybe_native_system(Opts, _) -> Opts.

synthetic_chat_response(Text, Meta, Model0) ->
    Base = synthetic_response_base(Meta, Model0),
    Base#{<<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Text}}.

synthetic_generate_response(Text, Meta, Model0) ->
    Base = synthetic_response_base(Meta, Model0),
    Base#{<<"response">> => Text}.

synthetic_response_base(Meta, Model0) ->
    WallMs = maps:get(wall_duration_ms, Meta, 0),
    #{
        <<"model">> => to_binary(Model0),
        <<"created_at">> => now_iso8601(),
        <<"done">> => true,
        <<"done_reason">> => <<"stop">>,
        <<"total_duration">> => max(0, WallMs) * 1000000,
        <<"load_duration">> => 0,
        <<"prompt_eval_count">> => int_or_zero(maps:get(input_tokens, Meta, 0)),
        <<"prompt_eval_duration">> => 0,
        <<"eval_count">> => int_or_zero(maps:get(output_tokens, Meta, 0)),
        <<"eval_duration">> => max(0, WallMs) * 1000000
    }.

native_ollama_meta(Json, WallMs) ->
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

ollama_generation_options(Opts) ->
    %% Only known native options are serialized; transport/auth maps never leak.
    Base0 = #{<<"temperature">> => maps:get(temperature, Opts, 0)},
    Keys = [top_p, top_k, min_p, seed, repeat_penalty, num_ctx],
    Base = lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Opts) of
            {ok, Value} when is_number(Value) -> Acc#{atom_to_binary(Key, utf8) => Value};
            _ -> Acc
        end
    end, Base0, Keys),
    case maps:get(max_output_tokens, Opts, undefined) of
        N when is_integer(N), N > 0 -> Base#{<<"num_predict">> => N};
        _ -> Base
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
        decode => maps:get(response_decode, Opts, json),
        max_response_bytes => maps:get(max_response_bytes, Opts, infinity),
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

default_auth(anthropic) -> #{type => bearer_env, env => "ANTHROPIC_API_KEY"};
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
    case byte_size(Token) > 0 andalso byte_size(Token) =< 8192 andalso
         binary:match(Token, [<<"\r">>, <<"\n">>, <<0>>]) =:= nomatch of
        true -> {ok, [{<<"authorization">>, <<"Bearer ", Token/binary>>}]};
        false -> {error, invalid_bearer_token}
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
public_auth(_) ->
    #{type => unknown}.

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
                modified_at => mget(<<"modified_at">>, M, undefined),
                details => json_binary_keys(mget(<<"details">>, M, #{})),
                capabilities => json_binary_keys(mget(<<"capabilities">>, M, []))
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

json_put(Key, Value, Map0) when is_binary(Key), is_map(Map0) ->
    Map1 =
        case binary_key_atom(Key) of
            undefined -> Map0;
            AtomKey -> maps:remove(AtomKey, Map0)
        end,
    maps:put(Key, Value, Map1).

binary_key_atom(<<"model">>) -> model;
binary_key_atom(<<"stream">>) -> stream;
binary_key_atom(_) -> undefined.

json_binary_keys(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_binary_keys(V)} || {K, V} <- maps:to_list(Map)]);
json_binary_keys(List) when is_list(List) ->
    [json_binary_keys(V) || V <- List];
json_binary_keys(Value) ->
    Value.

json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_list(K) -> unicode:characters_to_binary(K);
json_key(K) -> to_binary(K).

int_or_zero(I) when is_integer(I), I >= 0 -> I;
int_or_zero(_) -> 0.

now_iso8601() ->
    to_binary(
        calendar:system_time_to_rfc3339(erlang:system_time(second), [
            {unit, second}, {offset, "Z"}
        ])
    ).

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


%% Native Anthropic Messages adapter. No tools, arbitrary headers or browser
%% credentials. The shared env/file/node-vault resolver supplies x-api-key.
anthropic_headers(Opts) ->
    case resolve_auth(maps:get(auth, Opts, default_auth(anthropic))) of
        {ok, [{<<"authorization">>, <<"Bearer ", Key/binary>>}]} ->
            {ok, [{<<"x-api-key">>, Key}, {<<"anthropic-version">>, <<"2023-06-01">>},
                  {<<"accept">>, <<"application/json">>}]};
        {ok, _} -> {error, anthropic_api_key_required};
        {error, _} = Error -> Error
    end.

anthropic_probe(Opts) ->
    case anthropic_headers(Opts) of
        {ok, Headers} ->
            case damage_gun:get(maps:get(host, Opts), maps:get(port, Opts),
                    api_path(Opts, "/models?limit=1000"), Headers,
                    request_opts(Opts, maps:get(health_timeout, Opts, 5000))) of
                {ok, #{status := 200, json := #{<<"data">> := Entries} = Json}}
                  when is_list(Entries) ->
                    %% Never treat an incomplete list as authoritative availability.
                    case maps:get(<<"has_more">>, Json, false) of
                        true -> {error, anthropic_model_list_incomplete};
                        false ->
                            Models = maps:from_list([{Id, #{provider => anthropic,
                                digest => <<>>, created => maps:get(<<"created_at">>, M, undefined)}}
                                || M <- Entries, is_map(M),
                                   Id <- [maps:get(<<"id">>, M, undefined)], is_binary(Id)]),
                            {ok, #{provider => anthropic, models => Models}}
                    end;
                {ok, #{status := Status}} -> {error, {anthropic_http_status, Status}};
                {error, Reason} -> {error, {anthropic_request_failed, Reason}}
            end;
        Error -> Error
    end.

anthropic_request(Prompt, JsonMode, Opts) ->
    case {anthropic_headers(Opts), anthropic_payload(Prompt, JsonMode, Opts)} of
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error;
        {{ok, Headers}, {ok, Payload}} ->
            Started = erlang:monotonic_time(millisecond),
            case damage_gun:post(maps:get(host, Opts), maps:get(port, Opts),
                    api_path(Opts, "/messages"),
                    [{<<"content-type">>, <<"application/json">>} | Headers],
                    jsx:encode(Payload), request_opts(Opts, maps:get(timeout, Opts))) of
                {ok, #{status := Status, json := Json}} when Status >= 200, Status < 300 ->
                    case decode_anthropic_response(Json, elapsed_ms(Started), Opts) of
                        {ok, Text, Meta} -> finish_decoded_response(JsonMode, Text, Meta);
                        Error -> Error
                    end;
                {ok, #{status := Status}} -> {error, {anthropic_http_status, Status}};
                {error, Reason} -> {error, {anthropic_request_failed, Reason}}
            end
    end.

anthropic_payload(Prompt, JsonMode, Opts) ->
    try
        {Messages, Systems} = anthropic_messages(Prompt),
        Model = to_binary(maps:get(model, Opts)),
        true = byte_size(Model) > 0,
        Max = maps:get(max_output_tokens, Opts, 4096),
        true = is_integer(Max) andalso Max > 0,
        System0 = to_binary(maps:get(system, Opts, <<>>)),
        Hint = case JsonMode of
            true -> <<"Return only one valid JSON object. No markdown or commentary.">>;
            false -> <<>>
        end,
        System = iolist_to_binary(lists:join(<<"\n\n">>,
            [S || S <- [System0 | Systems] ++ [Hint], S =/= <<>>])),
        Base = #{<<"model">> => Model, <<"max_tokens">> => Max,
                 <<"messages">> => Messages, <<"stream">> => false},
        WithSystem = case System of <<>> -> Base; _ -> Base#{<<"system">> => System} end,
        WithTemp = case maps:get(temperature, Opts, undefined) of
            undefined -> WithSystem;
            T when is_number(T), T >= 0, T =< 1 -> WithSystem#{<<"temperature">> => T};
            _ -> throw(invalid_anthropic_temperature)
        end,
        {ok, WithTemp}
    catch
        throw:Why -> {error, Why};
        _:_ -> {error, invalid_anthropic_request}
    end.

anthropic_messages(Prompt) when is_binary(Prompt) ->
    {[#{<<"role">> => <<"user">>, <<"content">> => Prompt}], []};
anthropic_messages(Messages) when is_list(Messages), Messages =/= [] ->
    {Conversation, Systems} = lists:foldl(fun(M, {Cs, Ss}) ->
        true = is_map(M),
        true = maps:get(<<"tool_calls">>, M, []) =:= [],
        true = maps:get(<<"images">>, M, []) =:= [],
        Content = maps:get(<<"content">>, M), true = is_binary(Content),
        case maps:get(<<"role">>, M) of
            <<"system">> -> {Cs, [Content | Ss]};
            <<"developer">> -> {Cs, [Content | Ss]};
            R when R =:= <<"user">>; R =:= <<"assistant">> ->
                {[#{<<"role">> => R, <<"content">> => Content} | Cs], Ss};
            _ -> throw(anthropic_tools_not_supported)
        end
    end, {[], []}, Messages),
    true = Conversation =/= [],
    {lists:reverse(Conversation), lists:reverse(Systems)}.

decode_anthropic_response(#{<<"stop_reason">> := <<"max_tokens">>}, _, _) ->
    {error, anthropic_truncated};
decode_anthropic_response(#{<<"stop_reason">> := Stop, <<"content">> := Blocks} = Json,
                         WallMs, _Opts)
  when (Stop =:= <<"end_turn">> orelse Stop =:= <<"stop_sequence">>), is_list(Blocks) ->
    case Blocks =/= [] andalso lists:all(fun
            (#{<<"type">> := <<"text">>, <<"text">> := T}) when is_binary(T) -> true;
            (_) -> false
         end, Blocks) of
        true ->
            Text = iolist_to_binary([maps:get(<<"text">>, B) || B <- Blocks]),
            Usage = maps:get(<<"usage">>, Json, #{}),
            Meta = #{provider => anthropic, model => maps:get(<<"model">>, Json, <<>>),
                response_id => maps:get(<<"id">>, Json, undefined), done_reason => Stop,
                input_tokens => maps:get(<<"input_tokens">>, Usage, undefined),
                output_tokens => maps:get(<<"output_tokens">>, Usage, undefined),
                wall_duration_ms => WallMs},
            case Text of <<>> -> {error, anthropic_empty_output}; _ -> {ok, Text, Meta} end;
        false -> {error, anthropic_unsupported_content}
    end;
decode_anthropic_response(_, _, _) -> {error, anthropic_invalid_response}.

%% Reject native features this text-only adapter cannot faithfully translate.
%% Connection options, not unvalidated native payload options, govern Claude.
anthropic_native_options(Request) ->
    Unsupported = [<<"tools">>, <<"images">>, <<"options">>, <<"format">>,
                   <<"context">>, <<"suffix">>, <<"raw">>, <<"think">>],
    case [K || K <- Unsupported,
               not lists:member(mget(K, Request, undefined), [undefined, null, false, [], #{}, <<>>])] of
        [] -> ok;
        [K | _] -> {error, {unsupported_native_option, anthropic, K}}
    end.

anthropic_native_request(chat, Request, Opts0) ->
    case mget(<<"tools">>, Request, []) of
        [] ->
            Opts = maybe_native_system(Opts0, mget(<<"system">>, Request, <<>>)),
            case anthropic_request(mget(<<"messages">>, Request, []), false, Opts) of
                {ok, Text, Meta} ->
                    {ok, synthetic_chat_response(Text, Meta, maps:get(model, Opts)), Meta};
                Error -> Error
            end;
        _ -> {error, anthropic_tools_not_supported}
    end;
anthropic_native_request(generate, Request, Opts0) ->
    case mget(<<"prompt">>, Request, undefined) of
        Prompt when is_binary(Prompt) ->
            Opts = maybe_native_system(Opts0, mget(<<"system">>, Request, <<>>)),
            case anthropic_request(Prompt, false, Opts) of
                {ok, Text, Meta} ->
                    {ok, synthetic_generate_response(Text, Meta, maps:get(model, Opts)), Meta};
                Error -> Error
            end;
        _ -> {error, invalid_native_generate_prompt}
    end.
