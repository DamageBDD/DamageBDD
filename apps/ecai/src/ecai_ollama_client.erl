-module(ecai_ollama_client).

-export([
    generate_json/1,
    generate_json/2,
    generate_text/1,
    generate_text/2,
    generate_json_with_meta/2,
    generate_text_with_meta/2,
    tags/1,
    defaults/0
]).

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 11434).
-define(DEFAULT_MODEL, "qwen3-coder:30b").
-define(DEFAULT_TIMEOUT, 180000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

%% Raw, endpoint-aware Ollama HTTP client. Cluster selection belongs in
%% ecai_ollama_pool; this module intentionally knows nothing about scheduling.

defaults() ->
    #{
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

tags(Opts0) when is_map(Opts0) ->
    Opts = maps:merge(defaults(), Opts0),
    case damage_gun:get(
        maps:get(host, Opts),
        maps:get(port, Opts),
        "/api/tags",
        [{<<"accept">>, <<"application/json">>}],
        request_opts(Opts, maps:get(health_timeout, Opts, 5000))
    ) of
        {ok, #{status := Status, json := Json, body := RawBody}}
          when Status >= 200, Status < 300 ->
            decode_tags(Json, RawBody);
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {ollama_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {ollama_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {ollama_request_failed, Reason}}
    end.

request(Prompt0, JsonMode, Opts0) ->
    Opts = maps:merge(defaults(), Opts0),
    Prompt = to_binary(Prompt0),
    Base = #{
        <<"model">> => to_binary(maps:get(model, Opts)),
        <<"prompt">> => Prompt,
        <<"stream">> => false,
        <<"options">> => #{<<"temperature">> => maps:get(temperature, Opts, 0)}
    },
    BodyMap =
        case JsonMode of
            true -> Base#{<<"format">> => <<"json">>};
            false -> Base
        end,
    Body = jsx:encode(BodyMap),
    Started = erlang:monotonic_time(millisecond),
    case damage_gun:post(
        maps:get(host, Opts),
        maps:get(port, Opts),
        "/api/generate",
        [{<<"content-type">>, <<"application/json">>}],
        Body,
        request_opts(Opts, maps:get(timeout, Opts))
    ) of
        {ok, #{status := Status, json := Json, body := RawBody}}
          when Status >= 200, Status < 300 ->
            decode_response(JsonMode, Json, RawBody, elapsed_ms(Started));
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {ollama_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {ollama_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {ollama_request_failed, Reason}}
    end.

request_opts(Opts, Timeout) ->
    #{
        timeout => Timeout,
        connect_timeout => maps:get(connect_timeout, Opts),
        decode => json,
        proxy => maps:get(proxy, Opts, direct),
        transport => maps:get(transport, Opts, tcp)
    }.

decode_response(JsonMode, Json, RawBody, WallMs) when is_map(Json) ->
    case mget(<<"response">>, Json, undefined) of
        Response when is_binary(Response) ->
            Meta = response_meta(Json, WallMs),
            case JsonMode of
                false -> {ok, Response, Meta};
                true ->
                    case decode_json(Response) of
                        {ok, Value} -> {ok, Value, Meta};
                        {error, _} = Error -> Error
                    end
            end;
        undefined -> {error, {missing_ollama_response, Json, RawBody}};
        Other -> {error, {bad_ollama_response, Other, Json}}
    end;
decode_response(_JsonMode, Json, RawBody, _WallMs) ->
    {error, {bad_ollama_generate_json, Json, RawBody}}.

response_meta(Json, WallMs) ->
    #{
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

decode_tags(Json, _RawBody) when is_map(Json) ->
    Models0 = mget(<<"models">>, Json, []),
    Models = maps:from_list([
        begin
            Name = to_binary(mget(<<"name">>, M, mget(<<"model">>, M, <<>>))),
            {Name, #{
                digest => to_binary(mget(<<"digest">>, M, <<>>)),
                size => mget(<<"size">>, M, undefined),
                modified_at => mget(<<"modified_at">>, M, undefined)
            }}
        end
     || M <- Models0,
        is_map(M),
        to_binary(mget(<<"name">>, M, mget(<<"model">>, M, <<>>))) =/= <<>>
    ]),
    {ok, #{models => Models}};
decode_tags(Json, RawBody) ->
    {error, {bad_ollama_tags_json, Json, RawBody}}.

decode_json(Response) ->
    try jsx:decode(Response, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {response_not_json_object, Other}}
    catch
        Class:Reason -> {error, {invalid_json_response, Class, Reason, Response}}
    end.

ollama_error(Json, RawBody) when is_map(Json) ->
    mget(<<"error">>, Json, RawBody);
ollama_error(_Json, RawBody) ->
    RawBody.

elapsed_ms(Started) ->
    max(0, erlang:monotonic_time(millisecond) - Started).

mget(Key, Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) -> Default.

to_binary(undefined) -> <<>>;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F) -> float_to_binary(F, [compact]);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
