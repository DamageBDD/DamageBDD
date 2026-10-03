%% Test adapters only. The existing DamageBDD fake PQC backend is reused;
%% there is intentionally no duplicated test KEM implementation here.
-module(ecai_private_test_support).
-export([keypair/1, generate_text/2]).
keypair(#{corpus := Corpus}) ->
    Owner = application:get_env(ecai, private_test_owner, self()),
    Owner ! {private_test_key_lookup, Corpus},
    Pairs = application:get_env(ecai, private_test_pairs, #{}),
    case maps:find(Corpus, Pairs) of
        {ok, Pair} -> {ok, Pair};
        error -> {error, unavailable}
    end.
generate_text(Prompt, Opts) ->
    Owner = application:get_env(ecai, private_test_owner, self()),
    Owner ! {private_test_llm, Prompt, Opts},
    case application:get_env(ecai, private_test_llm_error, false) of
        true -> {error, {provider_echo, Prompt, Opts}};
        false -> {ok, <<"The private evidence supports this answer. [S1]">>}
    end.
