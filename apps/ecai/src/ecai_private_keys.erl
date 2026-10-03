%% Reuse the existing scoped secrets vault. No new keystore, node identity,
%% password derivation or implicit key generation is introduced here.
-module(ecai_private_keys).
-export([keypair/1, load/1, provision/2]).

-spec keypair(map()) -> {ok, map()} | {error, atom()}.
keypair(#{owner := Owner, corpus := Corpus, key_name := Name}) ->
    case secrets:retrieve_decrypt({agent, Owner, Corpus}, Name) of
        {ok, #{public_key := Pub, private_key := Priv} = Pair}
          when is_binary(Pub), byte_size(Pub) > 0,
               is_binary(Priv), byte_size(Priv) > 0 ->
            {ok, maps:with([public_key, private_key], Pair)};
        _ -> {error, private_key_unavailable}
    end.

%% The module is operator configuration, never a request parameter. A remote
%% key service adapter can implement keypair/1 later; this API currently releases
%% keys to the trusted worker and is not a non-exportable HSM interface.
-spec load(map()) -> map().
load(Config) ->
    Module = application:get_env(ecai, private_key_provider_module, ?MODULE),
    case Module:keypair(Config) of
        {ok, #{public_key := Pub, private_key := Priv} = Pair}
          when is_binary(Pub), byte_size(Pub) > 0,
               is_binary(Priv), byte_size(Priv) > 0 ->
            maps:with([public_key, private_key], Pair);
        _ -> ecai_private_policy:fail(private_key_unavailable)
    end.

%% Trusted operator API only. Generates a fresh randomly named vault entry and
%% returns references, not keys. Never updates an existing corpus configuration.
-spec provision(binary(), binary()) -> {ok, map()} | {error, atom()}.
provision(Owner, Corpus) ->
    ecai_private_policy:run(fun() ->
        ecai_private_policy:guard(is_binary(Owner) andalso byte_size(Owner) > 0),
        ecai_private_policy:guard(is_binary(Corpus) andalso byte_size(Corpus) > 0),
        Suffix = binary:encode_hex(crypto:strong_rand_bytes(16)),
        Name = <<"ecai-private-pqc-", Suffix/binary>>,
        #{public_key := Pub, private_key := _} = Pair = secrets_pqc:generate_keypair(),
        ok = secrets:encrypt_store({agent, Owner, Corpus}, Name, Pair),
        {ok, Pair} = secrets:retrieve_decrypt({agent, Owner, Corpus}, Name),
        {ok, #{key_name => Name, key_id => Name,
               public_key_sha256 => binary:encode_hex(crypto:hash(sha256, Pub))}}
    end).
