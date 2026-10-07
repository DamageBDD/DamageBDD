-module(nosternity_llm_bridge_tests).
-include_lib("eunit/include/eunit.hrl").

public_only_filters_test() ->
    Query = <<"Lightning payments">>,
    {ok, Query, Query, [Filter], 8} = nosternity_llm_bridge:prepare(#{<<"query">> => Query}),
    ?assertEqual(Query, maps:get(<<"search">>, Filter)),
    ?assertEqual([0, 1, 30023], maps:get(<<"kinds">>, Filter)),
    ?assertEqual(8, maps:get(<<"limit">>, Filter)).

all_or_filters_are_public_test() ->
    Query = <<"release">>,
    {ok, _, _, Filters, 3} = nosternity_llm_bridge:prepare(#{
        <<"query">> => Query, <<"limit">> => 3,
        <<"filters">> => [
            #{<<"kinds">> => [1, 4, 1059], <<"search">> => <<"ignored">>, <<"limit">> => 200},
            #{<<"kinds">> => [4, 1059]},
            #{<<"kinds">> => [30023], <<"limit">> => 1}
        ]
    }),
    ?assertEqual([
        #{<<"kinds">> => [1], <<"search">> => Query, <<"limit">> => 3},
        #{<<"kinds">> => [30023], <<"search">> => Query, <<"limit">> => 1}
    ], Filters).

private_only_never_searches_test() ->
    {ok, #{sources := [], total := 0}} = nosternity_llm_bridge:context(#{
        <<"query">> => <<"secret">>, <<"filters">> => [#{<<"kinds">> => [4, 1059, 24133]}]
    }).

client_provider_controls_rejected_test() ->
    lists:foreach(fun(Key) ->
        ?assertEqual({error, invalid_request}, nosternity_llm_bridge:prepare(#{
            <<"query">> => <<"hello">>, Key => <<"attacker-controlled">>
        }))
    end, [<<"host">>, <<"url">>, <<"model">>, <<"options">>, <<"system">>, <<"tools">>]).

request_limits_test() ->
    lists:foreach(fun(Request) ->
        ?assertEqual({error, invalid_request}, nosternity_llm_bridge:prepare(Request))
    end, [
        #{}, #{<<"query">> => <<" ">>}, #{<<"query">> => <<255>>},
        #{<<"query">> => binary:copy(<<"q">>, 1025)},
        #{<<"query">> => <<"q">>, <<"question">> => binary:copy(<<"q">>, 8193)},
        #{<<"query">> => <<"q">>, <<"limit">> => 9},
        #{<<"query">> => <<"q">>, <<"limit">> => 0}
    ]).

utf8_clipping_test() ->
    %% Keep complete code points when the byte budget lands within a character.
    Bin = <<"abc", 16#1F680/utf8, "def">>,
    ?assertEqual(<<"abc">>, nosternity_llm_bridge:clip_utf8(Bin, 5)),
    ?assertEqual(<<"abc", 16#1F680/utf8>>, nosternity_llm_bridge:clip_utf8(Bin, 7)),
    ?assertEqual(<<>>, nosternity_llm_bridge:clip_utf8(Bin, 0)),
    ?assertError(invalid_index_utf8, nosternity_llm_bridge:clip_utf8(<<255>>, 1)).

context_is_bounded_and_excludes_ciphertext_test() ->
    Text = binary:copy(<<16#1F680/utf8>>, 2048),
    Public = [result(N, 1, Text) || N <- lists:seq(1, 20)],
    Results = [result(0, 4, <<"ciphertext">>) | Public],
    #{sources := Sources} = nosternity_llm_bridge:build_context(<<"q">>, <<"q">>, Results, 20, 8),
    ?assertEqual(8, length(Sources)),
    lists:foreach(fun(Source) ->
        ?assertEqual(1, maps:get(<<"kind">>, Source)),
        ?assertEqual(4096, byte_size(maps:get(<<"text">>, Source))),
        ?assert(is_binary(unicode:characters_to_binary(maps:get(<<"text">>, Source)))),
        ?assertEqual(true, maps:get(<<"truncated">>, Source))
    end, Sources),
    ?assertEqual(<<"S1">>, maps:get(<<"citation">>, hd(Sources))),
    ?assertEqual(<<"1">>, maps:get(<<"id">>, hd(Sources))).

inference_is_disabled_by_default_test() ->
    with_env(search_llm_enabled, false, fun() ->
        ?assertEqual({error, llm_disabled}, nosternity_llm_bridge:ask(#{<<"query">> => <<"q">>}))
    end).

immutable_system_and_closed_provider_options_test() ->
    with_env(search_llm_enabled, true, fun() ->
        with_env(search_llm_opts, #{provider => ollama, model => <<"local-model">>,
            system => <<"bad system">>, tools => [unsafe], store => true, timeout => 9999999}, fun() ->
            {ok, Opts} = nosternity_llm_bridge:inference_options(),
            ?assertEqual(<<"local-model">>, maps:get(model, Opts)),
            ?assertNotEqual(<<"bad system">>, maps:get(system, Opts)),
            ?assertNot(maps:is_key(tools, Opts)),
            ?assertEqual(false, maps:get(store, Opts)),
            ?assertEqual(60000, maps:get(timeout, Opts))
        end)
    end).

proplist_configuration_test() ->
    with_env(search_llm_enabled, true, fun() ->
        with_env(search_llm_opts, [{provider, ollama}, {model, <<"local-model">>},
            {host, "127.0.0.1"}, {port, 11434}], fun() ->
            {ok, Opts} = nosternity_llm_bridge:inference_options(),
            ?assertEqual(ollama, maps:get(provider, Opts)),
            ?assertEqual(<<"local-model">>, maps:get(model, Opts)),
            ?assertEqual("127.0.0.1", maps:get(host, Opts))
        end),
        with_env(search_llm_opts, [invalid], fun() ->
            ?assertEqual({error, llm_not_configured}, nosternity_llm_bridge:inference_options())
        end)
    end).

missing_model_fails_closed_test() ->
    with_env(search_llm_enabled, true, fun() ->
        with_env(search_llm_opts, #{}, fun() ->
            ?assertEqual({error, llm_not_configured}, nosternity_llm_bridge:inference_options())
        end)
    end).

result(N, Kind, Text) ->
    #{event => #{id => integer_to_binary(N), pubkey => <<"author">>,
        kind => Kind, created_at => N, content => Text}, score => 1.0}.

with_env(Key, Value, Fun) ->
    Previous = application:get_env(nosternity, Key),
    application:set_env(nosternity, Key, Value),
    try Fun()
    after
        case Previous of
            {ok, Old} -> application:set_env(nosternity, Key, Old);
            undefined -> application:unset_env(nosternity, Key)
        end
    end.
