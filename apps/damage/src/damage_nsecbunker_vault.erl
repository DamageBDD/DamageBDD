%%--------------------------------------------------------------------
%% damage_nsecbunker_vault
%%
%% Vault/crypto boundary for the in-tree Damage NIP-46 bunker.
%% Phase 2B C backend patch: every backend call carries vault_path.
%% This module never returns nsec material. Until a crypto backend executable
%% is configured, every identity/sign/encrypt/decrypt operation fails closed.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_vault).

-include_lib("kernel/include/file.hrl").
-export([
    init/2,
    status/1,
    guard_state/1,
    generate_identity/1,
    export_identity/3,
    public_key/1,
    bunker_uri_pattern/2,
    sign_event/2,
    nip44_decrypt/3,
    nip44_encrypt/3
]).

-record(vault, {
    config = #{},
    policy = #{},
    path = <<>>,
    backend = undefined
}).

init(Config, Policy) ->
    Path = bin(maps:get(vault_path, Config, "/var/lib/damage/nsecbunker/lodgeit_genesis.vault")),
    #vault{config = Config, policy = Policy, path = Path, backend = backend_cmd(Config)}.

status(Vault = #vault{path = Path, backend = Backend}) ->
    #{
        vault_path => Path,
        backend => backend_status(Backend),
        guard_state => guard_state(Vault)
    }.

%% State expected by damage_nsecbunker_vault_guard.
guard_state(#vault{policy = Policy, backend = {ok, _Cmd}}) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case valid_pubkey(Expected) of
        true -> #{sealed => false, integrity => ok, pubkey_hex => Expected};
        false -> #{sealed => true, integrity => missing_bunker_pubkey, pubkey_hex => <<>>}
    end;
guard_state(#vault{backend = {error, Reason}, policy = Policy}) ->
    #{
        sealed => true,
        integrity => Reason,
        pubkey_hex => maps:get(bunker_pubkey_hex, Policy, <<>>)
    }.

generate_identity(Vault = #vault{path = Path}) ->
    call_backend(Vault, #{op => <<"generate_identity">>, vault_path => Path}).

export_identity(Vault, Config, Policy) ->
    case public_key(Vault) of
        {ok, Pubkey} ->
            NpubResult =
                case maps:get(bunker_npub, Config, undefined) of
                    undefined ->
                        call_backend_field(Vault, #{op => <<"npub">>, pubkey_hex => Pubkey}, npub);
                    Npub ->
                        {ok, bin(Npub)}
                end,
            case NpubResult of
                {ok, Npub0} ->
                    {ok, #{
                        pubkey_hex => Pubkey,
                        npub => Npub0,
                        bunker_uri_pattern => uri_pattern(Pubkey, Config),
                        policy => public_policy(Policy)
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

public_key(#vault{policy = Policy, path = Path} = Vault) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case valid_pubkey(Expected) of
        true ->
            {ok, Expected};
        false ->
            call_backend_field(Vault, #{op => <<"get_public_key">>, vault_path => Path}, pubkey_hex)
    end.

bunker_uri_pattern(Vault, Config) ->
    case public_key(Vault) of
        {ok, Pubkey} -> {ok, uri_pattern(Pubkey, Config)};
        {error, Reason} -> {error, Reason}
    end.

sign_event(#vault{path = Path} = Vault, Event0) ->
    case public_key(Vault) of
        {ok, Pubkey} ->
            Event = damage_nostr_event:ensure_event_id(Event0#{pubkey => Pubkey}),
            call_backend_field(
                Vault, #{op => <<"sign_event">>, vault_path => Path, event => Event}, event
            );
        {error, Reason} ->
            {error, Reason}
    end.

nip44_decrypt(#vault{path = Path} = Vault, ClientPubkey, Ciphertext) ->
    call_backend_field(
        Vault,
        #{
            op => <<"nip44_decrypt">>,
            vault_path => Path,
            client_pubkey => ClientPubkey,
            ciphertext => Ciphertext
        },
        plaintext
    ).

nip44_encrypt(#vault{path = Path} = Vault, ClientPubkey, Plaintext) ->
    call_backend_field(
        Vault,
        #{
            op => <<"nip44_encrypt">>,
            vault_path => Path,
            client_pubkey => ClientPubkey,
            plaintext => Plaintext
        },
        ciphertext
    ).

%%--------------------------------------------------------------------
%% Backend port protocol
%%--------------------------------------------------------------------

backend_cmd(Config) ->
    Cmd0 = first_defined([crypto_backend_cmd, crypto_port_cmd], Config, undefined),
    case Cmd0 of
        undefined ->
            {error, crypto_backend_not_configured};
        Cmd when is_binary(Cmd) -> backend_cmd(Config#{crypto_backend_cmd => binary_to_list(Cmd)});
        Cmd when is_list(Cmd) ->
            case executable_file(Cmd) of
                true -> {ok, Cmd};
                false -> {error, {crypto_backend_not_executable, Cmd}}
            end;
        Other ->
            {error, {invalid_crypto_backend_cmd, Other}}
    end.

executable_file(Cmd) when is_list(Cmd) ->
    case file:read_file_info(Cmd) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            (Mode band 8#111) =/= 0;
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Cmd) of
                {ok, LinkTarget} ->
                    executable_file(filename:absname(LinkTarget, filename:dirname(Cmd)));
                {error, _} ->
                    false
            end;
        _ ->
            false
    end.

backend_status({ok, Cmd}) ->
    #{configured => true, executable => true, cmd => Cmd};
backend_status({error, Reason}) ->
    #{configured => false, reason => Reason}.

call_backend(#vault{backend = {error, Reason}}, _Payload) ->
    {error, Reason};
call_backend(#vault{backend = {ok, Cmd}, config = Config}, Payload) ->
    Timeout = maps:get(crypto_timeout_ms, Config, 5000),
    call_port(Cmd, Payload, Timeout).

call_backend_field(Vault, Payload, Field) ->
    case call_backend(Vault, Payload) of
        {ok, Map} when is_map(Map) ->
            case get_field(Field, Map) of
                undefined -> {error, {missing_backend_response_field, Field}};
                Value -> {ok, Value}
            end;
        {error, _} = Error ->
            Error;
        Other ->
            {error, {bad_backend_response, Other}}
    end.

call_port(Cmd, Payload, Timeout) ->
    try open_port({spawn_executable, Cmd}, [binary, use_stdio, exit_status, stderr_to_stdout]) of
        Port ->
            Json = jsx:encode(Payload),
            true = port_command(Port, <<Json/binary, "\n">>),
            collect_port(Port, Timeout, <<>>)
    catch
        Class:Reason -> {error, {crypto_backend_open_failed, Class, Reason}}
    end.

collect_port(Port, Timeout, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, Timeout, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            decode_backend_response(Acc);
        {Port, {exit_status, Status}} ->
            {error, {crypto_backend_exit, Status, Acc}}
    after Timeout ->
        safe_port_close(Port),
        {error, crypto_backend_timeout}
    end.

safe_port_close(Port) ->
    try erlang:port_close(Port) of
        _ ->
            ok
    catch
        error:badarg ->
            ok;
        _:_ ->
            ok
    end.
decode_backend_response(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        #{<<"ok">> := true, <<"result">> := Result} -> {ok, normalize_backend(Result)};
        #{<<"ok">> := false, <<"error">> := Error} -> {error, Error};
        #{ok := true, result := Result} -> {ok, normalize_backend(Result)};
        #{ok := false, error := Error} -> {error, Error};
        Map when is_map(Map) -> {ok, normalize_backend(Map)}
    catch
        _:Reason -> {error, {invalid_crypto_backend_json, Reason, Bin}}
    end.

normalize_backend(Map) when is_map(Map) ->
    maps:from_list([{normalize_key(K), normalize_backend(V)} || {K, V} <- maps:to_list(Map)]);
normalize_backend(List) when is_list(List) ->
    [normalize_backend(V) || V <- List];
normalize_backend(Other) ->
    Other.

normalize_key(K) when is_binary(K) ->
    try
        binary_to_existing_atom(K, utf8)
    catch
        _:_ -> K
    end;
normalize_key(K) ->
    K.

get_field(Field, Map) ->
    case maps:get(Field, Map, undefined) of
        undefined when is_atom(Field) -> maps:get(atom_to_binary(Field, utf8), Map, undefined);
        Value -> Value
    end.

%%--------------------------------------------------------------------
%% Public/custody helpers
%%--------------------------------------------------------------------

public_policy(Policy) ->
    #{
        bunker_pubkey_hex => maps:get(bunker_pubkey_hex, Policy, <<>>),
        contract_sha => maps:get(contract_sha, Policy, <<>>),
        authorized_clients_count => length(maps:get(authorized_clients, Policy, [])),
        allowed_methods => maps:get(allowed_methods, Policy, []),
        allowed_kinds => maps:get(allowed_kinds, Policy, []),
        created_at_skew_seconds => maps:get(created_at_skew_seconds, Policy, undefined),
        max_event_bytes => maps:get(max_event_bytes, Policy, #{}),
        required_tags => maps:get(required_tags, Policy, #{}),
        reject_active_content => maps:get(reject_active_content, Policy, true),
        bunker_publishes => maps:get(bunker_publishes, Policy, false),
        rate_limit => maps:get(rate_limit, Policy, #{})
    }.

uri_pattern(Pubkey, Config) ->
    Relays = maps:get(relays, Config, []),
    RelayQuery = relay_query(Relays),
    Secret = maps:get(secret_hint, Config, <<"<out-of-band-secret>">>),
    iolist_to_binary([<<"bunker://">>, Pubkey, <<"?">>, RelayQuery, <<"&secret=">>, bin(Secret)]).

relay_query([]) ->
    <<"relay=">>;
relay_query(Relays) ->
    Encoded = [<<"relay=", (url_quote(bin(Relay)))/binary>> || Relay <- Relays],
    join(Encoded, <<"&">>).

url_quote(Bin) when is_binary(Bin) ->
    iolist_to_binary([url_quote_char(C) || <<C>> <= Bin]).

url_quote_char(C) when C >= $a, C =< $z -> <<C>>;
url_quote_char(C) when C >= $A, C =< $Z -> <<C>>;
url_quote_char(C) when C >= $0, C =< $9 -> <<C>>;
url_quote_char($-) -> <<"-">>;
url_quote_char($_) -> <<"_">>;
url_quote_char($.) -> <<".">>;
url_quote_char($~) -> <<"~">>;
url_quote_char(C) -> iolist_to_binary(io_lib:format("%~2.16.0B", [C])).

join([], _Sep) -> <<>>;
join([One], _Sep) -> One;
join([H | T], Sep) -> lists:foldl(fun(E, Acc) -> <<Acc/binary, Sep/binary, E/binary>> end, H, T).

valid_pubkey(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    Bin =/= <<"BUNKER_PUBKEY_HEX">>;
valid_pubkey(_) ->
    false.

first_defined([], _Map, Default) ->
    Default;
first_defined([Key | Rest], Map, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> first_defined(Rest, Map, Default);
        Value -> Value
    end.

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
