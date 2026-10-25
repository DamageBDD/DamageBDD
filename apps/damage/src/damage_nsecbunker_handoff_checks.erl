%% Bounded, evidence-producing checks for the original AWS bunker handoff.
%% No AWS writes, identity generation, passphrase storage or provider fallback.
-module(damage_nsecbunker_handoff_checks).
-include_lib("kernel/include/file.hrl").
-export([snapshot/0, assess/1, fingerprint/1, target/1, check/3,
    verify_exchange/5, correlate/4, recovery/1, public_error/1]).

snapshot() ->
    C = damage_nsecbunker_config:load(),
    B = safe(fun damage_nsecbunker:status/0),
    O = safe(fun damage_nsecbunker_secret_owner:status/0),
    RuntimePolicy = safe(fun()->gen_server:call(damage_nsecbunker,handoff_status,2000) end),
    R = safe(fun damage_nsecbunker_relay:status/0),
    Local = try secrets:retrieve_secret(nsecbunker_vault_passphrase) of
        [] -> absent;
        [_ | _] -> present;
        _ -> unknown
    catch _:_ -> unknown end,
    #{config => C, bunker => B, owner => O, relay => R, local_secret => Local,
        runtime_policy => RuntimePolicy,
        runtime_instance => pid_bin(whereis(damage_nsecbunker)),
        provenance_revision => maps:get(version_id, maps:get(secret_provenance, O, #{}), undefined),
        code_revision => [{M, module_md5(M)} || M <- [damage_nsecbunker,
            damage_nsecbunker_gate, damage_nsecbunker_policy, damage_nsecbunker_port,
            damage_nsecbunker_secret_owner, damage_aws_secret_provider,
            damage_nip46, damage_nostr_event, steps_nsecbunker_live,
            damage_nsecbunker_handoff, damage_nsecbunker_handoff_checks,
            damage_nsecbunker_handoff_recovery,
            damage_nsecbunker_audit, damage_nsecbunker_relay, damage_nostr_relay_client,
            damage_nsecbunker_config, damage_aws_runtime, damage_aws_imdsv2]],
        backend_artifact => vault_state(maps:get(crypto_backend_cmd, C, <<>>)),
        vault_file => vault_state(maps:get(vault_path, C, <<>>)),
        audit_file => file_state(maps:get(audit_log, C, <<>>))}.

assess(S) ->
    C = maps:get(config, S, #{}), B = maps:get(bunker, S, #{}),
    O = maps:get(owner, S, #{}), R = maps:get(relay, S, #{}),
    P = damage_nsecbunker:policy(C), A = damage_nsecbunker_config:aws_secret(C),
    Provenance = maps:get(secret_provenance, O, #{}),
    Expected = maps:get(bunker_pubkey_hex, P, <<>>),
    Guard = maps:get(guard_state, maps:get(vault, B, #{}), #{}),
    AllowedMethods = [<<"connect">>, <<"ping">>, <<"get_public_key">>, <<"sign_event">>],
    Methods = maps:get(allowed_methods, P, []),
    Clients = maps:get(authorized_clients, P, []),
    Relays = maps:get(relays, C, []),
    ConfigOK = damage_nsecbunker_config:validate_production(C) =:= ok,
    [check(service_ready, maps:get(ready, B, false) =:= true,
        <<"The running bunker must be ready.">>),
     check(aws_only, ConfigOK andalso damage_nsecbunker_config:production(C) andalso
        damage_nsecbunker_config:secret_provider(C) =:= aws_secrets_manager andalso
        damage_nsecbunker_config:vault_mode(C) =:= open_existing,
        <<"Select production AWS custody and open the existing vault.">>),
     check(local_secret_absent, maps:get(local_secret, S, unknown) =:= absent,
        <<"Remove the local nsecbunker vault-passphrase entry; unknown is not a pass.">>),
     check(identity_pinned, hex64(Expected) andalso maps:get(pubkey_hex, Guard, <<>>) =:= Expected
        andalso maps:get(sealed, Guard, true) =:= false,
        <<"Compare the vault identity with the independently pinned signing key.">>),
     check(aws_provenance, maps:get(ready, O, false) =:= true andalso
        maps:get(credential_provider, Provenance, undefined) =:= aws_credentials_ec2 andalso
        maps:get(imds_protocol, Provenance, undefined) =:= imdsv2 andalso
        maps:get(account_id, Provenance, undefined) =:= bin(maps:get(expected_account_id, A, <<>>)) andalso
        maps:get(role_name, Provenance, undefined) =:= bin(maps:get(expected_role_name, A, <<>>)) andalso
        maps:get(secret_id_sha256, Provenance, undefined) =:= sha(bin(maps:get(secret_id, A, <<>>))) andalso
        lists:member(<<"AWSCURRENT">>, maps:get(version_stages, Provenance, [])),
        <<"Freshly unlock using the expected EC2 role and AWSCURRENT secret.">>),
     check(narrow_policy, Methods =/= [] andalso
        lists:all(fun(M) -> lists:member(M, AllowedMethods) end, Methods) andalso
        maps:get(bunker_publishes, P, true) =:= false andalso
        maps:get(reject_active_content, P, false) =:= true,
        <<"Restrict methods to the ratified signing policy; keep publishing disabled.">>),
     check(runtime_policy_matches, maps:get(policy_fingerprint,maps:get(runtime_policy,S,#{}),undefined)
        =:= sha(term_to_binary(P,[deterministic])) andalso
        maps:get(secret_provider,maps:get(runtime_policy,S,#{}),undefined) =:= aws_secrets_manager,
        <<"The running signer must use the deployed policy; apply approved changes and restart before verifying.">>),
     check(client_allowlist, Clients =/= [] andalso lists:all(fun hex64/1, Clients),
        <<"Configure the approved client public keys.">>),
     check(relays_subscribed, Relays =/= [] andalso length(Relays) =< 6 andalso
        lists:all(fun secure_relay/1, Relays) andalso maps:get(subscribed, R, false) =:= true,
        <<"Configure at most six explicit WSS relays and establish subscriptions.">>),
     check(backend_artifact, executable_artifact(maps:get(backend_artifact,S,#{})),
        <<"Install the regular, executable crypto backend without group/world write permission; its checksum is part of the evidence fingerprint.">>),
     check(vault_permissions, private_regular(maps:get(vault_file, S, #{})),
        <<"The encrypted vault must be a regular private file, without group/world access.">>),
     check(audit_permissions, private_regular(maps:get(audit_file, S, #{})),
        <<"Create a private regular audit file writable by the service account.">>)].

check(Id, true, Next) -> #{id => Id, status => passed, next_action => Next};
check(Id, false, Next) -> #{id => Id, status => failed, next_action => Next}.

fingerprint(S) -> sha(term_to_binary(maps:with(
    [config, runtime_instance, code_revision, vault_file, provenance_revision, backend_artifact, runtime_policy], S), [deterministic])).
target(S) ->
    C = maps:get(config, S, #{}), A = damage_nsecbunker_config:aws_secret(C),
    sha(term_to_binary({maps:get(bunker_pubkey_hex, C, <<>>), A,
        maps:get(vault_file, S, #{}), maps:get(code_revision, S, []), maps:get(backend_artifact,S,#{})}, [deterministic])).

%% Verify the transport signatures, request correlation and exact signed object.
%% This is not satisfied by a pubkey field, a relay OK or a matching event kind.
verify_exchange(Request0, Reply0, Response, Unsigned, Expected) ->
    try
        {ok, Request} = damage_nostr_event:verify(Request0),
        {ok, Reply} = damage_nostr_event:verify(Reply0),
        Client = maps:get(client, Expected), Bunker = maps:get(bunker, Expected),
        true = maps:get(pubkey, Request) =:= Client,
        true = maps:get(kind, Request) =:= 24133,
        true = damage_nostr_event:tag_values(Request, <<"p">>) =:= [Bunker],
        true = maps:get(pubkey, Reply) =:= Bunker,
        true = maps:get(kind, Reply) =:= 24133,
        true = damage_nostr_event:tag_values(Reply, <<"p">>) =:= [Client],
        true = abs(maps:get(created_at, Reply) - maps:get(created_at, Request)) =< 600,
        true = field(id, Response, <<>>) =:= maps:get(request_id, Expected),
        Error = field(error, Response, <<>>),
        case maps:get(outcome, Expected) of
            {rejected, Why} ->
                true = Error =:= Why,
                {ok, #{request_event => Request, response_event => Reply,
                    request_id => maps:get(request_id, Expected), decision => <<"rejected">>}};
            {result, Value} ->
                true = empty_error(Error),
                true = field(result, Response, undefined) =:= Value,
                {ok, #{request_event => Request, response_event => Reply,
                    request_id => maps:get(request_id, Expected), decision => <<"allowed">>}};
            signed_event ->
                true = empty_error(Error),
                Signed0 = field(result, Response, undefined),
                Signed1 = case Signed0 of
                    M when is_map(M) -> M;
                    J when is_binary(J) -> jsx:decode(J, [return_maps])
                end,
                {ok, Signed} = damage_nostr_event:verify(Signed1),
                true = maps:get(pubkey, Signed) =:= Bunker,
                Keys = [created_at, kind, tags, content],
                true = maps:with(Keys, Signed) =:= maps:with(Keys, Unsigned),
                {ok, #{request_event => Request, response_event => Reply,
                    request_id => maps:get(request_id, Expected), decision => <<"allowed">>,
                    signed_event => Signed}}
        end
    catch _:_ -> {error, exchange_verification_failed} end.

correlate(Rows, RequestId, RequestEventId, ReplyEventId) ->
    Decisions = [R || R <- Rows, field(request_id, R, undefined) =:= RequestId,
        field(schema_version, R, 0) =:= 1],
    Completions = [R || R <- Rows, field(request_id, R, undefined) =:= RequestId,
        field(phase, R, undefined) =:= <<"response_signed">>,
        field(request_event_id, R, undefined) =:= RequestEventId,
        field(response_event_id, R, undefined) =:= ReplyEventId],
    case {Decisions, Completions} of
        {[D | _], [T | _]} ->
            Keys = [requester_pubkey, method, decision, bunker_pubkey],
            case lists:all(fun(K) -> field(K, D, undefined) =:= field(K, T, missing) end, Keys) of
                true -> {ok, #{decision => D, completion => T}};
                false -> {error, audit_correlation_mismatch}
            end;
        _ -> {error, audit_correlation_missing}
    end.

%% Copy encrypted bytes only. The live vault is never replaced or opened by
%% this check. The transient worker retrieves the AWS value directly and closes
%% every port before exiting; evidence contains only public verification data.
recovery(Stage) when Stage =:= current; Stage =:= pending ->
    C = damage_nsecbunker_config:load(),
    true = damage_nsecbunker_config:secure_aws(C),
    Dir = filename:join(damage_nsecbunker_config:state_dir(),
        "handoff-recovery-" ++ binary_to_list(sha(crypto:strong_rand_bytes(16)))),
    ok = file:make_dir(Dir), ok = file:change_mode(Dir, 8#700),
    Backup = filename:join(Dir, "encrypted-backup.vault"),
    Restored = filename:join(Dir, "restored.vault"),
    try
        Source = maps:get(vault_path, C),
        #{type := regular, size := Size} = file_state(Source),
        true = Size > 0 andalso Size =< 8388608,
        {ok, Bytes} = file:read_file(Source),
        ok = private_write(Backup, Bytes),
        {ok, Copy} = file:read_file(Backup),
        ok = private_write(Restored, Copy),
        true = sha(Bytes) =:= sha(Copy),
        MetadataRestore = case Stage of
            current -> damage_nsecbunker_handoff_recovery:metadata(Dir);
            pending -> #{restored => false, reason => pending_version_only}
        end,
        A = damage_nsecbunker_config:aws_secret(C),
        Fetch = fun(Imds) ->
            D = #{imdsv2_metadata => Imds},
            case Stage of
                current -> damage_aws_secret_provider:fetch_vault_passphrase(A, D);
                pending ->
                    case damage_aws_secret_provider:fetch_vault_passphrase(A, D) of
                        {ok, _Current, CurrentMeta} ->
                            damage_aws_secret_provider:with_pending_passphrase(A, D,
                                fun(Pass, Meta) -> {ok, Pass, Meta#{baseline_version_id =>
                                    maps:get(version_id, CurrentMeta)}} end);
                        Error -> Error
                    end
            end
        end,
        case damage_aws_runtime:with_runtime(C, Fetch) of
            {ok, Passphrase, Metadata} ->
                Result = restored_check(C#{vault_path => Restored, vault_mode => open_existing}, Passphrase),
                true = sha(Bytes) =:= file_sha(Source),
                ok = rejected_unlock(C#{vault_path => Restored, vault_mode => open_existing},
                    binary:encode_hex(crypto:strong_rand_bytes(32))),
                Result#{wrong_unlock_rejected => true, secret_provenance => Metadata, vault_sha256 => sha(Bytes),
                    backup_restored => true, metadata_restore => MetadataRestore, stage => Stage};
            _ -> error(aws_retrieval_failed)
        end
    after
        file:delete(Restored), file:delete(Backup), file:del_dir(Dir),
        erlang:garbage_collect()
    end.

restored_check(C, Passphrase) ->
    {ok, Port} = damage_nsecbunker_port:open(C),
    try
        {ok, Metadata} = damage_nsecbunker_port:unlock(Port, Passphrase, 15000),
        Expected = bin(maps:get(bunker_pubkey_hex, C)),
        true = field(pubkey_hex, Metadata, <<>>) =:= Expected,
        Event = #{pubkey => Expected, kind => 1, created_at => erlang:system_time(second),
            tags => [], content => <<"DamageBDD isolated recovery verification">>},
        {ok, Result} = damage_nsecbunker_port:call(Port,
            #{<<"op">> => <<"sign_event">>, <<"event">> => damage_nostr_event:ensure_event_id(Event)},
            15000, self()),
        {ok, Signed} = damage_nostr_event:verify(field(event, Result, #{})),
        true = maps:with([pubkey, kind, created_at, tags, content], Signed) =:= Event,
        #{identity_preserved => true, signed_event => Signed}
    after damage_nsecbunker_port:close(Port) end.

private_write(Path, Bytes) ->
    {ok, Fd} = file:open(Path, [write, binary, exclusive]),
    try ok = file:change_mode(Path, 8#600), ok = file:write(Fd, Bytes), file:sync(Fd)
    after file:close(Fd) end.

vault_state(Path) ->
    Info = file_state(Path),
    case Info of
        #{type := regular, size := Size} when Size > 0, Size =< 67108864 ->
            try Info#{sha256 => file_sha(Path)} catch _:_ -> Info end;
        _ -> Info
    end.

file_state(Path) ->
    try file:read_link_info(Path) of
        {ok, #file_info{type = Type, mode = Mode, size = Size}} ->
            #{type => Type, mode => Mode band 8#777, size => Size};
        _ -> #{}
    catch _:_ -> #{} end.
executable_artifact(#{type:=regular,mode:=Mode,sha256:=Hash}) ->
    Mode band 8#111 =/= 0 andalso Mode band 8#022 =:= 0 andalso byte_size(Hash)=:=64;
executable_artifact(_) -> false.
private_regular(#{type := regular, mode := Mode}) -> Mode band 8#077 =:= 0;
private_regular(_) -> false.
file_sha(Path) -> {ok, B} = file:read_file(Path), sha(B).
hex64(B) when is_binary(B), byte_size(B) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, binary_to_list(B));
hex64(_) -> false.
secure_relay(R0) ->
    R = case R0 of #{url := URL} -> URL; _ -> R0 end,
    try uri_string:parse(bin(R)) of
        #{scheme := <<"wss">>, host := H} = U -> byte_size(H) > 0 andalso
            not lists:any(fun(K) -> maps:is_key(K, U) end, [userinfo, query, fragment]);
        _ -> false
    catch _:_ -> false end.
safe(Fun) -> try Fun() of M when is_map(M) -> M; _ -> #{} catch _:_ -> #{} end.
module_md5(M) -> _ = code:ensure_loaded(M), try M:module_info(md5) catch _:_ -> <<>> end.
pid_bin(undefined) -> <<>>;
pid_bin(Pid) -> list_to_binary(pid_to_list(Pid)).
field(K, M, Default) when is_map(M) -> maps:get(K, M, maps:get(atom_to_binary(K, utf8), M, Default));
field(_, _, Default) -> Default.
empty_error(<<>>) -> true;
empty_error(null) -> true;
empty_error(undefined) -> true;
empty_error(_) -> false.
bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> unicode:characters_to_binary(V);
bin(_) -> <<>>.
sha(B) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(crypto:hash(sha256, B))))).
public_error(R) when is_atom(R) -> R;
public_error({R, _}) when is_atom(R) -> R;
public_error(_) -> check_failed.


rejected_unlock(C, Wrong) ->
    {ok, Port} = damage_nsecbunker_port:open(C),
    try
        case damage_nsecbunker_port:unlock(Port, Wrong, 15000) of
            {error, {vault_unlock_failed, _}} -> ok;
            _ -> error(wrong_unlock_was_not_rejected)
        end
    after damage_nsecbunker_port:close(Port) end.
