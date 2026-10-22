-module(damage_ai_openai_tests).
-include_lib("eunit/include/eunit.hrl").

endpoint_test() ->
    E = damage_ai_openai:endpoint([{base_url, <<"https://example.invalid/v1/">>}]),
    ?assertEqual(tls, maps:get(transport, E)),
    ?assertEqual(<<"/v1">>, maps:get(path, E)),
    ?assertEqual(443, maps:get(port, E)),
    lists:foreach(fun(URL) ->
        ?assertEqual({error, invalid_endpoint}, damage_ai:safe(fun() ->
            damage_ai_openai:endpoint([{base_url, URL}]) end))
    end, [<<"https://user:pass@example.invalid/v1">>,
          <<"https://example.invalid/v1?key=secret">>,
          <<"https://example.invalid/v1#fragment">>, <<"file:///tmp/input">>]),
    ?assertEqual({error, insecure_endpoint}, damage_ai:safe(fun() ->
        damage_ai_openai:endpoint([{base_url, <<"http://127.0.0.1:11434/v1">>}]) end)),
    ?assertEqual({error, insecure_endpoint}, damage_ai:safe(fun() ->
        damage_ai_openai:endpoint([{base_url, <<"http://example.invalid/v1">>},
                                  {allow_loopback_http, true}]) end)).

payload_test() ->
    {Req, _, _} = damage_ai:prepare(<<"classify">>, <<"bill">>,
                                    #{labels => [<<"billing">>]}),
    P = [{model, <<"fixture">>}, {max_output_tokens, 100}, {json_mode, json_schema}],
    {<<"/chat/completions">>, B} = damage_ai_openai:payload(P, Req),
    ?assertEqual(100, maps:get(<<"max_completion_tokens">>, B)),
    ?assertEqual(false, maps:get(<<"stream">>, B)),
    ?assertEqual(false, maps:is_key(<<"temperature">>, B)),
    ?assertEqual(false, maps:is_key(<<"tools">>, B)),
    Format = maps:get(<<"response_format">>, B),
    ?assertEqual(<<"json_schema">>, maps:get(<<"type">>, Format)),
    {_, Legacy} = damage_ai_openai:payload([{token_limit_key, max_tokens} | P], Req),
    ?assertEqual(100, maps:get(<<"max_tokens">>, Legacy)),
    ?assertEqual(false, maps:is_key(<<"max_completion_tokens">>, Legacy)),
    {ER, _, _} = damage_ai:prepare(<<"embed">>, <<"input">>, #{}),
    {<<"/embeddings">>, EB} = damage_ai_openai:payload([{embedding_model, <<"vector-v1">>}], ER),
    ?assertEqual(<<"float">>, maps:get(<<"encoding_format">>, EB)).

wire_decode_test() ->
    Good = completion(<<"hello">>),
    R = damage_ai_openai:decode(chat, Good),
    ?assertEqual(<<"hello">>, maps:get(text, R)),
    ?assertEqual(#{}, maps:get(usage, R)),
    [Choice] = maps:get(<<"choices">>, Good),
    BadLength = Good#{<<"choices">> => [Choice#{<<"finish_reason">> => <<"length">>}]},
    ?assertEqual({error, truncated}, damage_ai:safe(fun() ->
        damage_ai_openai:decode(chat, BadLength) end)),
    BadRefusal = Good#{<<"choices">> => [Choice#{<<"message">> =>
                         #{<<"refusal">> => <<"refused">>, <<"content">> => null}}]},
    ?assertEqual({error, refused}, damage_ai:safe(fun() ->
        damage_ai_openai:decode(chat, BadRefusal) end)),
    BadTool = Good#{<<"choices">> => [Choice#{<<"message">> =>
                         #{<<"tool_calls">> => [#{}], <<"content">> => <<"x">>}}]},
    ?assertEqual({error, unexpected_tool_call}, damage_ai:safe(fun() ->
        damage_ai_openai:decode(chat, BadTool) end)),
    ?assertEqual({error, invalid_backend_response}, damage_ai:safe(fun() ->
        damage_ai_openai:decode(chat, #{<<"choices">> => []}) end)).

%% Local transport tests use the real supplied damage_gun connection path.
%% These do not contact a model provider or use credentials.
http_success_test() ->
    with_server(200, jsx:encode(completion(<<"local fixture">>)), [], fun(P) ->
        {ok, R} = damage_ai_openai:invoke(P, request()),
        ?assertEqual(<<"local fixture">>, maps:get(text, R))
    end).
http_body_limit_test() ->
    with_server(200, binary:copy(<<"x">>, 1024), [], fun(P) ->
        ?assertEqual({error, response_too_large},
            damage_ai_openai:invoke([{max_response_bytes, 128} | P], request()))
    end).
http_error_redaction_test() ->
    with_server(401, <<"SECRET_CANARY">>, [], fun(P) ->
        ?assertEqual({error, {http_status, 401}}, damage_ai_openai:invoke(P, request()))
    end).
no_redirect_test() ->
    with_server(302, <<>>, [{<<"location">>, <<"https://example.invalid/steal-key">>}], fun(P) ->
        ?assertEqual({error, {http_status, 302}}, damage_ai_openai:invoke(P, request()))
    end).

completion(Text) ->
    #{<<"model">> => <<"fixture-v1">>, <<"choices">> => [
        #{<<"finish_reason">> => <<"stop">>, <<"message">> => #{<<"content">> => Text}}]}.
request() ->
    {Req, _, _} = damage_ai:prepare(<<"summarize">>, <<"test input">>, #{}), Req.
with_server(Status, Body, ExtraHeaders, Test) ->
    {ok, _} = application:ensure_all_started(gun),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                    {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Server = spawn(fun() ->
        case gen_tcp:accept(Listen, 2000) of
            {ok, Sock} ->
                try
                    receive_request(Sock, <<>>),
                    Extra = [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- ExtraHeaders],
                    gen_tcp:send(Sock, [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" Fixture\r\n">>,
                        <<"content-type: application/json\r\ncontent-length: ">>,
                        integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n">>,
                        Extra, <<"\r\n">>, Body])
                after gen_tcp:close(Sock) end;
            _ -> ok
        end
    end),
    URL = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), <<"/v1">>]),
    P = [{base_url, URL}, {allow_loopback_http, true}, {model, <<"fixture">>},
         {timeout_ms, 1000}, {max_response_bytes, 4096}],
    try Test(P)
    after gen_tcp:close(Listen), exit(Server, kill) end.

%% Read the complete request before replying, avoiding TCP reset from unread data.
receive_request(Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            {match, [Length]} = re:run(Headers, <<"content-length: ([0-9]+)">>,
                                      [caseless, {capture, [1], binary}]),
            Missing = binary_to_integer(Length) - byte_size(Body),
            case Missing > 0 of
                true -> {ok, _} = gen_tcp:recv(Sock, Missing, 1000), ok;
                false -> ok
            end;
        _ ->
            {ok, Next} = gen_tcp:recv(Sock, 0, 1000),
            receive_request(Sock, <<Acc/binary, Next/binary>>)
    end.
