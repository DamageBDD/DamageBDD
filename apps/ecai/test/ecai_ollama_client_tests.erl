-module(ecai_ollama_client_tests).

-include_lib("eunit/include/eunit.hrl").

plain_json_test() ->
    ?assertEqual(
        {ok, #{<<"purpose">> => [<<"test">>]}},
        ecai_ollama_client:decode_json(
            <<"{\"purpose\":[\"test\"]}">>
        )
    ).

json_fence_test() ->
    ?assertEqual(
        {ok, #{<<"purpose">> => [<<"test">>]}},
        ecai_ollama_client:decode_json(
            <<"```json\n{\"purpose\":[\"test\"]}\n```">>
        )
    ).

plain_fence_test() ->
    ?assertEqual(
        {ok, #{<<"purpose">> => [<<"test">>]}},
        ecai_ollama_client:decode_json(
            <<"```\n{\"purpose\":[\"test\"]}\n```">>
        )
    ).

surrounding_whitespace_test() ->
    ?assertEqual(
        {ok, #{<<"purpose">> => [<<"test">>]}},
        ecai_ollama_client:decode_json(
            <<"  \n```json\r\n{\"purpose\":[\"test\"]}\r\n```  \n">>
        )
    ).

reject_prose_wrapped_json_test() ->
    ?assertMatch(
        {error, {invalid_json_response, _, _, _}},
        ecai_ollama_client:decode_json(
            <<"Here is the JSON: {\"purpose\":[\"test\"]}">>
        )
    ).

reject_unclosed_fence_test() ->
    ?assertMatch(
        {error, {invalid_json_response, _, _, _}},
        ecai_ollama_client:decode_json(
            <<"```json\n{\"purpose\":[\"test\"]}">>
        )
    ).

reject_non_object_json_test() ->
    ?assertMatch(
        {error, {response_not_json_object, _}},
        ecai_ollama_client:decode_json(<<"[1,2,3]">>)
    ).
