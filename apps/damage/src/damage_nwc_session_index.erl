-module(damage_nwc_session_index).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([
    put/3,
    put/4,
    get/1,
    delete/1,
    secret_key/1
]).

-import(damage_utils, [to_bin/1]).

-spec put(binary() | list(), binary() | list(), binary() | list()) -> ok.
put(ClientPubHex, Owner, LedgerCt) ->
    put(ClientPubHex, Owner, LedgerCt, #{}).

-spec put(binary() | list(), binary() | list(), binary() | list(), map()) -> ok.
put(ClientPubHex0, Owner0, LedgerCt0, Meta0) ->
    ClientPubHex = to_bin(ClientPubHex0),
    Owner = to_bin(Owner0),
    LedgerCt = to_bin(LedgerCt0),
    Meta = normalize_meta(Meta0),
    Key = secret_key(ClientPubHex),
    Value = term_to_binary(#{
        client_pubkey => ClientPubHex,
        owner => Owner,
        ledger_ct => LedgerCt,
        meta => Meta
    }),
    ok = secrets:encrypt_store(Key, Value).

-spec get(binary() | list()) -> {ok, map()} | {error, not_found}.
get(ClientPubHex0) ->
    ClientPubHex = to_bin(ClientPubHex0),
    Key = secret_key(ClientPubHex),
    case secrets:retrieve_decrypt(Key) of
        {ok, Bin} when is_binary(Bin) ->
            try
                case binary_to_term(Bin) of
                    #{owner := _Owner, ledger_ct := _LedgerCt} = M ->
                        {ok, M};
                    _ ->
                        {error, not_found}
                end
            catch
                _:_ ->
                    {error, not_found}
            end;
        {ok, List} when is_list(List) ->
            try
                case binary_to_term(list_to_binary(List)) of
                    #{owner := _Owner, ledger_ct := _LedgerCt} = M ->
                        {ok, M};
                    _ ->
                        {error, not_found}
                end
            catch
                _:_ ->
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

-spec delete(binary() | list()) -> ok.
delete(ClientPubHex0) ->
    ClientPubHex = to_bin(ClientPubHex0),
    Key = secret_key(ClientPubHex),
    %% if your secrets module has delete, use that instead
    ok = secrets:encrypt_store(Key, <<"deleted">>).

-spec secret_key(binary() | list()) -> string().
secret_key(ClientPubHex0) ->
    ClientPubHex = to_bin(ClientPubHex0),
    binary_to_list(
        <<"nwc_client__", (base64:encode(crypto:hash(sha256, ClientPubHex)))/binary>>
    ).

normalize_meta(M) when is_map(M) ->
    maps:from_list([{to_bin(K), normalize_meta(V)} || {K, V} <- maps:to_list(M)]);
normalize_meta(V) when is_list(V) ->
    [normalize_meta(X) || X <- V];
normalize_meta(V) ->
    V.
