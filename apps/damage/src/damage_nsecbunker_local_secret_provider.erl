%%--------------------------------------------------------------------
%% Local/default nsecbunker passphrase provider.
%%
%% This is the single compatibility boundary for the pre-AWS Damage secret
%% store. Managed providers must never call this module as an error fallback.
%%--------------------------------------------------------------------

-module(damage_nsecbunker_local_secret_provider).

-export([fetch/1]).

-spec fetch(map() | proplists:proplist()) ->
    {ok, binary()} | {error, term()}.
fetch(Config0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    SecretRef = maps:get(
        vault_passphrase,
        Config,
        nsecbunker_vault_passphrase
    ),
    normalize_result(secrets:retrieve_decrypt(SecretRef)).

normalize_result({ok, Value}) ->
    normalize_secret(Value);
normalize_result({error, _} = Error) ->
    Error;
normalize_result(Value) ->
    normalize_secret(Value).

normalize_secret(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_secret(Value) when is_list(Value), Value =/= [] ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary), byte_size(Binary) > 0 ->
            {ok, Binary};
        _ ->
            {error, empty_local_vault_passphrase}
    catch
        _:_ ->
            {error, invalid_local_vault_passphrase}
    end;
normalize_secret(_) ->
    {error, empty_local_vault_passphrase}.
