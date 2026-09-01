%%--------------------------------------------------------------------
%% Optional managed-secret owner for AWS retrieval and the persistent C port.
%% The supervisor never starts this process for the default local provider.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_secret_owner).

-behaviour(gen_server).

-export([
    start_link/1,
    ready/0,
    status/0,
    reload/1,
    generate_identity/1,
    public_key/1,
    npub/2,
    sign_event/2,
    nip44_encrypt/3,
    nip44_decrypt/3
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    config = #{} :: map(),
    backend_module = damage_nsecbunker_port :: module(),
    backend_handle = undefined :: term(),
    metadata = #{} :: map(),
    vault_metadata = #{} :: map(),
    ready = false :: boolean()
}).

-spec start_link(term()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-spec ready() -> boolean().
ready() ->
    case whereis(?MODULE) of
        undefined ->
            false;
        _ ->
            try gen_server:call(?MODULE, ready, 2000) of
                true -> true;
                _ -> false
            catch
                _:_ -> false
            end
    end.

-spec status() -> map().
status() ->
    case whereis(?MODULE) of
        undefined ->
            #{ready => false, reason => not_started};
        _ ->
            case safe_call(status, 5000) of
                Status when is_map(Status) -> Status;
                {error, Reason} -> #{ready => false, reason => Reason};
                _ -> #{ready => false, reason => invalid_status_response}
            end
    end.

-spec reload(term()) -> ok | {error, term()}.
reload(Config) -> safe_call({reload, damage_nsecbunker_config:normalize(Config)}, 60000).

-spec generate_identity(timeout()) -> {ok, map()} | {error, term()}.
generate_identity(Timeout) -> operation(generate_identity, #{}, Timeout).
-spec public_key(timeout()) -> {ok, map()} | {error, term()}.
public_key(Timeout) -> operation(public_key, #{}, Timeout).
-spec npub(binary(), timeout()) -> {ok, map()} | {error, term()}.
npub(Pubkey, Timeout) when is_binary(Pubkey) ->
    operation(npub, #{pubkey => Pubkey}, Timeout);
npub(_, _) ->
    {error, invalid_pubkey}.
-spec sign_event(map(), timeout()) -> {ok, map()} | {error, term()}.
sign_event(Event, Timeout) when is_map(Event) ->
    operation(sign_event, #{event => Event}, Timeout);
sign_event(_, _) ->
    {error, invalid_event}.
-spec nip44_encrypt(binary(), binary(), timeout()) -> {ok, map()} | {error, term()}.
nip44_encrypt(ClientPubkey, Plaintext, Timeout) when
    is_binary(ClientPubkey), is_binary(Plaintext)
->
    operation(
        nip44_encrypt,
        #{client_pubkey => ClientPubkey, plaintext => Plaintext},
        Timeout
    );
nip44_encrypt(_, _, _) ->
    {error, invalid_nip44_encrypt_request}.
-spec nip44_decrypt(binary(), binary(), timeout()) -> {ok, map()} | {error, term()}.
nip44_decrypt(ClientPubkey, Ciphertext, Timeout) when
    is_binary(ClientPubkey), is_binary(Ciphertext)
->
    operation(
        nip44_decrypt,
        #{client_pubkey => ClientPubkey, ciphertext => Ciphertext},
        Timeout
    );
nip44_decrypt(_, _, _) ->
    {error, invalid_nip44_decrypt_request}.

operation(Name, Data, Timeout0) ->
    Timeout = normalize_timeout(Timeout0),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    safe_call({operation, Name, Data, Deadline}, Timeout + 1000).

init(Config0) ->
    process_flag(trap_exit, true),
    Config = damage_nsecbunker_config:normalize(Config0),
    case bootstrap(Config) of
        {ok, State} ->
            _ = erlang:garbage_collect(self()),
            {ok, State};
        {error, Reason} ->
            {stop, {secure_vault_bootstrap_failed, Reason}}
    end.

handle_call(ready, _From, State = #state{ready = Ready}) ->
    {reply, Ready, State};
handle_call(status, _From, State) ->
    {reply, public_status(State), State};
handle_call({reload, Config}, From, State) ->
    case authorized_caller(From) of
        false ->
            {reply, {error, unauthorized_custody_caller}, State};
        true ->
            case bootstrap(Config) of
                {ok, Replacement} ->
                    close_state_backend(State),
                    _ = erlang:garbage_collect(self()),
                    {reply, ok, Replacement};
                {error, Reason} ->
                    %% Candidate failed: the currently validated port remains live.
                    %% Collect temporary secret references from the rejected bootstrap.
                    _ = erlang:garbage_collect(self()),
                    {reply, {error, {secure_vault_reload_failed, Reason}}, State}
            end
    end;
handle_call({operation, Name, Data, Deadline}, From, State = #state{ready = true}) ->
    case authorized_caller(From) of
        false -> {reply, {error, unauthorized_custody_caller}, State};
        true -> execute_operation(Name, Data, Deadline, From, State)
    end;
handle_call({operation, _, _, _}, _From, State) ->
    {reply, {error, vault_sealed}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_secret_owner_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info({Port, {exit_status, Status}}, State = #state{backend_handle = Port}) ->
    {stop, {crypto_backend_exit, Status}, State#state{ready = false}};
handle_info({'EXIT', Port, Reason}, State = #state{backend_handle = Port}) ->
    {stop, {crypto_backend_exit, safe_reason(Reason)}, State#state{ready = false}};
handle_info(_Message, State) ->
    {noreply, State}.
terminate(_Reason, State) ->
    close_state_backend(State),
    ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

execute_operation(Name, Data, Deadline, {CallerPid, _Tag}, State) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false ->
            {reply, {error, crypto_backend_deadline_expired}, State};
        true ->
            Payload = operation_payload(Name, Data),
            BackendModule = State#state.backend_module,
            Reply = BackendModule:call(
                State#state.backend_handle,
                Payload,
                Remaining,
                CallerPid
            ),
            case fatal_transport_reply(Reply) of
                true ->
                    {stop, {secure_backend_transport_failed, safe_reason(Reply)}, Reply,
                        State#state{ready = false}};
                false ->
                    {reply, Reply, State}
            end
    end.

operation_payload(generate_identity, _) ->
    #{<<"op">> => <<"generate_identity">>};
operation_payload(public_key, _) ->
    #{<<"op">> => <<"get_public_key">>};
operation_payload(npub, #{pubkey := Pubkey}) ->
    #{<<"op">> => <<"npub">>, <<"pubkey_hex">> => Pubkey};
operation_payload(sign_event, #{event := Event}) ->
    #{<<"op">> => <<"sign_event">>, <<"event">> => Event};
operation_payload(
    nip44_encrypt,
    #{client_pubkey := ClientPubkey, plaintext := Plaintext}
) ->
    #{
        <<"op">> => <<"nip44_encrypt">>,
        <<"client_pubkey">> => ClientPubkey,
        <<"plaintext">> => Plaintext
    };
operation_payload(
    nip44_decrypt,
    #{client_pubkey := ClientPubkey, ciphertext := Ciphertext}
) ->
    #{
        <<"op">> => <<"nip44_decrypt">>,
        <<"client_pubkey">> => ClientPubkey,
        <<"ciphertext">> => Ciphertext
    }.

bootstrap(Config) ->
    case damage_nsecbunker_config:managed_secret_owner(Config) of
        false ->
            {error, managed_secret_owner_not_enabled};
        true ->
            case damage_nsecbunker_config:validate_production(Config) of
                ok ->
                    AwsConfig = damage_nsecbunker_config:aws_secret(Config),
                    BackendModule = damage_nsecbunker_port,
                    UnlockTimeout = positive_integer(
                        maps:get(crypto_unlock_timeout_ms, Config, 15000), 15000
                    ),
                    case
                        damage_aws_runtime:with_runtime(
                            Config,
                            fun(ImdsMetadata) ->
                                damage_aws_secret_provider:
                                    fetch_vault_passphrase(
                                        AwsConfig,
                                        #{
                                            imdsv2_metadata =>
                                                ImdsMetadata
                                        }
                                    )
                            end
                        )
                    of
                        {ok, Passphrase, Metadata} when
                            is_binary(Passphrase),
                            byte_size(Passphrase) > 0,
                            is_map(Metadata)
                        ->
                            %% AWS and aws_credentials have been stopped
                            %% successfully before the persistent custody
                            %% backend is opened. A teardown failure therefore
                            %% cannot orphan an unlocked backend handle.
                            open_and_unlock(
                                Config,
                                BackendModule,
                                Passphrase,
                                Metadata,
                                UnlockTimeout
                            );
                        {error, _} = Error ->
                            Error;
                        _ ->
                            {error, invalid_aws_secret_bootstrap_result}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

open_and_unlock(Config, BackendModule, Passphrase, Metadata, UnlockTimeout) ->
    case BackendModule:open(Config) of
        {ok, Handle} ->
            case BackendModule:unlock(Handle, Passphrase, UnlockTimeout) of
                {ok, VaultMetadata} when is_map(VaultMetadata) ->
                    case validate_vault_identity(Config, VaultMetadata) of
                        ok ->
                            {ok, #state{
                                config = Config,
                                backend_module = BackendModule,
                                backend_handle = Handle,
                                metadata = Metadata#{backend_protocol => framed_stdio_v2},
                                vault_metadata = redact_vault_metadata(VaultMetadata),
                                ready = true
                            }};
                        {error, Reason} ->
                            ok = safe_close_backend(BackendModule, Handle),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    ok = safe_close_backend(BackendModule, Handle),
                    {error, {crypto_backend_unlock_failed, safe_reason(Reason)}};
                _ ->
                    ok = safe_close_backend(BackendModule, Handle),
                    {error, invalid_crypto_backend_unlock_result}
            end;
        {error, Reason} ->
            {error, {crypto_backend_open_failed, safe_reason(Reason)}}
    end.

public_status(State) ->
    #{
        ready => State#state.ready,
        backend => safe_backend_status(
            State#state.backend_module,
            State#state.backend_handle
        ),
        secret_provenance => State#state.metadata,
        vault => State#state.vault_metadata
    }.

validate_vault_identity(Config, Metadata) ->
    Actual = metadata_binary(pubkey_hex, Metadata),
    Expected = expected_pubkey(Config),
    Created = metadata_boolean(vault_created, Metadata),
    case {valid_pubkey_hex(Actual), valid_pubkey_hex(Expected), Created} of
        {false, _, _} ->
            {error, invalid_unlocked_vault_pubkey};
        {true, true, _} when Actual =:= Expected ->
            ok;
        {true, true, _} ->
            {error, vault_pubkey_mismatch};
        {true, false, true} ->
            %% Initial create_if_missing ceremony: the public identity is
            %% exported and must be pinned before the next production start.
            ok;
        {true, false, false} ->
            {error, production_bunker_pubkey_required}
    end.

expected_pubkey(Config) ->
    to_binary(
        case maps:get(bunker_pubkey_hex, Config, undefined) of
            undefined -> maps:get(bunker_pubkey, Config, undefined);
            Value -> Value
        end
    ).

metadata_binary(Key, Metadata) ->
    to_binary(
        case maps:get(Key, Metadata, undefined) of
            undefined -> maps:get(atom_to_binary(Key, utf8), Metadata, undefined);
            Value -> Value
        end
    ).

metadata_boolean(Key, Metadata) ->
    case maps:get(Key, Metadata, maps:get(atom_to_binary(Key, utf8), Metadata, false)) of
        true -> true;
        _ -> false
    end.

valid_pubkey_hex(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    lists:all(fun is_hex/1, binary_to_list(Value));
valid_pubkey_hex(_) ->
    false.

is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(C) when C >= $A, C =< $F -> true;
is_hex(_) -> false.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.

redact_vault_metadata(Metadata) ->
    maps:with(
        [
            <<"vault_created">>,
            <<"pubkey_hex">>,
            <<"npub">>,
            vault_created,
            pubkey_hex,
            npub
        ],
        Metadata
    ).

safe_backend_status(BackendModule, Handle) ->
    try BackendModule:status(Handle) of
        Status when is_map(Status) -> maps:remove(owner, Status);
        _ -> #{connected => false}
    catch
        _:_ -> #{connected => false}
    end.

close_state_backend(#state{backend_module = Module, backend_handle = Handle}) ->
    safe_close_backend(Module, Handle).

safe_close_backend(BackendModule, Handle) ->
    try BackendModule:close(Handle) of
        _ -> ok
    catch
        _:_ -> ok
    end.

authorized_caller({CallerPid, _Tag}) when is_pid(CallerPid) ->
    CallerPid =:= whereis(damage_nsecbunker);
authorized_caller(_) ->
    false.

fatal_transport_reply({error, crypto_backend_timeout}) -> true;
fatal_transport_reply({error, crypto_backend_caller_gone}) -> true;
fatal_transport_reply({error, crypto_backend_closed}) -> true;
fatal_transport_reply({error, crypto_backend_request_id_mismatch}) -> true;
fatal_transport_reply({error, invalid_crypto_backend_response}) -> true;
fatal_transport_reply({error, crypto_backend_bad_envelope}) -> true;
fatal_transport_reply({error, crypto_backend_response_not_object}) -> true;
fatal_transport_reply({error, crypto_backend_invalid_json}) -> true;
fatal_transport_reply({error, {crypto_backend_exit, _}}) -> true;
fatal_transport_reply(_) -> false.

safe_call(Request, Timeout) ->
    case whereis(?MODULE) of
        undefined ->
            {error, secure_vault_owner_not_running};
        _ ->
            try gen_server:call(?MODULE, Request, Timeout) of
                Reply -> Reply
            catch
                exit:{timeout, _} -> {error, crypto_backend_timeout};
                exit:{noproc, _} -> {error, secure_vault_owner_not_running};
                exit:Reason -> {error, {secure_vault_owner_exit, safe_reason(Reason)}}
            end
    end.

normalize_timeout(Value) when is_integer(Value), Value > 0 -> Value;
normalize_timeout(_) -> 10000.
positive_integer(Value, _) when is_integer(Value), Value > 0 -> Value;
positive_integer(_, Default) -> Default.

safe_reason({error, Reason}) -> safe_reason(Reason);
safe_reason(Reason) when is_atom(Reason) -> Reason;
safe_reason({Tag, Value}) when is_atom(Tag), is_atom(Value) -> {Tag, Value};
safe_reason({Tag, _}) when is_atom(Tag) -> Tag;
safe_reason(_) -> secure_backend_failure.
