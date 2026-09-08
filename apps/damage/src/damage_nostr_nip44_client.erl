%%--------------------------------------------------------------------
%% Stateless NIP-44 client crypto for Damage Nostr callers.
%%
%% This is deliberately separate from nsecbunker custody:
%%   * it never opens or names a vault;
%%   * it never retrieves a vault passphrase;
%%   * it never calls damage_nsecbunker_secret_owner;
%%   * it never changes behaviour based on the configured secret provider;
%%   * only the explicit-key NIP-44 vector operations are allowed.
%%
%% The caller already owns the client private key. The production bunker
%% private key remains exclusively behind damage_nsecbunker_secret_owner.
%%--------------------------------------------------------------------
-module(damage_nostr_nip44_client).

-include_lib("kernel/include/file.hrl").

-export([
    encrypt/3,
    encrypt/4,
    decrypt/3,
    decrypt/4
]).

-define(DEFAULT_TIMEOUT_MS, 10000).
-define(MAX_RESPONSE_BYTES, 4 * 1024 * 1024).

-spec encrypt(binary(), binary() | list(), binary() | list()) ->
    {ok, binary()} | {error, term()}.
encrypt(PrivateKey, PeerPubkey, Plaintext) ->
    encrypt(PrivateKey, PeerPubkey, Plaintext, ?DEFAULT_TIMEOUT_MS).

-spec encrypt(binary(), binary() | list(), binary() | list(), timeout()) ->
    {ok, binary()} | {error, term()}.
encrypt(PrivateKey0, PeerPubkey0, Plaintext0, Timeout0) ->
    case {
        private_key_hex(PrivateKey0),
        pubkey_hex(PeerPubkey0),
        to_binary(Plaintext0),
        backend_command(),
        normalize_timeout(Timeout0)
    } of
        {{ok, PrivateKey}, {ok, PeerPubkey}, Plaintext, {ok, Command}, Timeout}
                when is_binary(Plaintext), byte_size(Plaintext) > 0 ->
            Request = #{
                <<"op">> => <<"nip44_encrypt_vector">>,
                <<"secret_key_hex">> => PrivateKey,
                <<"peer_pubkey_hex">> => PeerPubkey,
                <<"nonce_hex">> => lower_hex(crypto:strong_rand_bytes(32)),
                <<"plaintext">> => Plaintext
            },
            case call_stateless(Command, Request, Timeout) of
                {ok, Result} ->
                    required_binary(payload, Result);
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _, _, _, _} ->
            Error;
        {_, {error, _} = Error, _, _, _} ->
            Error;
        {_, _, _, {error, _} = Error, _} ->
            Error;
        _ ->
            {error, invalid_nip44_plaintext}
    end.

-spec decrypt(binary(), binary() | list(), binary() | list()) ->
    {ok, binary()} | {error, term()}.
decrypt(PrivateKey, PeerPubkey, Payload) ->
    decrypt(PrivateKey, PeerPubkey, Payload, ?DEFAULT_TIMEOUT_MS).

-spec decrypt(binary(), binary() | list(), binary() | list(), timeout()) ->
    {ok, binary()} | {error, term()}.
decrypt(PrivateKey0, PeerPubkey0, Payload0, Timeout0) ->
    case {
        private_key_hex(PrivateKey0),
        pubkey_hex(PeerPubkey0),
        to_binary(Payload0),
        backend_command(),
        normalize_timeout(Timeout0)
    } of
        {{ok, PrivateKey}, {ok, PeerPubkey}, Payload, {ok, Command}, Timeout}
                when is_binary(Payload), byte_size(Payload) > 0 ->
            Request = #{
                <<"op">> => <<"nip44_decrypt_vector">>,
                <<"secret_key_hex">> => PrivateKey,
                <<"peer_pubkey_hex">> => PeerPubkey,
                <<"payload">> => Payload
            },
            case call_stateless(Command, Request, Timeout) of
                {ok, Result} ->
                    required_binary(plaintext, Result);
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _, _, _, _} ->
            Error;
        {_, {error, _} = Error, _, _, _} ->
            Error;
        {_, _, _, {error, _} = Error, _} ->
            Error;
        _ ->
            {error, invalid_nip44_payload}
    end.

%% The transport is intentionally private and only receives requests built by
%% encrypt/4 or decrypt/4. There is no generic public "call arbitrary backend
%% operation" API here.
call_stateless(Command, Request, Timeout) ->
    case allowed_request(Request) of
        true ->
            open_and_call(Command, Request, Timeout);
        false ->
            {error, forbidden_stateless_crypto_operation}
    end.

allowed_request(#{<<"op">> := <<"nip44_encrypt_vector">>} = Request) ->
    exact_keys(
        Request,
        [
            <<"op">>,
            <<"secret_key_hex">>,
            <<"peer_pubkey_hex">>,
            <<"nonce_hex">>,
            <<"plaintext">>
        ]
    );
allowed_request(#{<<"op">> := <<"nip44_decrypt_vector">>} = Request) ->
    exact_keys(
        Request,
        [
            <<"op">>,
            <<"secret_key_hex">>,
            <<"peer_pubkey_hex">>,
            <<"payload">>
        ]
    );
allowed_request(_) ->
    false.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).

open_and_call(Command, Request, Timeout) ->
    Options = [
        binary,
        use_stdio,
        exit_status,
        stderr_to_stdout,
        eof,
        {env, scrub_child_environment()}
    ],
    try open_port({spawn_executable, Command}, Options) of
        Port when is_port(Port) ->
            try
                Json = iolist_to_binary(jsx:encode(Request)),
                true = erlang:port_command(Port, <<Json/binary, "\n">>),
                collect_port(Port, Timeout, <<>>)
            catch
                Class:Reason ->
                    {error, {stateless_crypto_call_failed, safe_reason(Class, Reason)}}
            after
                safe_close(Port)
            end
    catch
        Class:Reason ->
            {error, {stateless_crypto_open_failed, safe_reason(Class, Reason)}}
    end.

collect_port(Port, Timeout, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            case byte_size(Acc) + byte_size(Data) =< ?MAX_RESPONSE_BYTES of
                true ->
                    collect_port(Port, Timeout, <<Acc/binary, Data/binary>>);
                false ->
                    {error, stateless_crypto_response_too_large}
            end;
        {Port, eof} ->
            collect_port(Port, Timeout, Acc);
        {Port, {exit_status, 0}} ->
            decode_response(Acc);
        {Port, {exit_status, _Status}} ->
            decode_error_response(Acc);
        {'EXIT', Port, _Reason} ->
            {error, stateless_crypto_backend_exit}
    after Timeout ->
        {error, stateless_crypto_timeout}
    end.

decode_response(Data) ->
    case decode_last_json(Data) of
        {ok, #{<<"ok">> := true, <<"result">> := Result}} when is_map(Result) ->
            {ok, Result};
        {ok, #{ok := true, result := Result}} when is_map(Result) ->
            {ok, Result};
        {ok, #{<<"ok">> := false, <<"error">> := Error}} ->
            {error, {stateless_crypto_rejected, safe_error(Error)}};
        {ok, #{ok := false, error := Error}} ->
            {error, {stateless_crypto_rejected, safe_error(Error)}};
        {ok, _Other} ->
            {error, stateless_crypto_bad_envelope};
        {error, _} = Error ->
            Error
    end.

decode_error_response(Data) ->
    case decode_last_json(Data) of
        {ok, #{<<"error">> := Error}} ->
            {error, {stateless_crypto_rejected, safe_error(Error)}};
        {ok, #{error := Error}} ->
            {error, {stateless_crypto_rejected, safe_error(Error)}};
        _ ->
            {error, stateless_crypto_backend_failed}
    end.

decode_last_json(Data) ->
    case last_nonempty_line(Data) of
        <<>> ->
            {error, stateless_crypto_empty_response};
        Line ->
            try jsx:decode(Line, [return_maps]) of
                Map when is_map(Map) ->
                    {ok, Map};
                _ ->
                    {error, stateless_crypto_response_not_object}
            catch
                _:_ ->
                    {error, stateless_crypto_invalid_json}
            end
    end.

last_nonempty_line(Data) ->
    Lines = binary:split(Data, <<"\n">>, [global]),
    Nonempty = [
        Trimmed
     || Line <- Lines,
        Trimmed <- [trim(Line)],
        Trimmed =/= <<>>
    ],
    case lists:reverse(Nonempty) of
        [Last | _] -> Last;
        [] -> <<>>
    end.

required_binary(Field, Map) ->
    Value =
        case maps:get(Field, Map, undefined) of
            undefined ->
                maps:get(atom_to_binary(Field, utf8), Map, undefined);
            Found ->
                Found
        end,
    case Value of
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            {ok, Bin};
        _ ->
            {error, {missing_stateless_crypto_response_field, Field}}
    end.

backend_command() ->
    Config = damage_nsecbunker_config:load(),
    Command0 = first_defined(
        [crypto_backend_cmd, crypto_port_cmd],
        Config,
        undefined
    ),
    case executable_path(Command0) of
        {ok, _} = Ok ->
            Ok;
        {error, _} ->
            %% Preserve the established operational fallback path, but only for
            %% locating the executable. No custody operation is invoked.
            executable_path(damage_nsecbunker_ops:crypto_backend_path())
    end.

executable_path(Value) when is_binary(Value) ->
    executable_path(binary_to_list(Value));
executable_path(Value) when is_list(Value), Value =/= [] ->
    Path =
        case filename:pathtype(Value) of
            absolute -> Value;
            _ -> filename:absname(Value)
        end,
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, mode = Mode}} when Mode band 8#111 =/= 0 ->
            {ok, Path};
        _ ->
            {error, stateless_crypto_backend_not_executable}
    end;
executable_path(_) ->
    {error, stateless_crypto_backend_not_configured}.

private_key_hex(Value) when is_binary(Value), byte_size(Value) =:= 32 ->
    {ok, lower_hex(Value)};
private_key_hex(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    case is_hex64(Value) of
        true -> {ok, lower_ascii(Value)};
        false -> {error, invalid_nip44_private_key}
    end;
private_key_hex(Value) when is_list(Value) ->
    private_key_hex(unicode:characters_to_binary(Value));
private_key_hex(_) ->
    {error, invalid_nip44_private_key}.

pubkey_hex(Value) when is_binary(Value), byte_size(Value) =:= 32 ->
    {ok, lower_hex(Value)};
pubkey_hex(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    case is_hex64(Value) of
        true -> {ok, lower_ascii(Value)};
        false -> {error, invalid_nip44_peer_pubkey}
    end;
pubkey_hex(Value) when is_list(Value) ->
    pubkey_hex(unicode:characters_to_binary(Value));
pubkey_hex(_) ->
    {error, invalid_nip44_peer_pubkey}.

is_hex64(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    lists:all(
        fun(C) ->
            (C >= $0 andalso C =< $9) orelse
                (C >= $a andalso C =< $f) orelse
                (C >= $A andalso C =< $F)
        end,
        binary_to_list(Bin)
    );
is_hex64(_) ->
    false.

lower_hex(Bin) ->
    lower_ascii(binary:encode_hex(Bin)).

lower_ascii(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(Bin))).

scrub_child_environment() ->
    [
        {Name, false}
     || Name <- [
            "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
            "DAMAGE_NSECBUNKER_VAULT_PATH",
            "DAMAGE_NSECBUNKER_PRODUCTION",
            "DAMAGE_NSECBUNKER_TEST_MODE",
            "DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "AWS_SECURITY_TOKEN",
            "AWS_PROFILE",
            "AWS_DEFAULT_PROFILE",
            "AWS_SHARED_CREDENTIALS_FILE",
            "AWS_CONFIG_FILE",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            "AWS_WEB_IDENTITY_TOKEN_FILE",
            "AWS_ROLE_ARN",
            "AWS_EC2_METADATA_SERVICE_ENDPOINT",
            "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
            "AWS_EC2_METADATA_DISABLED"
        ]
    ].

safe_close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        _:_ -> ok
    end;
safe_close(_) ->
    ok.

safe_error(Error) when is_atom(Error) ->
    Error;
safe_error(Error) when is_binary(Error), byte_size(Error) =< 128 ->
    case safe_error_binary(Error) of
        true -> Error;
        false -> backend_error
    end;
safe_error(_) ->
    backend_error.

safe_error_binary(<<>>) ->
    true;
safe_error_binary(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_ orelse
        C =:= $- orelse
        C =:= $.
->
    safe_error_binary(Rest);
safe_error_binary(_) ->
    false.

safe_reason(_Class, Reason) when is_atom(Reason) ->
    Reason;
safe_reason(Class, _Reason) ->
    Class.

normalize_timeout(Value) when is_integer(Value), Value > 0 ->
    Value;
normalize_timeout(_) ->
    ?DEFAULT_TIMEOUT_MS.

first_defined([], _Map, Default) ->
    Default;
first_defined([Key | Rest], Map, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> first_defined(Rest, Map, Default);
        Value -> Value
    end.

trim(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(_) ->
    <<>>.
