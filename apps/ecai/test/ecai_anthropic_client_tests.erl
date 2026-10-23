-module(ecai_anthropic_client_tests).
-include_lib("eunit/include/eunit.hrl").

payload_system_and_roles_test() ->
    Messages = [#{<<"role">> => <<"system">>, <<"content">> => <<"Trusted instruction">>},
                #{<<"role">> => <<"user">>, <<"content">> => <<"Question">>},
                #{<<"role">> => <<"assistant">>, <<"content">> => <<"Earlier response">>},
                #{<<"role">> => <<"user">>, <<"content">> => <<"Follow-up">>}],
    {ok, P} = ecai_ollama_client:anthropic_payload(Messages, false,
        #{model => <<"fixture-model">>, max_output_tokens => 123}),
    ?assertEqual(<<"Trusted instruction">>, maps:get(<<"system">>, P)),
    ?assertEqual(tl(Messages), maps:get(<<"messages">>, P)),
    ?assertEqual(123, maps:get(<<"max_tokens">>, P)),
    ?assertEqual(false, maps:get(<<"stream">>, P)),
    ?assertNot(maps:is_key(<<"temperature">>, P)).
json_hint_test() ->
    {ok, P} = ecai_ollama_client:anthropic_payload(<<"Question">>, true, #{model => <<"fixture">>}),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"system">>, P), <<"JSON">>)).
reject_tools_and_images_test() ->
    ?assertMatch({error, _}, ecai_ollama_client:anthropic_payload(
        [#{<<"role">> => <<"tool">>, <<"content">> => <<"untrusted">>}], false, #{model => <<"fixture">>})),
    ?assertMatch({error, _}, ecai_ollama_client:anthropic_payload(
        [#{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"image">>}]}], false, #{model => <<"fixture">>})).
invalid_temperature_test() ->
    ?assertEqual({error, invalid_anthropic_temperature},
        ecai_ollama_client:anthropic_payload(<<"Q">>, false, #{model => <<"fixture">>, temperature => 1.5})).
headers_test() ->
    {ok, H} = ecai_ollama_client:anthropic_headers(#{auth => {bearer, <<"unit-test-key">>}}),
    ?assertEqual(<<"unit-test-key">>, proplists:get_value(<<"x-api-key">>, H)),
    ?assertEqual(<<"2023-06-01">>, proplists:get_value(<<"anthropic-version">>, H)),
    ?assertEqual(undefined, proplists:get_value(<<"authorization">>, H)),
    ?assertEqual({error, invalid_bearer_token}, ecai_ollama_client:anthropic_headers(
        #{auth => {bearer, <<"key\r\nx-inject: yes">>}})),
    ?assertEqual({error, anthropic_api_key_required}, ecai_ollama_client:anthropic_headers(#{auth => none})).
response() -> #{<<"id">> => <<"msg-fixture">>, <<"model">> => <<"fixture-model">>,
    <<"stop_reason">> => <<"end_turn">>,
    <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Answer">>}],
    <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 2}}.
response_text_test() ->
    {ok, <<"Answer">>, Meta} = ecai_ollama_client:decode_anthropic_response(response(), 12, #{}),
    ?assertEqual(anthropic, maps:get(provider, Meta)),
    ?assertEqual(10, maps:get(input_tokens, Meta)),
    ?assertEqual(12, maps:get(wall_duration_ms, Meta)).
no_fabricated_usage_test() ->
    {ok, _, Meta} = ecai_ollama_client:decode_anthropic_response(maps:remove(<<"usage">>, response()), 0, #{}),
    ?assertEqual(undefined, maps:get(input_tokens, Meta)).
reject_truncation_and_nontext_test() ->
    ?assertEqual({error, anthropic_truncated}, ecai_ollama_client:decode_anthropic_response(
        (response())#{<<"stop_reason">> => <<"max_tokens">>}, 0, #{})),
    ?assertEqual({error, anthropic_unsupported_content}, ecai_ollama_client:decode_anthropic_response(
        (response())#{<<"content">> => [#{<<"type">> => <<"tool_use">>}]}, 0, #{})),
    ?assertMatch({error, _}, ecai_ollama_client:decode_anthropic_response(
        (response())#{<<"stop_reason">> => <<"refusal">>}, 0, #{})).

native_options_not_silently_ignored_test() ->
    ?assertEqual(ok, ecai_ollama_client:anthropic_native_options(#{<<"stream">> => false})),
    ?assertMatch({error, {unsupported_native_option, anthropic, <<"images">>}},
        ecai_ollama_client:anthropic_native_options(#{<<"images">> => [<<"base64-fixture">>]})),
    ?assertMatch({error, {unsupported_native_option, anthropic, <<"options">>}},
        ecai_ollama_client:anthropic_native_options(#{<<"options">> => #{<<"seed">> => 1}})).
