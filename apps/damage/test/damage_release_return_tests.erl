%% Pure regressions for the shared release contract-result decoder.
%% No chain calls, signing, IPFS reads, module mocks, or application startup.
-module(damage_release_return_tests).
-include_lib("eunit/include/eunit.hrl").

%% This is the pair of decoded/raw fields from the reported failure.
logged_none_reply() ->
    #{
        "return_type" => "ok",
        "return_value" => {variant, [0, 1], 0, {}},
        <<"return_type">> => <<"ok">>,
        <<"return_value">> => <<"cb_r4IAAQA/aHG2bw==">>
    }.

none() -> {variant, [0, 1], 0, {}}.
some(Value) -> {variant, [0, 1], 1, {Value}}.

mixed_none_reply_test() ->
    {ok, Value} = damage_release_nft:call_return(logged_none_reply()),
    ?assertEqual(none(), Value),
    ?assertEqual(none, damage_release_nft:option_value(Value)).

mixed_some_reply_test() ->
    %% The raw transport field is deliberately opaque: it must not be chosen
    %% or decoded again when the wrapper has already supplied a FATE value.
    Call = (logged_none_reply())#{
        "return_value" := some(42),
        <<"return_value">> := <<"cb_opaque-transport-value">>
    },
    {ok, Value} = damage_release_nft:call_return(Call),
    ?assertEqual(some(42), Value),
    ?assertEqual({ok, 42}, damage_release_nft:option_value(Value)).

decoded_string_keys_take_precedence_test() ->
    %% Preserve the wrapper's decoded string fields even if atom aliases
    %% have also been retained by a caller. Do not change unrelated map rules.
    Call = (logged_none_reply())#{return_type => error, return_value => wrong},
    ?assertEqual({ok, none()}, damage_release_nft:call_return(Call)).

single_key_representation_test_() ->
    [
        ?_assertEqual({ok, some(42)}, damage_release_nft:call_return(Call))
     || Call <- [
        #{"return_type" => "ok", "return_value" => some(42)},
        #{return_type => ok, return_value => some(42)},
        #{<<"return_type">> => <<"ok">>, <<"return_value">> => some(42)}
    ]
    ].

atom_keys_precede_raw_binary_fallback_test() ->
    Call = #{
        return_type => ok,
        return_value => none(),
        <<"return_type">> => <<"ok">>,
        <<"return_value">> => <<"cb_r4IAAQA/aHG2bw==">>
    },
    ?assertEqual({ok, none()}, damage_release_nft:call_return(Call)).

raw_status_with_decoded_value_test() ->
    Call = maps:remove("return_type", logged_none_reply()),
    ?assertEqual({ok, none()}, damage_release_nft:call_return(Call)).

mint_and_oracle_results_test_() ->
    %% Mint token ID, unit response, oracle query ID, and a native map.
    %% Do not specialize call_return/1 for options only.
    [
        ?_assertEqual({ok, Value}, damage_release_nft:call_return(
            (logged_none_reply())#{"return_value" := Value}))
     || Value <- [42, {}, {oracle_query, <<0:256>>}, #{<<"release">> => <<"v1">>}]
    ].

revert_keeps_decoded_reason_test() ->
    Call = (logged_none_reply())#{
        "return_type" := "revert",
        "return_value" := <<"Release already exists">>,
        <<"return_type">> := <<"revert">>,
        <<"return_value">> := <<"cb_opaque-revert">>
    },
    ?assertEqual({error, {revert, <<"Release already exists">>}},
        damage_release_nft:call_return(Call)).

error_keeps_decoded_reason_test() ->
    Call = (logged_none_reply())#{
        "return_type" := "error",
        "return_value" := <<"Contract execution failed">>,
        <<"return_type">> := <<"error">>,
        <<"return_value">> := <<"cb_opaque-error">>
    },
    ?assertEqual({error, {unexpected_return_type, "error", <<"Contract execution failed">>}},
        damage_release_nft:call_return(Call)).

missing_status_still_fails_test() ->
    ?assertEqual({error, missing_return_type},
        damage_release_nft:call_return(#{"return_value" => none()})).

nonmap_still_fails_test() ->
    ?assertEqual({error, contract_call_failed}, damage_release_nft:call_return(not_a_map)).

raw_only_value_is_not_assumed_none_test() ->
    Raw = <<"cb_r4IAAQA/aHG2bw==">>,
    Call = #{<<"return_type">> => <<"ok">>, <<"return_value">> => Raw},
    {ok, Value} = damage_release_nft:call_return(Call),
    ?assertEqual(Raw, Value),
    ?assertEqual({error, invalid_release_option}, damage_release_nft:option_value(Value)).

malformed_decoded_value_does_not_fall_back_test() ->
    Call = (logged_none_reply())#{
        "return_value" := undefined,
        <<"return_value">> := none()
    },
    ?assertEqual({ok, undefined}, damage_release_nft:call_return(Call)),
    ?assertEqual({error, invalid_release_option},
        damage_release_nft:option_value(undefined)).

malformed_variant_still_fails_test_() ->
    [
        ?_assertEqual({error, invalid_release_option}, damage_release_nft:option_value(Value))
     || Value <- [
        {variant, [1, 0], 0, {}},
        {variant, [0, 1], 0, {unexpected}},
        {variant, [0, 1], 1, {}},
        {variant, [0, 1], 2, {}},
        <<"not a decoded option">>
    ]
    ].

latest_none_is_not_found_test() ->
    Query = fun("latest_release_value_for", ["ubuntu-noble-amd64"]) ->
        damage_release_nft:call_return(logged_none_reply())
    end,
    ?assertEqual({error, not_found},
        damage_release_nft:select_release(latest, <<"ubuntu-noble-amd64">>, Query)).

historical_none_is_not_found_test() ->
    %% No metadata lookup may run for a nonexistent release token.
    Query = fun("release_token", ["v1.2.3", "ubuntu-noble-amd64"]) ->
        damage_release_nft:call_return(logged_none_reply())
    end,
    ?assertEqual({error, not_found}, damage_release_nft:select_release(
        {release, <<"v1.2.3">>}, <<"ubuntu-noble-amd64">>, Query)).
