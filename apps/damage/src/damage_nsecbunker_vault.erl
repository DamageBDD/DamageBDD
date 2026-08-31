%%--------------------------------------------------------------------
%% damage_nsecbunker_vault
%%
%% Vault/crypto facade. The configured secret provider selects the custody
%% path: local preserves the historical one-shot backend; AWS delegates to the
%% optional supervised managed-secret owner. No runtime infrastructure probe
%% silently changes providers.
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
    sign_event/2, sign_event/3,
    nip44_decrypt/3,
    nip44_encrypt/3
]).

-record(vault, {config = #{}, policy = #{}, path = <<>>, backend = undefined}).

init(Config0, Policy) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    Path = bin(
        maps:get(
            vault_path,
            Config,
            "/var/lib/damage/nsecbunker/genesis.vault"
        )
    ),
    #vault{
        config = Config,
        policy = Policy,
        path = Path,
        backend = backend_mode(Config)
    }.

status(Vault = #vault{path = Path, backend = Backend}) ->
    #{
        vault_path => Path,
        backend => backend_status(Backend),
        guard_state => guard_state(Vault)
    }.

guard_state(Vault = #vault{policy = Policy, backend = secure_owner}) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case valid_pubkey(Expected) of
        false ->
            sealed(missing_bunker_pubkey, <<>>);
        true ->
            case public_key(Vault) of
                {ok, Expected} ->
                    #{sealed => false, integrity => ok, pubkey_hex => Expected};
                {ok, Actual} ->
                    sealed(vault_pubkey_mismatch, Actual);
                {error, Reason} ->
                    sealed(Reason, Expected)
            end
    end;
guard_state(#vault{
    config = Config,
    policy = Policy,
    backend = {legacy, {ok, _Cmd}}
}) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case {valid_pubkey(Expected), local_vault_passphrase(Config)} of
        {false, _} -> sealed(missing_bunker_pubkey, <<>>);
        {true, {ok, _}} -> #{sealed => false, integrity => ok, pubkey_hex => Expected};
        {true, error} -> sealed(missing_vault_passphrase, Expected)
    end;
guard_state(#vault{backend = {legacy, {error, Reason}}, policy = Policy}) ->
    sealed(Reason, maps:get(bunker_pubkey_hex, Policy, <<>>));
guard_state(#vault{backend = {error, Reason}, policy = Policy}) ->
    sealed(Reason, maps:get(bunker_pubkey_hex, Policy, <<>>)).

generate_identity(Vault = #vault{backend = secure_owner}) ->
    owner_result(damage_nsecbunker_secret_owner:generate_identity(timeout(Vault)));
generate_identity(Vault = #vault{path = Path}) ->
    local_call(Vault, #{op => <<"generate_identity">>, vault_path => Path}).

export_identity(Vault, Config, Policy) ->
    case public_key(Vault) of
        {ok, Pubkey} ->
            case configured_or_backend_npub(Vault, Config, Pubkey) of
                {ok, Npub} ->
                    {ok, #{
                        pubkey_hex => Pubkey,
                        npub => Npub,
                        bunker_uri_pattern => uri_pattern(Pubkey, Config),
                        policy => public_policy(Policy)
                    }};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

public_key(Vault = #vault{policy = Policy, backend = secure_owner}) ->
    case damage_nsecbunker_secret_owner:ready() of
        false ->
            {error, secure_vault_owner_not_ready};
        true ->
            case
                owner_field(
                    damage_nsecbunker_secret_owner:public_key(timeout(Vault)),
                    pubkey_hex
                )
            of
                {ok, Actual} ->
                    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
                    case valid_pubkey(Expected) andalso Actual =/= Expected of
                        true -> {error, vault_pubkey_mismatch};
                        false -> {ok, Actual}
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
public_key(#vault{policy = Policy, path = Path} = Vault) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case valid_pubkey(Expected) of
        true ->
            {ok, Expected};
        false ->
            local_call_field(
                Vault, #{op => <<"get_public_key">>, vault_path => Path}, pubkey_hex
            )
    end.

bunker_uri_pattern(Vault, Config) ->
    case public_key(Vault) of
        {ok, Pubkey} -> {ok, uri_pattern(Pubkey, Config)};
        {error, _} = Error -> Error
    end.

sign_event(Vault, Event) -> sign_event(Vault, Event, timeout(Vault)).
sign_event(Vault = #vault{backend = secure_owner}, Event0, Timeout) ->
    case public_key(Vault) of
        {ok, Pubkey} ->
            Event = damage_nostr_event:ensure_event_id(Event0#{pubkey => Pubkey}),
            owner_field(damage_nsecbunker_secret_owner:sign_event(Event, Timeout), event);
        {error, _} = Error ->
            Error
    end;
sign_event(Vault = #vault{path = Path}, Event0, Timeout) ->
    case public_key(Vault) of
        {ok, Pubkey} ->
            Event = damage_nostr_event:ensure_event_id(
                Event0#{pubkey => Pubkey}
            ),
            local_call_field(
                Vault,
                #{
                    op => <<"sign_event">>,
                    vault_path => Path,
                    event => Event
                },
                event,
                Timeout
            );
        {error, _} = Error ->
            Error
    end.

local_call(Vault, Payload) ->
    local_call(Vault, Payload, timeout(Vault)).

local_call(#vault{backend = {error, Reason}}, _Payload, _Timeout) ->
    {error, Reason};
local_call(#vault{backend = secure_owner}, _Payload, _Timeout) ->
    {error, generic_production_backend_call_forbidden};
local_call(#vault{backend = {legacy, {error, Reason}}}, _Payload, _Timeout) ->
    {error, Reason};
local_call(Vault = #vault{backend = {legacy, {ok, _Cmd}}}, Payload, Timeout) ->
    normalize_local_result(
        damage_nsecbunker_legacy_backend:call(
            local_backend_config(Vault),
            Payload,
            Timeout
        )
    ).

local_call_field(Vault, Payload, Field) ->
    local_call_field(Vault, Payload, Field, timeout(Vault)).

local_call_field(Vault, Payload, Field, Timeout) ->
    case local_call(Vault, Payload, Timeout) of
        {ok, Map} when is_map(Map) ->
            case get_field(Field, Map) of
                undefined ->
                    {error, {missing_backend_response_field, Field}};
                Value ->
                    {ok, Value}
            end;
        {error, _} = Error ->
            Error;
        Other ->
            {error, {bad_backend_response, Other}}
    end.

normalize_local_result({error, {crypto_backend_rejected, Reason}}) ->
    {error, Reason};
normalize_local_result(Result) ->
    Result.

local_backend_config(#vault{
    config = Config,
    path = Path,
    backend = {legacy, {ok, Cmd}}
}) ->
    Config#{
        crypto_backend_cmd => Cmd,
        vault_path => Path
    }.

nip44_decrypt(Vault = #vault{backend = secure_owner}, ClientPubkey, Ciphertext) ->
    owner_field(
        damage_nsecbunker_secret_owner:nip44_decrypt(
            bin(ClientPubkey), bin(Ciphertext), timeout(Vault)
        ),
        plaintext
    );
nip44_decrypt(Vault = #vault{path = Path}, ClientPubkey, Ciphertext) ->
    local_call_field(
        Vault,
        #{
            op => <<"nip44_decrypt">>,
            vault_path => Path,
            client_pubkey => ClientPubkey,
            ciphertext => Ciphertext
        },
        plaintext
    ).

nip44_encrypt(Vault = #vault{backend = secure_owner}, ClientPubkey, Plaintext) ->
    owner_field(
        damage_nsecbunker_secret_owner:nip44_encrypt(
            bin(ClientPubkey), bin(Plaintext), timeout(Vault)
        ),
        ciphertext
    );
nip44_encrypt(Vault = #vault{path = Path}, ClientPubkey, Plaintext) ->
    local_call_field(
        Vault,
        #{
            op => <<"nip44_encrypt">>,
            vault_path => Path,
            client_pubkey => ClientPubkey,
            plaintext => Plaintext
        },
        ciphertext
    ).

configured_or_backend_npub(Vault = #vault{backend = secure_owner}, Config, Pubkey) ->
    case maps:get(bunker_npub, Config, undefined) of
        undefined ->
            owner_field(
                damage_nsecbunker_secret_owner:npub(Pubkey, timeout(Vault)), npub
            );
        Npub ->
            {ok, bin(Npub)}
    end;
configured_or_backend_npub(Vault, Config, Pubkey) ->
    case maps:get(bunker_npub, Config, undefined) of
        undefined ->
            local_call_field(
                Vault, #{op => <<"npub">>, pubkey_hex => Pubkey}, npub
            );
        Npub ->
            {ok, bin(Npub)}
    end.

owner_result({ok, Map}) when is_map(Map) -> {ok, normalize_backend(Map)};
owner_result({error, _} = Error) -> Error;
owner_result(Other) -> {error, {bad_backend_response, Other}}.
owner_field(Result, Field) ->
    case owner_result(Result) of
        {ok, Map} ->
            case get_field(Field, Map) of
                undefined -> {error, {missing_backend_response_field, Field}};
                Value -> {ok, Value}
            end;
        {error, _} = Error ->
            Error
    end.

backend_mode(Config) ->
    case damage_nsecbunker_config:secret_provider(Config) of
        aws_secrets_manager -> secure_owner;
        local -> {legacy, backend_cmd(Config)};
        Other -> {error, {unsupported_nsecbunker_secret_provider, Other}}
    end.

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
        {ok, #file_info{type = regular, mode = Mode}} -> (Mode band 8#111) =/= 0;
        _ -> false
    end.

backend_status(secure_owner) ->
    damage_nsecbunker_secret_owner:status();
backend_status({legacy, {ok, Cmd}}) ->
    #{configured => true, executable => true, mode => local_secret, cmd => Cmd};
backend_status({legacy, {error, Reason}}) ->
    #{configured => false, mode => local_secret, reason => Reason};
backend_status({error, Reason}) ->
    #{configured => false, reason => Reason}.

local_vault_passphrase(Config) ->
    case damage_nsecbunker_config:secret_provider(Config) of
        local ->
            case damage_nsecbunker_local_secret_provider:fetch(Config) of
                {ok, Passphrase} ->
                    {ok, Passphrase};
                {error, _Reason} ->
                    error
            end;
        _ ->
            %% A managed provider is never allowed to downgrade to local
            %% custody when its bootstrap fails.
            error
    end.

normalize_backend(Map) when is_map(Map) ->
    maps:from_list([{normalize_key(K), normalize_backend(V)} || {K, V} <- maps:to_list(Map)]);
normalize_backend(List) when is_list(List) -> [normalize_backend(V) || V <- List];
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

sealed(Reason, Pubkey) -> #{sealed => true, integrity => Reason, pubkey_hex => Pubkey}.
timeout(#vault{config = Config}) ->
    case maps:get(crypto_timeout_ms, Config, 10000) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> 10000
    end.

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
    RelayQuery = relay_query(maps:get(relays, Config, [])),
    Secret = maps:get(secret_hint, Config, <<"<out-of-band-secret>">>),
    iolist_to_binary([
        <<"bunker://">>,
        Pubkey,
        <<"?">>,
        RelayQuery,
        <<"&secret=">>,
        bin(Secret)
    ]).
relay_query([]) -> <<"relay=">>;
relay_query(Relays) -> join([<<"relay=", (url_quote(bin(R)))/binary>> || R <- Relays], <<"&">>).
url_quote(Bin) -> iolist_to_binary([url_quote_char(C) || <<C>> <= Bin]).
url_quote_char(C) when C >= $a, C =< $z -> <<C>>;
url_quote_char(C) when C >= $A, C =< $Z -> <<C>>;
url_quote_char(C) when C >= $0, C =< $9 -> <<C>>;
url_quote_char(C) when C =:= $-; C =:= $_; C =:= $.; C =:= $~ -> <<C>>;
url_quote_char(C) -> iolist_to_binary(io_lib:format("%~2.16.0B", [C])).
join([], _) -> <<>>;
join([One], _) -> One;
join([H | T], Sep) -> lists:foldl(fun(E, A) -> <<A/binary, Sep/binary, E/binary>> end, H, T).

valid_pubkey(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    Bin =/= <<"BUNKER_PUBKEY_HEX">>;
valid_pubkey(_) ->
    false.
first_defined([], _, Default) ->
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
