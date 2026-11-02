-module(damage_nsecbunker_handoff_tests).
-include_lib("eunit/include/eunit.hrl").

healthy_snapshot_test() -> ?assert(lists:all(fun(C) -> maps:get(status,C) =:= passed end,
    damage_nsecbunker_handoff_checks:assess(snapshot()))).

fail_closed_controls_test_() ->
    S = snapshot(), C = maps:get(config,S), O = maps:get(owner,S), P = maps:get(secret_provenance,O),
    Cases = [
        {local_secret_absent, S#{local_secret => unknown}},
        {local_secret_absent, S#{local_secret => present}},
        {aws_only, S#{config => C#{secret_provider => local}}},
        {aws_only, S#{config => C#{vault_mode => create_if_missing}}},
        {aws_provenance, S#{owner => O#{secret_provenance => P#{account_id => <<"wrong">>}}}},
        {aws_provenance, S#{owner => O#{secret_provenance => P#{credential_provider => aws_credentials_env}}}},
        {aws_provenance, S#{owner => O#{secret_provenance => P#{version_stages => [<<"AWSPENDING">>]}}}},
        {identity_pinned, S#{bunker => #{ready => true}}},
        {narrow_policy, S#{config => C#{allowed_methods => [<<"nip04_decrypt">>]}}},
        {narrow_policy, S#{config => C#{bunker_publishes => true}}},
        {runtime_policy_matches,S#{runtime_policy=>#{policy_fingerprint=><<"old-policy">>}}},
        {client_allowlist, S#{config => C#{authorized_clients => []}}},
        {relays_subscribed, S#{config => C#{relays => [<<"ws://relay.example">>]}}},
        {relays_subscribed, S#{config => C#{relays => [<<"wss://user:pass@relay.example">>]}}},
        {backend_artifact, S#{backend_artifact=>#{type=>regular,mode=>8#777,sha256=>binary:copy(<<"c">>,64)}}},
        {vault_permissions, S#{vault_file => #{type => symlink, mode => 8#600}}},
        {audit_permissions, S#{audit_file => #{type => regular, mode => 8#644}}}],
    [?_assertEqual(failed, status(Id, Changed)) || {Id,Changed} <- Cases].

fingerprint_invalidation_test_() ->
    S = snapshot(), F = damage_nsecbunker_handoff_checks:fingerprint(S),
    [?_assertNotEqual(F, damage_nsecbunker_handoff_checks:fingerprint(S#{K => V})) ||
        {K,V} <- [{runtime_instance, <<"replacement">>}, {code_revision, [new]},
            {config, #{}}, {vault_file, #{sha256 => <<"changed">>}}, {provenance_revision, <<"new-version">>}]].

closure_requires_all_evidence_test() ->
    E = evidence(), Now = 1000,
    ?assertEqual(awaiting_acceptance, damage_nsecbunker_handoff:closure(E, undefined, <<"f">>, Now)),
    A = #{report_sha256 => <<"hash">>},
    ?assertEqual(accepted, damage_nsecbunker_handoff:closure(E, A, <<"f">>, Now)),
    lists:foreach(fun(K) -> ?assertEqual(outstanding,
        damage_nsecbunker_handoff:closure(maps:remove(K,E), A, <<"f">>, Now)) end,
        [health,verify,restart,recovery,pending]),
    ?assertEqual(outstanding, damage_nsecbunker_handoff:closure(E,A,<<"different">>,Now)),
    ?assertEqual(outstanding, damage_nsecbunker_handoff:closure(E,A,<<"f">>,Now+61)),
    ?assertEqual(awaiting_acceptance, damage_nsecbunker_handoff:closure(E,
        #{report_sha256 => <<"other">>}, <<"f">>,Now)).

rotation_cannot_be_inferred_from_two_passing_runs_test() ->
    E = evidence(), R = maps:get(recovery,E), P = maps:get(pending,E),
    SameVersion = P#{recovery => #{secret_provenance => #{version_id => <<"new">>, baseline_version_id => <<"new">>}}},
    NoPromotion = R#{recovery => #{secret_provenance => #{version_id => <<"old">>}}},
    lists:foreach(fun(Changed) -> ?assertEqual(outstanding,
        damage_nsecbunker_handoff:closure(Changed,undefined,<<"f">>,1000)) end,
        [E#{pending => SameVersion},E#{recovery => NoPromotion},
         E#{verify => (maps:get(verify,E))#{active_secret_version => <<"old">>}},
         E#{restart => (maps:get(restart,E))#{runtime_instance => <<"previous-process">>}}]).

canonical_json_roundtrip_test() ->
    M = #{status => passed, nested => #{b => 2, a => true}, list => [1,<<"x">>]},
    Bytes = damage_nsecbunker_handoff:canonical(M),
    ?assertEqual(Bytes, damage_nsecbunker_handoff:canonical(jsx:decode(Bytes,[return_maps]))).

future_timestamp_is_not_fresh_test() ->
    ?assertNot(damage_nsecbunker_handoff:fresh(#{completed_at=>1001},1000,60)),
    ?assertNot(damage_nsecbunker_handoff:fresh(#{},1000,60)).

acceptance_requires_exact_evidence_references_test() ->
    A = references(),
    ?assertMatch({ok,_},damage_nsecbunker_handoff:validate_attestation(A)),
    ?assertMatch({error,_},damage_nsecbunker_handoff:validate_attestation(A#{<<"nsec">> => <<"secret">>})),
    ?assertMatch({error,_},damage_nsecbunker_handoff:validate_attestation(A#{<<"iam_reviewed">> => true})),
    ?assertMatch({error,_},damage_nsecbunker_handoff:validate_attestation(A#{<<"iam_reviewed">> => <<"nsec1secret">>})).

admin_boundary_test() ->
    Good = #{authenticated=>true,node_admin=>true,public_key=><<"ak_operator">>},
    ?assert(damage_nsecbunker_handoff_http:authorized_context(Good)),
    ?assertNot(damage_nsecbunker_handoff_http:authorized_context(Good#{auth_mode=>wallet})),
    ?assertNot(damage_nsecbunker_handoff_http:authorized_context(Good#{node_admin=>false})),
    ?assertNot(damage_nsecbunker_handoff_http:authorized_context(Good#{authenticated=>false})),
    ?assertEqual(error,damage_nsecbunker_handoff_http:decode_action(<<"use_local">>)),
    ?assertEqual(error,damage_nsecbunker_handoff_http:decode_action(<<"generate_identity">>)).

origin_boundary_test_() ->
    Base = <<"https://lightning.lodgeit.org">>,
    [?_assert(damage_nsecbunker_handoff_http:same_origin(Base,<<"https://lightning.lodgeit.org:443">>)),
     ?_assertNot(damage_nsecbunker_handoff_http:same_origin(Base,<<"http://lightning.lodgeit.org">>)),
     ?_assertNot(damage_nsecbunker_handoff_http:same_origin(Base,<<"https://lightning.lodgeit.org:444">>)),
     ?_assertNot(damage_nsecbunker_handoff_http:same_origin(Base,<<"https://evil.example">>)),
     ?_assertNot(damage_nsecbunker_handoff_http:same_origin(<<"null">>,Base)),
     ?_assertNot(damage_nsecbunker_handoff_http:same_origin(<<"https://user@lightning.lodgeit.org">>,Base))].

audit_completion_is_whitelisted_test() ->
    M = #{ts_unix=>10,request_id=><<"id",1>>,request_event_id=><<"request">>,response_event_id=><<"reply">>,
        passphrase=><<"MUST_NOT_APPEAR">>,ciphertext=><<"ALSO_NOT_INCLUDED">>},
    Row = jsx:decode(damage_nsecbunker_audit:transport_line(M),[return_maps]),
    ?assertEqual(<<"id",1>>,maps:get(<<"request_id">>,Row)),
    ?assertNot(maps:is_key(<<"passphrase">>,Row)),
    ?assertNot(maps:is_key(<<"ciphertext">>,Row)).

audit_correlation_requires_all_ids_test() ->
    D = #{schema_version=>1,request_id=><<"id">>,requester_pubkey=><<"client">>,method=><<"sign_event">>,
        decision=><<"allowed">>,bunker_pubkey=><<"bunker">>},
    T = D#{schema_version=>2,phase=><<"response_signed">>,request_event_id=><<"request">>,response_event_id=><<"reply">>},
    ?assertMatch({ok,_},damage_nsecbunker_handoff_checks:correlate([D,T],<<"id">>,<<"request">>,<<"reply">>)),
    ?assertMatch({error,_},damage_nsecbunker_handoff_checks:correlate([D,T],<<"id">>,<<"wrong">>,<<"reply">>)),
    ?assertMatch({error,_},damage_nsecbunker_handoff_checks:correlate([D,T#{decision=><<"rejected">>}],<<"id">>,<<"request">>,<<"reply">>)).

unsigned_exchange_is_not_a_proof_test() ->
    ?assertEqual({error,exchange_verification_failed},
        damage_nsecbunker_handoff_checks:verify_exchange(#{},#{},#{},#{},#{})).

status(Id,S) -> [C] = [R || R <- damage_nsecbunker_handoff_checks:assess(S),maps:get(id,R)=:=Id], maps:get(status,C).
references() -> maps:from_list([{K,<<"audit-ticket-2026-001">>} || K <-
    [<<"iam_reviewed">>,<<"temporary_admin_removed">>,<<"external_client_accepted">>,<<"recovery_custodian_confirmed">>]]).
evidence() ->
    Base = #{status=>passed,started_at=>900,completed_at=>950,fingerprint=><<"f">>,target=><<"t">>,runtime_instance=><<"pid">>,active_secret_version=><<"new">>},
    #{health=>Base,verify=>Base#{sha256=><<"hash">>,active_secret_version=><<"new">>,exchanges=>[#{status=>passed}],policy_checks=>[#{status=>passed},#{status=>passed}]}, restart=>Base,
        pending=>Base#{completed_at=>920,recovery=>#{secret_provenance=>#{version_id=><<"new">>,baseline_version_id=><<"old">>}}},
        recovery=>Base#{started_at=>930,recovery=>#{backup_restored=>true,wrong_unlock_rejected=>true,
            metadata_restore=>#{restored=>true},secret_provenance=>#{version_id=><<"new">>}}}}.
snapshot() ->
    Pub = binary:copy(<<"a">>,64), Client = binary:copy(<<"b">>,64),
    Arn = <<"arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:bunker-ABC123">>,
    Hash = list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(crypto:hash(sha256,Arn))))),
    S=#{config=>#{enabled=>true,mode=>production,secret_provider=>aws_secrets_manager,
        vault_mode=>open_existing,crypto_backend_cmd=>"/opt/damage/bin/crypto",vault_path=>"/tmp/vault",
        bunker_pubkey_hex=>Pub,authorized_clients=>[Client],relays=>[<<"wss://relay.example">>],
        aws_secret=>#{region=><<"ap-southeast-2">>,secret_id=>Arn,expected_account_id=><<"123456789012">>,expected_role_name=><<"bunker-role">>}},
      bunker=>#{ready=>true,vault=>#{guard_state=>#{sealed=>false,pubkey_hex=>Pub}}},
      owner=>#{ready=>true,secret_provenance=>#{credential_provider=>aws_credentials_ec2,imds_protocol=>imdsv2,
          account_id=><<"123456789012">>,role_name=><<"bunker-role">>,secret_id_sha256=>Hash,version_stages=>[<<"AWSCURRENT">>]}},
      relay=>#{subscribed=>true},local_secret=>absent,runtime_instance=><<"pid">>,code_revision=>[],
      backend_artifact=>#{type=>regular,mode=>8#755,size=>10,sha256=>binary:copy(<<"c">>,64)},
      vault_file=>#{type=>regular,mode=>8#600,size=>10},audit_file=>#{type=>regular,mode=>8#600}},
    Policy=damage_nsecbunker:policy(maps:get(config,S)),
    S#{runtime_policy=>#{secret_provider=>aws_secrets_manager,policy_fingerprint=>lower_hex(crypto:hash(sha256,term_to_binary(Policy,[deterministic])))}}.

signed_exchange_integrity_test_() ->
    {timeout, 60, fun() ->
        ClientKey = <<1:256>>, BunkerKey = <<2:256>>,
        {ok,ClientRaw} = nostrlib_schnorr:new_publickey(ClientKey),
        {ok,BunkerRaw} = nostrlib_schnorr:new_publickey(BunkerKey),
        Client = lower_hex(ClientRaw), Bunker = lower_hex(BunkerRaw),
        Unsigned = #{kind=>30023,created_at=>1000,tags=>[[<<"d">>,<<"diagnostic">>]],content=><<"handoff-run-123">>},
        Signed = sign(Unsigned,BunkerKey),
        Req = sign(#{kind=>24133,created_at=>1000,tags=>[[<<"p">>,Bunker]],content=><<"encrypted-request">>},ClientKey),
        Reply = sign(#{kind=>24133,created_at=>1001,tags=>[[<<"p">>,Client]],content=><<"encrypted-reply">>},BunkerKey),
        Response = #{id=><<"correlation-id">>,error=><<>>,result=>Signed},
        Expected = #{client=>Client,bunker=>Bunker,request_id=><<"correlation-id">>,outcome=>signed_event},
        Verify = fun(R,Q,U,E) -> damage_nsecbunker_handoff_checks:verify_exchange(Req,R,Q,U,E) end,
        ?assertMatch({ok,_},Verify(Reply,Response,Unsigned,Expected)),
        Changed = sign(Unsigned#{content=><<"different but validly signed">>},BunkerKey),
        ?assertMatch({error,_},Verify(Reply,Response#{result=>Changed},Unsigned,Expected)),
        WrongKey = sign(Unsigned,ClientKey),
        ?assertMatch({error,_},Verify(Reply,Response#{result=>WrongKey},Unsigned,Expected)),
        ?assertMatch({error,_},Verify(Reply#{sig=>binary:copy(<<"0">>,128)},Response,Unsigned,Expected)),
        ?assertMatch({error,_},Verify(Reply,Response#{id=><<"another-id">>},Unsigned,Expected)),
        BadRecipient = sign(#{kind=>24133,created_at=>1001,tags=>[],content=><<"encrypted-reply">>},BunkerKey),
        ?assertMatch({error,_},Verify(BadRecipient,Response,Unsigned,Expected)),
        ?assertMatch({error,_},Verify(Reply,Response,Unsigned#{created_at=>1002},Expected))
    end}.

sign(Event,Key) ->
    {ok,Pub} = nostrlib_schnorr:new_publickey(Key),
    E = damage_nostr_event:ensure_event_id(Event#{pubkey=>lower_hex(Pub)}),
    {ok,Sig} = nostrlib_schnorr:sign(binary:decode_hex(maps:get(id,E)),Key),
    E#{sig=>lower_hex(Sig)}.
lower_hex(B) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(B)))).

audit_failure_prevents_backend_signing_test() ->
    Parent = self(), Pub = binary:copy(<<"a">>,64), Client = binary:copy(<<"b">>,64),
    Owner = spawn_link(fun() -> fake_owner(Parent,Pub) end),
    true = register(damage_nsecbunker_secret_owner, Owner),
    C = #{crypto_backend_cmd=>"/unused",secret_provider=>aws_secrets_manager,
        bunker_pubkey_hex=>Pub,authorized_clients=>[Client],
        audit_log=>"/definitely/missing/handoff/audit.log"},
    P = damage_nsecbunker:policy(C), Vault = damage_nsecbunker_vault:init(C,P),
    S = {state,C,P,Vault,1000,true,1000,undefined},
    Request = #{requester_pubkey=>Client,request_id=><<"audit-failure">>,method=><<"sign_event">>,
        created_at=>erlang:system_time(second),event=>#{kind=>1,created_at=>erlang:system_time(second),tags=>[],content=><<"test">>}},
    try
        ?assertMatch({reply,{error,audit_unavailable},_},damage_nsecbunker:handle_call({plain_request,Request},{self(),make_ref()},S)),
        ?assertMatch({reply,{error,invalid_nip46_event_signature},_},
            damage_nsecbunker:handle_call({nip46_event,#{}},{self(),make_ref()},S)),
        receive backend_signing_attempted -> ?assert(false) after 0 -> ok end
    after
        unlink(Owner), exit(Owner,kill),
        lists:foreach(fun(M) -> case whereis(M) of undefined->ok;Pid->unlink(Pid),gen_server:stop(Pid) end end,
            [damage_nsecbunker_replay,damage_nsecbunker_rate])
    end.
fake_owner(Parent,Pub) ->
    receive
        {'$gen_call',From,ready} -> gen_server:reply(From,true),fake_owner(Parent,Pub);
        {'$gen_call',From,{operation,public_key,_,_}} -> gen_server:reply(From,{ok,#{<<"pubkey_hex">>=>Pub}}),fake_owner(Parent,Pub);
        {'$gen_call',From,{operation,sign_event,_,_}} -> Parent!backend_signing_attempted,gen_server:reply(From,{error,blocked}),fake_owner(Parent,Pub)
    end.

metadata_snapshot_restores_opaque_records_test() ->
    Dir = filename:join("/tmp","bunker-metadata-test-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),ok=file:change_mode(Dir,8#700),Source=filename:join(Dir,"source.dets"),
    {ok,bunker_metadata_fixture}=dets:open_file(bunker_metadata_fixture,[{file,Source}]),
    try
        ok=dets:insert(bunker_metadata_fixture,[{node_metadata,<<"opaque-encrypted-record">>}]),
        ok=dets:sync(bunker_metadata_fixture),
        R=damage_nsecbunker_handoff_recovery:restore_snapshot(Source,Dir),
        ?assertEqual(true,maps:get(restored,R)),?assertEqual(1,maps:get(record_count,R)),
        ?assertNot(maps:is_key(records,R)),
        ?assertEqual([{node_metadata,<<"opaque-encrypted-record">>}],dets:lookup(bunker_metadata_fixture,node_metadata))
    after dets:close(bunker_metadata_fixture),file:delete(Source),file:del_dir(Dir) end.

controller_records_failure_and_never_restores_cached_health_on_boot_test() ->
    Dir=filename:join("/tmp","bunker-controller-test-"++integer_to_list(erlang:unique_integer([positive]))),
    Old=application:get_env(damage,nsecbunker),
    application:set_env(damage,nsecbunker,#{enabled=>false,state_dir=>Dir}),
    try
        {ok,Pid}=damage_nsecbunker_handoff:start_link(),
        wait_controller(200),
        #{closure:=outstanding,evidence:=E}=damage_nsecbunker_handoff:status(),
        ?assertEqual(failed,maps:get(status,maps:get(health,E))),
        ?assertMatch({ok,_},damage_nsecbunker_handoff:start(verify)),
        wait_controller(200),
        #{evidence:=E2}=damage_nsecbunker_handoff:status(),
        ?assertEqual(failed,maps:get(status,maps:get(verify,E2))),
        File=filename:join(Dir,"bundle.json"),
        ok=file:write_file(File,jsx:encode(#{evidence=>E2})),
        ?assertMatch({ok,_},damage_nsecbunker_handoff:verify_export(File)),
        ?assertMatch({reply,{error,verification_in_progress},_},
            damage_nsecbunker_handoff:handle_call({start,verify},undefined,#{busy=>true})),
        gen_server:stop(Pid),
        {ok,Again}=damage_nsecbunker_handoff:start_link(),
        ?assertEqual(outstanding,maps:get(closure,damage_nsecbunker_handoff:status())),
        gen_server:stop(Again)
    after
        case whereis(damage_nsecbunker_handoff) of undefined->ok;P->gen_server:stop(P) end,
        case Old of {ok,V}->application:set_env(damage,nsecbunker,V);undefined->application:unset_env(damage,nsecbunker) end,
        file:del_dir_r(Dir)
    end.
wait_controller(0) -> error(controller_timeout);
wait_controller(N) -> case maps:get(busy,damage_nsecbunker_handoff:status()) of
    false -> ok;
    true -> receive after 10 -> wait_controller(N-1) end
end.

aws_bootstrap_and_maintenance_cannot_race_test() ->
    Parent=self(),
    Locker=spawn_link(fun()->
        Lock={damage_aws_runtime,self()},true=global:set_lock(Lock,[node()],0),
        Parent!aws_lock_ready,
        receive release->global:del_lock(Lock,[node()]) end
    end),
    receive aws_lock_ready->ok after 2000->error(lock_timeout) end,
    try ?assertEqual({error,aws_runtime_busy},damage_aws_runtime:with_runtime(#{},
        fun(_)->error(must_not_run) end))
    after Locker!release end.
