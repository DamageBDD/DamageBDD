%% SPDX-License-Identifier: Apache-2.0
%% Minimal OpenAI-compatible Chat Completions + Embeddings adapter.
%% Uses damage_gun for connections/TLS/proxy policy; reads bounded chunks itself.
-module(damage_ai_openai).
-behaviour(damage_ai_backend).
-export([invoke/2, endpoint/1, payload/2, decode/2]).
-import(damage_ai, [require/2, text/1]).

-spec invoke(list(), map()) -> {ok, map()} | {error, term()}.
invoke(P, Request) ->
    damage_ai:safe(fun() ->
        Deadline = erlang:monotonic_time(millisecond) +
                   proplists:get_value(timeout_ms, P, 30000),
        E = endpoint(P),
        {Suffix, Payload} = payload(P, Request),
        Encoded = jsx:encode(Payload),
        Headers = [{<<"content-type">>, <<"application/json">>},
                   {<<"accept">>, <<"application/json">>},
                   {<<"accept-encoding">>, <<"identity">>} | auth_headers(P)],
        Response = request(E, Suffix, Headers, Encoded, P, Deadline),
        decode(maps:get(operation, Request), damage_ai:json(Response))
    end).

%% Profiles are operator-owned; features cannot supply or override this URL.
-spec endpoint(list()) -> map().
endpoint(P) ->
    Url = text(proplists:get_value(base_url, P, <<>>)),
    require(byte_size(Url) =< 2048, invalid_endpoint),
    Parsed = uri_string:parse(Url),
    require(is_map(Parsed), invalid_endpoint),
    require(not lists:any(fun(K) -> maps:is_key(K, Parsed) end,
                          [userinfo, query, fragment]), invalid_endpoint),
    Scheme = maps:get(scheme, Parsed, undefined),
    Host = maps:get(host, Parsed, <<>>),
    require(is_binary(Host) andalso byte_size(Host) > 0, invalid_endpoint),
    {Transport, DefaultPort} = case Scheme of
        <<"https">> -> {tls, 443};
        <<"http">> ->
            require(proplists:get_value(allow_loopback_http, P, false) =:= true
                    andalso lists:member(Host, [<<"127.0.0.1">>, <<"::1">>]),
                    insecure_endpoint),
            {tcp, 80};
        _ -> throw({ai_error, invalid_endpoint})
    end,
    Port = maps:get(port, Parsed, DefaultPort),
    require(is_integer(Port) andalso Port > 0 andalso Port =< 65535, invalid_endpoint),
    Path = string:trim(maps:get(path, Parsed, <<>>), trailing, "/"),
    #{host => binary_to_list(Host), port => Port, path => Path, transport => Transport}.

-spec payload(list(), map()) -> {binary(), map()}.
payload(P, #{operation := embedding, input := Input}) ->
    Model = configured_model(embedding_model, P),
    {<<"/embeddings">>, #{<<"model">> => Model, <<"input">> => Input,
                          <<"encoding_format">> => <<"float">>}};
payload(P, #{operation := chat, messages := Messages, json := Json} = Request) ->
    Model = configured_model(model, P),
    TokenKey = case proplists:get_value(token_limit_key, P, max_completion_tokens) of
        max_completion_tokens -> <<"max_completion_tokens">>;
        max_tokens -> <<"max_tokens">>;
        _ -> throw({ai_error, invalid_profile})
    end,
    B0 = #{<<"model">> => Model, <<"messages">> => Messages,
           <<"stream">> => false,
           TokenKey => proplists:get_value(max_output_tokens, P, 1024)},
    B1 = case proplists:get_value(temperature, P, undefined) of
        undefined -> B0;
        T when is_number(T), T >= 0, T =< 2 -> B0#{<<"temperature">> => T};
        _ -> throw({ai_error, invalid_profile})
    end,
    Format = response_format(proplists:get_value(json_mode, P, prompt_only),
                             Json, maps:get(schema, Request, undefined)),
    B2 = case Format of
        undefined -> B1;
        _ -> B1#{<<"response_format">> => Format}
    end,
    %% Do not expose arbitrary extra provider parameters, tools or URLs.
    {<<"/chat/completions">>, B2}.

configured_model(Key, P) ->
    Model = text(proplists:get_value(Key, P, <<>>)),
    require(byte_size(Model) > 0 andalso byte_size(Model) =< 256, missing_model),
    Model.
response_format(_, false, _) -> undefined;
response_format(prompt_only, true, _) -> undefined;
response_format(json_object, true, _) -> #{<<"type">> => <<"json_object">>};
response_format(json_schema, true, Schema) when is_map(Schema) ->
    #{<<"type">> => <<"json_schema">>, <<"json_schema">> =>
        #{<<"name">> => <<"damage_ai_result">>, <<"strict">> => true, <<"schema">> => Schema}};
response_format(json_schema, true, undefined) -> #{<<"type">> => <<"json_object">>};
response_format(_, _, _) -> throw({ai_error, invalid_profile}).

auth_headers(P) ->
    case proplists:get_value(api_key, P, none) of
        none -> [];
        {env, Name} when is_list(Name) ->
            case os:getenv(Name) of
                false -> throw({ai_error, missing_api_key});
                Key -> bearer(Key)
            end;
        {secret, Name} when is_atom(Name); is_binary(Name) ->
            %% Reference comes from operator configuration, never from Gherkin.
            case secrets:retrieve_decrypt(Name) of
                {ok, Key} -> bearer(Key);
                _ -> throw({ai_error, missing_api_key})
            end;
        _ -> throw({ai_error, invalid_profile})
    end.
bearer(Key0) ->
    Key = text(Key0),
    require(byte_size(Key) > 0 andalso byte_size(Key) =< 8192, missing_api_key),
    require(binary:match(Key, [<<"\r">>, <<"\n">>, <<0>>]) =:= nomatch, missing_api_key),
    [{<<"authorization">>, <<"Bearer ", Key/binary>>}].

request(#{host := Host, port := Port, path := Base, transport := Transport},
        Suffix, Headers, Body, P, Deadline) ->
    Opts = #{transport => Transport, protocols => [http], retry => 0,
             connect_timeout => remaining(Deadline),
             domain_lookup_timeout => remaining(Deadline)},
    %% damage_gun adds verify_peer and hostname verification for TLS.
    case damage_gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, remaining(Deadline)) of
                    {ok, _} -> ok;
                    _ -> throw({ai_error, transport_failed})
                end,
                Ref = gun:post(Conn, <<Base/binary, Suffix/binary>>, Headers, Body, #{flow => 1}),
                Limit = proplists:get_value(max_response_bytes, P, 1048576),
                receive_headers(Conn, Ref, Limit, Deadline)
            after
                %% No redirect handling, retry, cookie storage or raw-response logging.
                try gun:close(Conn) catch _:_ -> ok end,
                try gun:flush(Conn) catch _:_ -> ok end
            end;
        _ -> throw({ai_error, transport_failed})
    end.
receive_headers(Conn, Ref, Limit, Deadline) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {inform, _, _} -> receive_headers(Conn, Ref, Limit, Deadline);
        {response, nofin, Status, _} when Status >= 200, Status < 300 ->
            receive_body(Conn, Ref, Limit, Deadline, 0, []);
        {response, fin, Status, _} when Status >= 200, Status < 300 ->
            throw({ai_error, empty_output});
        {response, _, Status, _} -> throw({ai_error, {http_status, Status}});
        {error, timeout} -> throw({ai_error, timeout});
        _ -> throw({ai_error, transport_failed})
    end.
receive_body(Conn, Ref, Limit, Deadline, Size, Chunks) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {data, Fin, Chunk} ->
            NewSize = Size + byte_size(Chunk),
            require(NewSize =< Limit, response_too_large),
            case Fin of
                fin -> iolist_to_binary(lists:reverse([Chunk | Chunks]));
                nofin ->
                    gun:update_flow(Conn, Ref, 1),
                    receive_body(Conn, Ref, Limit, Deadline, NewSize, [Chunk | Chunks])
            end;
        {trailers, _} -> iolist_to_binary(lists:reverse(Chunks));
        {error, timeout} -> throw({ai_error, timeout});
        _ -> throw({ai_error, transport_failed})
    end.
remaining(Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    require(Left > 0, timeout), Left.

-spec decode(chat | embedding, map()) -> map().
decode(chat, #{<<"choices">> := [Choice], <<"model">> := Model} = Raw) ->
    Message = maps:get(<<"message">>, Choice, #{}),
    Refusal = maps:get(<<"refusal">>, Message, null),
    require(Refusal =:= null orelse Refusal =:= <<>>, refused),
    require(maps:get(<<"tool_calls">>, Message, []) =:= [] andalso
            not maps:is_key(<<"function_call">>, Message), unexpected_tool_call),
    case maps:get(<<"finish_reason">>, Choice, undefined) of
        <<"stop">> -> ok;
        <<"length">> -> throw({ai_error, truncated});
        <<"content_filter">> -> throw({ai_error, refused});
        <<"tool_calls">> -> throw({ai_error, unexpected_tool_call});
        _ -> throw({ai_error, unsupported_finish_reason})
    end,
    Content = maps:get(<<"content">>, Message, undefined),
    require(is_binary(Content), invalid_backend_response),
    #{text => Content, model => Model, usage => decode_usage(Raw)};
decode(embedding, #{<<"data">> := [#{<<"embedding">> := Vector}], <<"model">> := Model} = Raw) ->
    #{embedding => Vector, model => Model, usage => decode_usage(Raw)};
decode(_, _) -> throw({ai_error, invalid_backend_response}).
decode_usage(Raw) ->
    U = maps:get(<<"usage">>, Raw, #{}),
    case is_map(U) of
        false -> #{};
        true -> maps:from_list([{To, V} || {From, To} <- [
            {<<"prompt_tokens">>, input_tokens}, {<<"completion_tokens">>, output_tokens},
            {<<"total_tokens">>, total_tokens}],
            V <- [maps:get(From, U, undefined)], is_integer(V), V >= 0])
    end.
