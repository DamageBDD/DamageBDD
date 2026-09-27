-module(ecai_ollama_client).

-export([
    generate_json/1,
    generate_json/2,
    generate_text/1,
    generate_text/2,
    defaults/0
]).

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 11434).
-define(DEFAULT_MODEL, "qwen3-coder:30b").
-define(DEFAULT_TIMEOUT, 180000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

defaults() ->
    #{
        host => application:get_env(ecai, code_ollama_host, ?DEFAULT_HOST),
        port => application:get_env(ecai, code_ollama_port, ?DEFAULT_PORT),
        model => application:get_env(ecai, code_ollama_model, ?DEFAULT_MODEL),
        timeout => application:get_env(ecai, code_ollama_timeout_ms, ?DEFAULT_TIMEOUT),
        connect_timeout => application:get_env(ecai, code_ollama_connect_timeout_ms,
                                               ?DEFAULT_CONNECT_TIMEOUT)
    }.

generate_json(Prompt) ->
    generate_json(Prompt, #{}).

generate_json(Prompt, Opts) when is_map(Opts) ->
    request(Prompt, true, Opts).

generate_text(Prompt) ->
    generate_text(Prompt, #{}).

generate_text(Prompt, Opts) when is_map(Opts) ->
    request(Prompt, false, Opts).

request(Prompt0, JsonMode, Opts0) ->
    Opts = maps:merge(defaults(), Opts0),
    Prompt = to_binary(Prompt0),
    Base = #{
        <<"model">> => to_binary(maps:get(model, Opts)),
        <<"prompt">> => Prompt,
        <<"stream">> => false,
        <<"options">> => #{<<"temperature">> => maps:get(temperature, Opts, 0)}
    },
    BodyMap = case JsonMode of
        true -> Base#{<<"format">> => <<"json">>};
        false -> Base
    end,
    Body = jsx:encode(BodyMap),
    case damage_gun:post(
        maps:get(host, Opts),
        maps:get(port, Opts),
        "/api/generate",
        [{<<"content-type">>, <<"application/json">>}],
        Body,
        #{
            timeout => maps:get(timeout, Opts),
            connect_timeout => maps:get(connect_timeout, Opts),
            decode => json,
            proxy => direct,
            transport => tcp
        }
    ) of
        {ok, #{status := Status, json := Json, body := RawBody}}
          when Status >= 200, Status < 300 ->
            decode_response(JsonMode, Json, RawBody);
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {ollama_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {ollama_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {ollama_request_failed, Reason}}
    end.

decode_response(JsonMode, Json, RawBody) when is_map(Json) ->
    case mget(<<"response">>, Json, undefined) of
        Response when is_binary(Response) ->
            case JsonMode of
                false -> {ok, Response};
                true -> decode_json(Response)
            end;
        undefined -> {error, {missing_ollama_response, Json, RawBody}};
        Other -> {error, {bad_ollama_response, Other, Json}}
    end;
decode_response(_JsonMode, Json, RawBody) ->
    {error, {bad_ollama_generate_json, Json, RawBody}}.

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

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F) -> float_to_binary(F, [compact]);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
