-module(ecai_ollama_http_tests).

-include_lib("eunit/include/eunit.hrl").

passthrough_chat_preserves_native_fields_test() ->
    Body = #{
        <<"model">> => <<"ecai-visible">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"tools">> => [#{<<"type">> => <<"function">>}],
        <<"format">> => <<"json">>,
        <<"think">> => true,
        <<"stream">> => false
    },
    Model = #{
        backend_model => <<"qwen3-coder:30b">>,
        provider => ollama,
        profile => passthrough
    },
    {ok, Prepared, Meta} = ecai_ollama_http:prepare_request(chat, Body, Model, <<"acct">>),
    ?assertEqual(<<"qwen3-coder:30b">>, maps:get(<<"model">>, Prepared)),
    ?assertEqual(maps:get(<<"messages">>, Body), maps:get(<<"messages">>, Prepared)),
    ?assertEqual(maps:get(<<"tools">>, Body), maps:get(<<"tools">>, Prepared)),
    ?assertEqual(<<"json">>, maps:get(<<"format">>, Prepared)),
    ?assertEqual(true, maps:get(<<"think">>, Prepared)),
    ?assertEqual(false, ecai_ollama_http:stream_requested(Prepared)),
    ?assertEqual(passthrough, maps:get(profile, Meta)).

stream_defaults_to_true_test() ->
    ?assertEqual(true, ecai_ollama_http:stream_requested(#{})),
    ?assertEqual(true, ecai_ollama_http:stream_requested(#{<<"stream">> => true})),
    ?assertEqual(false, ecai_ollama_http:stream_requested(#{<<"stream">> => false})).

public_model_identity_is_restored_test() ->
    Response = #{
        <<"model">> => <<"backend-model">>,
        <<"done">> => true,
        <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"ok">>}
    },
    Public = <<"ecai/qwen3-coder:30b-rag-v1">>,
    Rewritten = ecai_ollama_http:response_with_public_model(Response, Public),
    ?assertEqual(Public, maps:get(<<"model">>, Rewritten)),
    ?assertEqual(true, maps:get(<<"done">>, Rewritten)).
