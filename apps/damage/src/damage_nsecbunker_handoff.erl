%% The controller lives outside the bunker subtree so restart checks survive.
%% One bounded worker at a time; viewing status never signs or restarts anything.
-module(damage_nsecbunker_handoff).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start_link/0, child_spec/0, start/1, status/0, accept/3,
    closure/4, closure_tasks/4, fresh/3, validate_attestation/1, canonical/1, verify_export/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(DEADLINE, 1200000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
child_spec() -> #{id => ?MODULE, start => {?MODULE, start_link, []},
    restart => permanent, shutdown => 5000, type => worker, modules => [?MODULE]}.
start(Action) -> gen_server:call(?MODULE, {start, Action}, 5000).
status() -> gen_server:call(?MODULE, status, 5000).
accept(Hash, Attestation, Actor) ->
    %% Re-observe immediately before acceptance. This never grants IAM authority.
    try
        S = damage_nsecbunker_handoff_checks:snapshot(),
        case passed(damage_nsecbunker_handoff_checks:assess(S)) of
            true -> gen_server:call(?MODULE, {accept, Hash, Attestation, Actor,
                damage_nsecbunker_handoff_checks:fingerprint(S)}, 5000);
            false -> {error, current_technical_evidence_required}
        end
    catch _:_ -> {error, current_technical_evidence_required} end.

init([]) ->
    process_flag(trap_exit,true),
    Saved = read_saved(),
    self() ! refresh_health,
    {ok, #{busy => false, evidence => (maps:get(evidence, Saved, #{}))#{health => #{}},
        acceptance => maps:get(acceptance, Saved, undefined)}}.

handle_call(status, _From, State) ->
    Evidence = maps:get(evidence, State),
    %% Snapshot collected by a health/verification worker, never an unbounded
    %% call to the signing process in a GET handler.
    Health = maps:get(health, Evidence, #{}),
    Current = maps:get(fingerprint, Health, <<>>),
    Now = erlang:system_time(second),
    Reply = #{busy => maps:get(busy, State), health => Health,
        evidence => Evidence, acceptance => nullable(maps:get(acceptance, State)),
        handover_status => case maps:get(acceptance,State) of
            #{report_sha256 := _} -> accepted;
            _ -> not_accepted
        end,
        closure => case maps:get(last_error,State,undefined) of
            undefined -> closure(Evidence, maps:get(acceptance, State), Current, Now);
            _ -> outstanding
        end,
        closure_tasks => closure_tasks(Evidence, maps:get(acceptance, State), Current, Now),
        last_error => nullable(maps:get(last_error, State, undefined)),
        health_stale => not fresh(Health, Now, 60)},
    {reply, Reply, State};
handle_call({start, _}, _From, State = #{busy := true}) ->
    {reply, {error, verification_in_progress}, State};
handle_call({start, Action}, _From, State) ->
    case lists:member(Action, [health, verify, restart, recovery, pending]) of
        false -> {reply, {error, unknown_action}, State};
        true ->
            Parent = self(), Token = make_ref(),
            {Pid, Monitor} = spawn_opt(fun() ->
                Result = run(Action),
                Parent ! {completed, Token, Result}
            end, [link,monitor]),
            Timer = erlang:send_after(?DEADLINE, self(), {deadline, Token}),
            {reply, {ok, #{action => Action, status => running}}, State#{busy => true,
                job => #{pid => Pid, monitor => Monitor, timer => Timer,
                    token => Token, action => Action}}}
    end;
handle_call({accept, Hash, Attestation, Actor, CurrentFingerprint}, _From, State = #{busy := false}) ->
    E = maps:get(evidence, State),
    %% Re-observe the current process/configuration before accepting an export.
    %% No permission is inferred from this identity; HTTP separately enforces admin auth.
    Parent = self(),
    case validate_attestation(Attestation) of
        {ok, Clean} ->
            V = maps:get(verify, E, #{}), H = maps:get(health, E, #{}),
            case Hash =:= maps:get(sha256, V, undefined) andalso
                maps:get(fingerprint, H, <<>>) =:= CurrentFingerprint andalso
                closure(E, undefined, CurrentFingerprint, erlang:system_time(second)) =:= awaiting_acceptance of
                true ->
                    A = #{report_sha256 => Hash, actor => Actor,
                        accepted_at => erlang:system_time(second), declarations => Clean,
                        assurance => operator_attested},
                    New = State#{acceptance => A},
                    case persist(New) of
                        ok -> Parent ! refresh_health, {reply, {ok, A}, New};
                        _ -> {reply, {error, evidence_write_failed}, State}
                    end;
                false -> {reply, {error, current_technical_evidence_required}, State}
            end;
        Error -> {reply, Error, State}
    end;
handle_call({accept, _, _, _, _}, _From, State) ->
    {reply, {error, verification_in_progress}, State};
handle_call(_, _From, State) -> {reply, {error, unknown_request}, State}.
handle_cast(_, State) -> {noreply, State}.

handle_info(refresh_health, State = #{busy := false}) ->
    %% Reuse the same serialized worker path after an acceptance operation.
    case handle_call({start, health}, undefined, State) of
        {reply, _, New} -> {noreply, New}
    end;
handle_info({completed, Token, Report}, State = #{job := #{token := Token} = Job}) ->
    erlang:cancel_timer(maps:get(timer, Job)), erlang:demonitor(maps:get(monitor, Job), [flush]),
    E0 = maps:get(evidence, State), Action = maps:get(action, Job),
    E1 = E0#{Action => Report, health => health_from(Report)},
    E = case Action of restart -> E1#{verify => Report}; _ -> E1 end,
    New = maps:remove(last_error,maps:remove(job, State#{busy => false, evidence => E})),
    case persist(New) of
        ok -> {noreply, New};
        _ ->
            Failed = #{status => failed, reason => evidence_write_failed,
                completed_at => erlang:system_time(second)},
            {noreply, maps:remove(job, State#{busy => false,
                evidence => E0#{Action => Failed}, last_error => evidence_write_failed})}
    end;
handle_info({deadline, Token}, State = #{job := #{token := Token} = Job}) ->
    exit(maps:get(pid, Job), kill),
    {noreply, finish_failure(State, deadline_exceeded)};
handle_info({'DOWN', Monitor, process, _, _}, State = #{job := #{monitor := Monitor}}) ->
    {noreply, finish_failure(State, verification_worker_failed)};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{job := #{pid := Pid}}) -> exit(Pid, kill), ok;
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

run(Action) ->
    Started = erlang:system_time(second),
    try
        Before = damage_nsecbunker_handoff_checks:snapshot(),
        Checks = damage_nsecbunker_handoff_checks:assess(Before),
        Result = case {Action, passed(Checks)} of
            {health, _} -> #{};
            {_, false} -> #{operation_status => failed, reason => prerequisites_failed};
            {verify, true} -> #{exchanges => steps_nsecbunker_live:handoff_probe(),
                policy_checks => policy_rehearsal()};
            {restart, true} ->
                Old = maps:get(runtime_instance, Before),
                {ok, _} = damage_nsecbunker_ops:restart(),
                wait_ready(erlang:monotonic_time(millisecond) + 90000),
                AfterRestart = damage_nsecbunker_handoff_checks:snapshot(),
                true = maps:get(runtime_instance, AfterRestart) =/= Old,
                #{restarted => true, verification_baseline => damage_nsecbunker_handoff_checks:fingerprint(AfterRestart),
                    exchanges => steps_nsecbunker_live:handoff_probe(),
                    policy_checks => policy_rehearsal()};
            {recovery, true} -> #{recovery => damage_nsecbunker_handoff_checks:recovery(current)};
            {pending, true} -> #{recovery => damage_nsecbunker_handoff_checks:recovery(pending)}
        end,
        After = damage_nsecbunker_handoff_checks:snapshot(),
        FinalChecks = damage_nsecbunker_handoff_checks:assess(After),
        Baseline = case Action of
            restart -> maps:get(verification_baseline,Result,undefined);
            _ -> damage_nsecbunker_handoff_checks:fingerprint(Before)
        end,
        Stable = Baseline =:= damage_nsecbunker_handoff_checks:fingerprint(After),
        PendingDistinct = case Action of
            pending -> PM=maps:get(secret_provenance,maps:get(recovery,Result,#{}),#{}),
                maps:get(version_id,PM,undefined)=/=maps:get(baseline_version_id,PM,undefined);
            _ -> true
        end,
        Success = PendingDistinct andalso Stable andalso passed(FinalChecks) andalso
            maps:get(operation_status, Result, passed) =/= failed andalso
            passed(maps:get(exchanges, Result, [])) andalso
            passed(maps:get(policy_checks, Result, [])) andalso
            case lists:member(Action,[verify,restart]) of
                true -> length(maps:get(exchanges,Result,[])) =:= 5 * length(maps:get(relays,maps:get(config,After),[]))
                    andalso maps:get(exchanges,Result,[]) =/= [];
                false -> true
            end,
        C = maps:get(config, After), P = damage_nsecbunker:policy(C),
        Report = Result#{schema_version => 1, action => Action, started_at => Started,
            completed_at => erlang:system_time(second), status => outcome(Success),
            fingerprint => damage_nsecbunker_handoff_checks:fingerprint(After),
            target => damage_nsecbunker_handoff_checks:target(After),
            runtime_instance => maps:get(runtime_instance, After),
            active_secret_version => maps:get(provenance_revision, After, undefined),
            checks => FinalChecks, configuration_changed => not Stable,
            setup => #{signing_public_key => maps:get(bunker_pubkey_hex, P, <<>>),
                clients => maps:get(authorized_clients, P, []),
                methods => maps:get(allowed_methods, P, []), kinds => maps:get(allowed_kinds, P, []),
                aws => maps:with([region, secret_id, expected_account_id, expected_role_name],
                    damage_nsecbunker_config:aws_secret(C)),
                relays => [public_relay(U) || U <- maps:get(relays, C, [])]}},
        hash_report(Report)
    catch _:Why -> hash_report(#{schema_version => 1, action => Action,
        started_at => Started, completed_at => erlang:system_time(second), status => failed,
        reason => damage_nsecbunker_handoff_checks:public_error(Why)}) end.

wait_ready(Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        false -> error(restart_readiness_timeout);
        true ->
            Ready = try gen_server:call(damage_nsecbunker, handoff_status, 2000)
                catch _:_ -> not_ready end,
            case Ready of
                #{ready := true} -> ok;
                _ -> receive after 250 -> wait_ready(Deadline) end
            end
    end.

%% Technical evidence and operator declarations remain separate in the UI.
%% This is an acceptance record, not an independent claim that IAM was audited.
closure(E, Acceptance, Fingerprint, Now) ->
    case passed(technical_tasks(E,Fingerprint,Now)) of
        false -> outstanding;
        true -> case Acceptance of
            #{report_sha256 := Hash} -> case Hash =:= maps:get(sha256,maps:get(verify,E,#{}),undefined) of
                true -> accepted;
                false -> awaiting_acceptance
            end;
            _ -> awaiting_acceptance
        end
    end.

closure_tasks(E,A,F,Now) ->
    Tasks = technical_tasks(E,F,Now),
    Attested = case A of
        #{report_sha256 := Hash} -> Hash =:= maps:get(sha256,maps:get(verify,E,#{}),undefined);
        _ -> false
    end,
    Tasks ++ [#{id=>operator_acceptance,status=>case Attested of true->operator_attested;false->not_checked end,
        next_action=><<"Record IAM, administrator-removal, external-client and recovery-custodian references against the current report.">>}].

technical_tasks(E,Fingerprint,Now) ->
    H=maps:get(health,E,#{}), V=maps:get(verify,E,#{}), R=maps:get(restart,E,#{}),
    Recovery=maps:get(recovery,E,#{}), Pending=maps:get(pending,E,#{}),
    SameTarget=fun(X)->maps:get(target,X,undefined)=:=maps:get(target,V,missing) end,
    RecoveryData=maps:get(recovery,Recovery,#{}),
    [damage_nsecbunker_handoff_checks:check(current_controls,
        fresh(H,Now,60) andalso good(H), <<"Run Check health; resolve every required control.">>),
     damage_nsecbunker_handoff_checks:check(live_signing,
        good(V) andalso fresh(V,Now,900) andalso maps:get(fingerprint,V,undefined)=:=Fingerprint
            andalso maps:get(exchanges,V,[])=/=[] andalso passed(maps:get(exchanges,V,[]))
            andalso length(maps:get(policy_checks,V,[]))=:=2 andalso passed(maps:get(policy_checks,V,[])),
        <<"Run Verify signing against the current deployment and all configured relays.">>),
     damage_nsecbunker_handoff_checks:check(cold_restart,
        good(R) andalso SameTarget(R) andalso fresh(R,Now,86400)
            andalso maps:get(runtime_instance,R,undefined)=:=maps:get(runtime_instance,V,missing)
            andalso maps:get(active_secret_version,R,undefined)=:=maps:get(active_secret_version,V,missing),
        <<"Run Restart & verify after promotion; the current process must have bootstrapped with the tested version.">>),
     damage_nsecbunker_handoff_checks:check(backup_restore,
        good(Recovery) andalso SameTarget(Recovery) andalso fresh(Recovery,Now,86400)
            andalso maps:get(backup_restored,RecoveryData,false)=:=true
            andalso maps:get(restored,maps:get(metadata_restore,RecoveryData,#{}),false)=:=true
            andalso maps:get(wrong_unlock_rejected,RecoveryData,false)=:=true,
        <<"Run Verify current version & restore to check the encrypted vault and opaque DETS snapshot.">>),
     damage_nsecbunker_handoff_checks:check(version_promotion,
        good(Pending) andalso SameTarget(Pending) andalso fresh(Pending,Now,86400)
            andalso rotation_complete(Pending,Recovery)
            andalso maps:get(active_secret_version,V,undefined)=:=maps:get(version_id,
                maps:get(secret_provenance,RecoveryData,#{}),missing),
        <<"Prepare a distinct AWSPENDING version, check it, promote that exact version, verify restore, then restart and verify.">>)].

rotation_complete(Pending, Recovery) ->
    PM = maps:get(secret_provenance, maps:get(recovery, Pending, #{}), #{}),
    RM = maps:get(secret_provenance, maps:get(recovery, Recovery, #{}), #{}),
    Version = maps:get(version_id, PM, undefined), Baseline = maps:get(baseline_version_id, PM, undefined),
    is_binary(Version) andalso is_binary(Baseline) andalso Version =/= Baseline andalso
        maps:get(version_id, RM, missing) =:= Version andalso
        maps:get(completed_at, Pending, 0) =< maps:get(started_at, Recovery, -1).

fresh(R, Now, TTL) ->
    At = maps:get(completed_at, R, 0), is_integer(At) andalso At > 0 andalso
        Now >= At andalso Now - At =< TTL.
good(R) -> maps:get(status, R, failed) =:= passed.
passed(Checks) -> lists:all(fun good/1, Checks).
outcome(true) -> passed;
outcome(false) -> failed.
health_from(R) ->
    Base = maps:with([schema_version, started_at, completed_at,
        fingerprint, target, runtime_instance, checks, setup, reason], R),
    Status = case maps:find(checks, R) of
        {ok, Checks} -> outcome(passed(Checks));
        error -> failed
    end,
    hash_report(Base#{status => Status}).
hash_report(R) -> R#{sha256 => lower_hex(crypto:hash(sha256, canonical(R)))}.
lower_hex(B) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(B)))).
nullable(undefined) -> null;
nullable(V) -> V.

validate_attestation(A) when is_map(A), map_size(A) =:= 4 ->
    Keys = [<<"iam_reviewed">>, <<"temporary_admin_removed">>,
        <<"external_client_accepted">>, <<"recovery_custodian_confirmed">>],
    case lists:sort(maps:keys(A)) =:= lists:sort(Keys) andalso
        lists:all(fun(K) -> safe_reference(maps:get(K, A, undefined)) end, Keys) of
        true -> {ok, A};
        false -> {error, four_evidence_references_required}
    end;
validate_attestation(_) -> {error, four_evidence_references_required}.
safe_reference(B) when is_binary(B), byte_size(B) >= 8, byte_size(B) =< 256 ->
    re:run(B, <<"^[A-Za-z0-9 ._:/#@-]+$">>, [{capture, none}]) =:= match andalso
        binary:match(string:lowercase(B), <<"nsec1">>) =:= nomatch andalso
        binary:match(B, <<"AKIA">>) =:= nomatch;
safe_reference(_) -> false.

finish_failure(State = #{job := Job}, Why) ->
    erlang:cancel_timer(maps:get(timer, Job)), erlang:demonitor(maps:get(monitor, Job), [flush]),
    E = maps:get(evidence, State), Action = maps:get(action, Job),
    Failed = hash_report(#{action => Action, status => failed, reason => Why,
        completed_at => erlang:system_time(second)}),
    New = maps:remove(job, State#{busy => false, evidence => E#{Action => Failed}}),
    _ = persist(New), New.

path() -> filename:join([damage_nsecbunker_config:state_dir(), "handoff", "evidence.term"]).
persist(State) ->
    %% Store only constructed public evidence. No application configuration,
    %% process state, passphrase, client private key or pending connection URI.
    Path = path(), Dir = filename:dirname(Path),
    try
        ok = filelib:ensure_dir(Path), ok = file:change_mode(Dir, 8#700),
        {ok, #file_info{type = directory}} = file:read_link_info(Dir),
        Tmp = Path ++ "." ++ integer_to_list(erlang:unique_integer([positive])),
        {ok, Fd} = file:open(Tmp, [write, binary, exclusive]),
        try
            ok = file:change_mode(Tmp, 8#600),
            ok = file:write(Fd, term_to_binary(maps:with([evidence, acceptance], State), [compressed])),
            ok = file:sync(Fd)
        after file:close(Fd) end,
        lists:foreach(fun archive_report/1, maps:values(maps:get(evidence, State, #{}))),
        ok = file:rename(Tmp, Path), ok
    catch _:_ -> {error, evidence_write_failed} end.
read_saved() ->
    %% Populate only known evidence-schema atoms before safe ETF decoding.
    %% A fresh VM may not yet have loaded the diagnostic/recovery modules.
    [code:ensure_loaded(M) || M <- [damage_nsecbunker_handoff_checks,
        damage_nsecbunker_handoff_recovery, steps_nsecbunker_live,
        damage_aws_secret_provider, damage_nsecbunker_port, damage_nostr_event]],
    try file:read_file(path()) of
        {ok, B} when byte_size(B) =< 16777216 -> case binary_to_term(B, [safe]) of
            M when is_map(M) -> M; _ -> #{} end;
        _ -> #{}
    catch _:_ -> #{} end.


%% Canonical JSON for report hashes, identical before and after JSON decoding.
canonical(M) when is_map(M) ->
    Pairs = lists:keysort(1, [{json_key(K), V} || {K, V} <- maps:to_list(M)]),
    iolist_to_binary([<<"{">>, lists:join(<<",">>,
        [[jsx:encode(K), <<":">>, canonical(V)] || {K, V} <- Pairs]), <<"}">>]);
canonical(L) when is_list(L) ->
    iolist_to_binary([<<"[">>, lists:join(<<",">>, [canonical(V) || V <- L]), <<"]">>]);
canonical(V) -> iolist_to_binary(jsx:encode(V)).
json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8).

archive_report(#{sha256 := Hash} = R) ->
    File = filename:join(filename:dirname(path()), binary_to_list(Hash) ++ ".json"),
    Bytes = canonical(R),
    case file:open(File, [write, binary, exclusive]) of
        {ok, Fd} ->
            try ok = file:change_mode(File, 8#600), ok = file:write(Fd, Bytes),
                ok = file:sync(Fd)
            after file:close(Fd) end;
        {error, eexist} -> {ok, Bytes} = file:read_file(File), ok;
        _ -> error(evidence_write_failed)
    end;
archive_report(_) -> ok.

%% Offline cryptographic/integrity verification only; it does not establish
%% current host/IAM state or turn operator attestations into independent facts.
verify_export(Path) ->
    try
        {ok, Bytes} = file:read_file(Path), true = byte_size(Bytes) =< 16777216,
        Bundle = jsx:decode(Bytes, [return_maps]),
        Reports = maps:values(maps:get(<<"evidence">>, Bundle)),
        lists:foreach(fun(R) ->
            Hash = maps:get(<<"sha256">>, R),
            true = Hash =:= lower_hex(crypto:hash(sha256, canonical(maps:remove(<<"sha256">>, R)))),
            lists:foreach(fun(X) ->
                case maps:get(<<"status">>, X) of
                    <<"passed">> ->
                        P = maps:get(<<"proof">>, X),
                        {ok, Req} = damage_nostr_event:verify(maps:get(<<"request_event">>, P)),
                        {ok, Res} = damage_nostr_event:verify(maps:get(<<"response_event">>, P)),
                        A = maps:get(<<"audit">>, X),
                        {ok, _} = damage_nsecbunker_handoff_checks:correlate(maps:values(A),
                            maps:get(<<"request_id">>, P), maps:get(id, Req), maps:get(id, Res)),
                        case maps:find(<<"signed_event">>, P) of
                            {ok, Event} -> {ok, _} = damage_nostr_event:verify(Event);
                            error -> ok
                        end;
                    _ -> ok
                end
            end, maps:get(<<"exchanges">>, R, [])),
            case maps:find(<<"recovery">>, R) of
                {ok, #{<<"signed_event">> := E}} -> {ok, _} = damage_nostr_event:verify(E);
                _ -> ok
            end
        end, Reports),
        {ok, #{reports_checked => length(Reports), verification => hashes_and_public_signatures,
            live_host_state => not_checked, operator_declarations => not_independently_verified}}
    catch _:_ -> {error, invalid_handoff_evidence} end.

public_relay(#{url := U}) -> public_relay(U);
public_relay(U) ->
    try uri_string:parse(unicode:characters_to_binary(U)) of
        #{host := H, scheme := S} = P -> uri_string:recompose(maps:with([host, scheme, port], P#{host => H, scheme => S}));
        _ -> <<"invalid_relay">>
    catch _:_ -> <<"invalid_relay">> end.


policy_rehearsal() ->
    Policy = damage_nsecbunker:policy(),
    Client = damage_nostr:public_key_hex(),
    Unknown = lower_hex(crypto:hash(sha256,crypto:strong_rand_bytes(32))),
    false = lists:member(Unknown, maps:get(authorized_clients,Policy)),
    Request = #{requester_pubkey => Unknown, request_id => <<"handoff-denial-",Unknown/binary>>,
        method => <<"ping">>, created_at => erlang:system_time(second)},
    {ok, Response} = damage_nsecbunker:handle_plain_request(Request),
    true = maps:get(error, Response, undefined) =:= <<"client_not_authorized">>,
    Removed = Policy#{authorized_clients => lists:delete(Client,maps:get(authorized_clients,Policy))},
    {error,client_not_authorized} = damage_nsecbunker_policy:authorize(
        Request#{requester_pubkey => Client}, Removed, erlang:system_time(second),
        maps:get(bunker_pubkey_hex,Policy)),
    [#{id => unauthorised_client_rejected,status => passed,
        next_action => <<"Running server rejected a non-allowlisted diagnostic request.">>},
     #{id => revocation_policy_rehearsal,status => passed,
        next_action => <<"Policy evaluation rejects the diagnostic client after removal; the production allowlist was not changed.">>}].
