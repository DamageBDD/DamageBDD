%% Durable AWS setup coordinator. The DETS records and this manager NEVER hold
%% AWS secrets. Session IDs are scoped to both owner and bearer fingerprint.
-module(ecai_aws_setup).
-behaviour(gen_server).
-ifdef(TEST).
-export([recovered/1, public/2]).
-endif.
-export([start_link/0, start_link/1, connect/4, disconnect/3, snapshot/1, snapshot/2, operation/2,
         plan/5, action/5, fingerprint/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/1, format_status/2]).

start_link() -> start_link(#{}).
start_link(Options) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).
snapshot(Owner) -> snapshot(Owner, undefined).
snapshot(Owner, Binding) -> gen_server:call(?MODULE, {snapshot, Owner, Binding}).
operation(Owner, Id) -> gen_server:call(?MODULE, {operation, Owner, Id}).
disconnect(Owner, Binding, Id) -> gen_server:call(?MODULE, {disconnect, Owner, Binding, Id}).
plan(Owner, Binding, Session, Key, Options) -> gen_server:call(?MODULE, {plan, Owner, Binding, Session, Key, Options}, 30000).
action(Owner, Binding, Id, Action, Input) -> gen_server:call(?MODULE, {action, Owner, Binding, Id, Action, Input}, 30000).

connect(Owner, Binding, Region, Credentials) ->
    %% Executed in the sensitive HTTP caller, not the durable manager process.
    case gen_server:call(?MODULE, {allocate, Owner, Binding, Region}) of
        {ok, Id, Pid} ->
            Result = try ecai_aws_setup_session:connect(Pid, ecai_aws_setup_config:get(), Credentials, Region)
                     catch _:_ -> {error, <<"setup_session_unavailable">>} end,
            case Result of
                {ok, Identity} -> gen_server:call(?MODULE, {connected, Owner, Binding, Id, Identity});
                Error -> disconnect(Owner, Binding, Id), Error
            end;
        Error -> Error
    end.

init(Options) ->
    process_flag(sensitive, true),
    Path = maps:get(path, Options, ecai_aws_setup_config:state_path()),
    ok = ecai_paths:ensure_parent(Path),
    case dets:open_file(ecai_aws_setup_dets, [{file, Path}, {type, set}, {auto_save, 1000}]) of
        {ok, T} ->
            ok = file:change_mode(Path, 8#600),
            Ops = dets:foldl(fun({Id, Op}, Acc) -> Acc#{Id => recovered(Op)} end, #{}, T),
            maps:foreach(fun(Id, Op) -> ok = dets:insert(T, {Id, Op}) end, Ops),
            ok = dets:sync(T),
            erlang:send_after(5000, self(), tick),
            {ok, #{table => T, operations => Ops, sessions => #{}, tasks => #{}, links => #{}}};
        {error, _} -> {stop, aws_setup_store_unavailable}
    end.

handle_call({snapshot, Owner, Binding}, _From, S) ->
    Ops = [public(O, false) || O <- maps:values(maps:get(operations, S)), maps:get(<<"owner">>, O) =:= Owner],
    Sorted = lists:sort(fun(A, B) -> maps:get(<<"created_at_ms">>, A) > maps:get(<<"created_at_ms">>, B) end, Ops),
    Live = [#{<<"session_id">> => Sid, <<"expires_at_ms">> => maps:get(expires, V),
        <<"region">> => maps:get(region, V), <<"identity">> => maps:get(identity, V)} ||
        {Sid, V} <- maps:to_list(maps:get(sessions, S)), maps:get(owner, V) =:= Owner,
        maps:get(binding, V) =:= Binding, maps:get(identity, V) =/= undefined,
        maps:get(expires, V) > now_ms(), is_process_alive(maps:get(pid, V))],
    PublicSession = case Live of [First | _] -> First; [] -> null end,
    {reply, {ok, #{<<"config">> => ecai_aws_setup_config:public(Owner), <<"operations">> => Sorted,
                  <<"session">> => PublicSession}}, S};
handle_call({operation, Owner, Id}, _From, S) ->
    {reply, case owned(Owner, Id, S) of {ok, O} -> {ok, public(O, true)}; Error -> Error end, S};
handle_call({allocate, Owner, Binding, Region}, _From, S0) ->
    Clean = expire_sessions(S0),
    %% A newly authorized token may start over without retaining an old token's
    %% credential session. It cannot use that old session for AWS actions.
    S = lists:foldl(fun({Sid, V}, Acc) ->
        case maps:get(owner, V) =:= Owner andalso maps:get(binding, V) =/= Binding of
            true -> close_session(Sid, Acc);
            false -> Acc
        end
    end, Clean, maps:to_list(maps:get(sessions, Clean))),
    Sessions = maps:get(sessions, S),
    Count = length([ok || Session <- maps:values(Sessions), maps:get(owner, Session) =:= Owner]),
    Ready = ecai_aws_setup_config:allowed(Owner) andalso ecai_aws_setup_config:ready() =:= ok,
    Regions = maps:get(<<"regions">>, ecai_aws_setup_config:get()),
    case {Ready, is_binary(Region) andalso lists:member(Region, Regions), Count < 1 andalso map_size(Sessions) < 4} of
        {true, true, true} ->
            Id = random_id(),
            case ecai_aws_setup_sessions_sup:start_session(Id) of
                {ok, Pid} ->
                    Session = #{owner => Owner, binding => Binding, region => Region, pid => Pid,
                        expires => now_ms() + 900000, identity => undefined},
                    {reply, {ok, Id, Pid}, S#{sessions := Sessions#{Id => Session}}};
                _ -> {reply, {error, <<"setup_session_unavailable">>}, S}
            end;
        {false, _, _} -> {reply, {error, <<"node_setup_required">>}, S};
        {_, false, _} -> {reply, {error, <<"region_not_allowed">>}, S};
        _ -> {reply, {error, <<"setup_session_limit">>}, S}
    end;
handle_call({connected, Owner, Binding, Id, Identity}, _From, S) ->
    case session(Owner, Binding, Id, S) of
        {ok, Session} ->
            Sessions = maps:get(sessions, S),
            Reply = #{<<"session_id">> => Id, <<"expires_at_ms">> => maps:get(expires, Session),
                <<"region">> => maps:get(region, Session), <<"identity">> => Identity},
            {reply, {ok, Reply}, S#{sessions := Sessions#{Id := Session#{identity := Identity}}}};
        Error -> {reply, Error, S}
    end;
handle_call({disconnect, Owner, Binding, Id}, _From, S) ->
    case session(Owner, Binding, Id, S) of
        {ok, _} -> {reply, {ok, #{<<"credentials_discarded">> => true}}, close_session(Id, S)};
        Error -> {reply, Error, S}
    end;
handle_call({plan, Owner, Binding, Sid, Key, Options}, _From, S) ->
    case {ecai_aws_setup_config:allowed(Owner), session(Owner, Binding, Sid, S), valid_key(Key), is_map(Options)} of
        {true, {ok, #{identity := #{<<"account_id">> := Account}} = Session}, true, true} ->
            Config = ecai_aws_setup_config:get(),
            InputHash = fingerprint({maps:get(region, Session), Account, Config, Options}),
            KeyHash = fingerprint(Key),
            Existing = [O || O <- maps:values(maps:get(operations, S)), maps:get(<<"owner">>, O) =:= Owner,
                maps:get(<<"key_hash">>, O) =:= KeyHash],
            case Existing of
                [#{<<"input_hash">> := InputHash} = O] -> {reply, {ok, public(O, true)}, S};
                [_] -> {reply, {error, <<"idempotency_conflict">>}, S};
                [] -> new_plan(Owner, Sid, Session, KeyHash, InputHash, Options, S)
            end;
        {false, _, _, _} -> {reply, {error, <<"automatic_aws_disabled">>}, S};
        {_, {error, E}, _, _} -> {reply, {error, E}, S};
        _ -> {reply, {error, <<"invalid_plan_request">>}, S}
    end;
handle_call({action, Owner, Binding, Id, Action, Input}, _From, S) ->
    case {ecai_aws_setup_config:allowed(Owner), owned(Owner, Id, S)} of
        {true, {ok, #{<<"busy">> := false} = O}} ->
            dispatch(Action, Owner, Binding, O, Input, S);
        {true, {ok, _}} -> {reply, {error, <<"operation_busy">>}, S};
        {true, Error} -> {reply, Error, S};
        _ -> {reply, {error, <<"automatic_aws_disabled">>}, S}
    end;
handle_call(_, _From, S) -> {reply, {error, <<"invalid_setup_request">>}, S}.

new_plan(Owner, Sid, Session, KeyHash, InputHash, Options, S) ->
    Ops = maps:get(operations, S),
    Active = [O || O <- maps:values(Ops), maps:get(<<"owner">>, O) =:= Owner,
        not lists:member(maps:get(<<"status">>, O), [<<"deleted">>, <<"plan_failed">>, <<"discarded">>])],
    case length(Active) < 8 andalso map_size(Ops) < 4096 of
        false -> {reply, {error, <<"setup_operation_limit">>}, S};
        true ->
            {ok, #{<<"external_id">> := External}} = ecai_compute_settings:prepare_provider(Owner, <<"aws_batch">>),
            Previous = case ecai_compute_settings:provider(Owner, <<"aws_batch">>) of {ok, P} -> P; _ -> absent end,
            Id = random_id(),
            Account = maps:get(<<"account_id">>, maps:get(identity, Session)),
            O = #{<<"id">> => Id, <<"owner">> => Owner, <<"key_hash">> => KeyHash, <<"input_hash">> => InputHash,
                <<"account_id">> => Account, <<"region">> => maps:get(region, Session), <<"status">> => <<"planning">>,
                <<"busy">> => false, <<"created_at_ms">> => now_ms(), <<"updated_at_ms">> => now_ms(),
                <<"expected_provider">> => fingerprint(Previous), <<"replaces_provider">> => Previous =/= absent,
                <<"runtime_status">> => <<"unchecked">>, <<"events">> => [], <<"last_error">> => null,
                <<"credential_session_active">> => true, <<"index_dispatch">> => <<"pending">>},
            Args = #{<<"operation_id">> => Id, <<"external_id">> => External, <<"options">> => Options},
            S1 = persist(O, S),
            S2 = S1#{links := (maps:get(links, S1))#{Id => Sid}},
            started(O, <<"plan">>, maps:get(pid, Session), Args, S2)
    end.

dispatch(<<"discard">>, _Owner, _Binding, O, _Input, S) ->
    case not maps:is_key(<<"intent">>, O) andalso
            lists:member(maps:get(<<"status">>, O), [<<"planned">>, <<"plan_failed">>]) of
        true ->
            Updated = O#{<<"status">> := <<"discarded">>},
            {reply, {ok, public(Updated, true)}, persist(Updated, S)};
        false -> {reply, {error, <<"only_unused_plans_can_be_discarded">>}, S}
    end;
dispatch(<<"deploy">>, Owner, Binding, O, Input, S) ->
    Eligible = maps:get(<<"status">>, O) =:= <<"planned">> orelse
        (maps:get(<<"status">>, O) =:= <<"reconcile_required">> andalso maps:get(<<"intent">>, O, <<>>) =:= <<"deploy">>),
    case {Eligible, maps:find(<<"plan">>, O)} of
        {true, {ok, Plan}} ->
            Policy = ecai_aws_setup_config:get(),
            CurrentPolicy = ecai_aws_setup_config:ready() =:= ok andalso
                maps:get(<<"worker_image">>, Plan) =:= maps:get(<<"worker_image">>, Policy) andalso
                maps:get(<<"worker_command">>, Plan, undefined) =:= maps:get(<<"worker_command">>, Policy) andalso
                maps:get(<<"coordinator_role_arn">>, Plan) =:= maps:get(<<"coordinator_role_arn">>, Policy) andalso
                lists:member(maps:get(<<"region">>, Plan), maps:get(<<"regions">>, Policy)),
            Approved = CurrentPolicy andalso maps:get(<<"plan_sha256">>, Input, null) =:= maps:get(<<"plan_sha256">>, Plan) andalso
                maps:get(<<"confirm">>, Input, <<>>) =:= <<"create aws environment">> andalso
                maps:get(<<"acknowledge_costs_and_iam">>, Input, false) =:= true andalso
                (not maps:get(<<"replaces_provider">>, O) orelse maps:get(<<"replace_connection">>, Input, false) =:= true),
            case Approved of
                true -> with_session(Owner, Binding, O#{<<"status">> := <<"deploying">>, <<"intent">> => <<"deploy">>}, Input, <<"deploy">>, S);
                false -> {reply, {error, <<"explicit_deployment_approval_required">>}, S}
            end;
        _ -> {reply, {error, <<"plan_not_deployable">>}, S}
    end;
dispatch(<<"reconcile">>, Owner, Binding, O, Input, S) ->
    case maps:is_key(<<"plan">>, O) andalso maps:is_key(<<"intent">>, O) of
        true -> with_session(Owner, Binding, O, Input, <<"observe">>, S);
        false -> {reply, {error, <<"no_deployment_to_reconcile">>}, S}
    end;
dispatch(<<"delete">>, Owner, Binding, O, Input, S) ->
    Plan = maps:get(<<"plan">>, O, #{}),
    Probe = maps:get(<<"probe">>, O, #{}),
    ProbeSettled = lists:member(maps:get(<<"status">>, Probe, <<"NONE">>), [<<"NONE">>, <<"VERIFIED">>, <<"FAILED">>]),
    Approved = map_size(Plan) > 0 andalso maps:get(<<"confirm">>, Input, null) =:= maps:get(<<"stack_name">>, Plan, undefined)
        andalso maps:get(<<"retain_artifacts">>, Input, false) =:= true andalso ProbeSettled,
    case Approved andalso lists:member(maps:get(<<"status">>, O), [<<"deployed">>, <<"connection_conflict">>, <<"deployment_failed">>, <<"delete_failed">>]) of
        true -> with_session(Owner, Binding, O#{<<"status">> := <<"deleting">>, <<"intent">> => <<"delete">>}, Input, <<"delete">>, S);
        false -> {reply, {error, <<"explicit_delete_approval_or_settled_probe_required">>}, S}
    end;
dispatch(<<"verify">>, _Owner, _Binding, O, _Input, S) ->
    case maps:get(<<"status">>, O) =:= <<"deployed">> of
        true -> runtime_started(O, <<"verify">>, #{}, S);
        false -> {reply, {error, <<"environment_not_deployed">>}, S}
    end;
dispatch(<<"probe">>, _Owner, _Binding, O, Input, S) ->
    Enabled = maps:get(<<"probe_enabled">>, ecai_aws_setup_config:get()) =:= true,
    Approved = maps:get(<<"confirm">>, Input, <<>>) =:= <<"run paid verification job">>,
    Plan = maps:get(<<"plan">>, O, #{}),
    Ready = maps:get(<<"status">>, O) =:= <<"deployed">> andalso maps:get(<<"runtime_status">>, O) =:= <<"verified">> andalso
        maps:get(<<"worker_image">>, Plan, null) =:= maps:get(<<"worker_image">>, ecai_aws_setup_config:get()),
    case Enabled andalso Approved andalso Ready andalso not maps:is_key(<<"probe">>, O) of
        true ->
            Probe = #{<<"probe_id">> => random_id(), <<"status">> => <<"SUBMITTING">>},
            O1 = O#{<<"probe">> => Probe, <<"probe_approved_at_ms">> => now_ms()},
            %% The durable SUBMITTING fence is saved before any SubmitJob call.
            runtime_started(O1, <<"probe_submit">>, Probe, S);
        false -> {reply, {error, <<"probe_not_ready_or_already_requested">>}, S}
    end;
dispatch(<<"probe-status">>, _Owner, _Binding, O, _Input, S) ->
    case maps:find(<<"probe">>, O) of
        {ok, Probe} -> runtime_started(O, <<"probe_observe">>, #{<<"probe">> => Probe}, S);
        error -> {reply, {error, <<"no_verification_job">>}, S}
    end;
dispatch(_, _, _, _, _, S) -> {reply, {error, <<"unsupported_setup_action">>}, S}.

with_session(Owner, Binding, O, Input, Action, S) ->
    Sid = maps:get(<<"session_id">>, Input, <<>>),
    case session(Owner, Binding, Sid, S) of
        {ok, #{identity := #{<<"account_id">> := Account}, region := Region} = Session} ->
            case Account =:= maps:get(<<"account_id">>, O) andalso Region =:= maps:get(<<"region">>, O) of
                true ->
                    S1 = S#{links := (maps:get(links, S))#{maps:get(<<"id">>, O) => Sid}},
                    started(O#{<<"credential_session_active">> := true}, Action, maps:get(pid, Session), #{<<"plan">> => maps:get(<<"plan">>, O)}, S1);
                false -> {reply, {error, <<"aws_account_or_region_mismatch">>}, S}
            end;
        {ok, _} -> {reply, {error, <<"setup_session_not_connected">>}, S};
        Error -> {reply, Error, S}
    end.
runtime_started(O, Action, Args, S) ->
    Payload = #{<<"plan">> => maps:get(<<"plan">>, O), <<"outputs">> => maps:get(<<"outputs">>, O), <<"args">> => Args},
    started(O, Action, runtime, Payload, S).
started(O0, Action, Runner, Args, S) ->
    O = O0#{<<"busy">> := true, <<"current_action">> => Action, <<"last_error">> := null},
    S1 = persist(O, S),
    Parent = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        process_flag(sensitive, true),
        Result = try case Runner of
            runtime -> ecai_aws_setup_session:runtime(Action, Args);
            _ -> ecai_aws_setup_session:run(Runner, Action, Args)
        end catch _:_ -> {error, <<"setup_worker_interrupted">>} end,
        Parent ! {task_result, Ref, Result}
    end),
    Task = #{id => maps:get(<<"id">>, O), action => Action, pid => Pid, monitor => Monitor},
    {reply, {ok, public(O, true)}, S1#{tasks := (maps:get(tasks, S1))#{Ref => Task}}}.

handle_cast(_, S) -> {noreply, S}.
handle_info({task_result, Ref, Result}, S) ->
    case maps:take(Ref, maps:get(tasks, S)) of
        {Task, Tasks} ->
            erlang:demonitor(maps:get(monitor, Task), [flush]),
            O = maps:get(maps:get(id, Task), maps:get(operations, S)),
            S1 = S#{tasks := Tasks},
            {noreply, complete(O#{<<"busy">> := false}, maps:get(action, Task), Result, S1)};
        error -> {noreply, S}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, S) ->
    case [Ref || {Ref, T} <- maps:to_list(maps:get(tasks, S)), maps:get(monitor, T) =:= Monitor] of
        [Ref] -> self() ! {task_result, Ref, {error, <<"setup_worker_interrupted">>}};
        [] -> ok
    end,
    {noreply, S};
handle_info({auto_verify, Id}, S) ->
    case maps:find(Id, maps:get(operations, S)) of
        {ok, O = #{<<"busy">> := false, <<"status">> := <<"deployed">>}} ->
            case ecai_aws_setup_config:allowed(maps:get(<<"owner">>, O)) of
                true -> {reply, _, S1} = runtime_started(O, <<"verify">>, #{}, S), {noreply, S1};
                false -> {noreply, S}
            end;
        _ -> {noreply, S}
    end;
handle_info(tick, S0) ->
    erlang:send_after(5000, self(), tick),
    S = expire_sessions(S0),
    S1 = lists:foldl(fun(Id, Acc) -> poll(Id, Acc) end, S, maps:keys(maps:get(operations, S))),
    {noreply, S1};
handle_info(_, S) -> {noreply, S}.

complete(O, <<"plan">>, {ok, Plan}, S) ->
    persist(O#{<<"plan">> => Plan, <<"status">> := <<"planned">>}, S);
complete(O, Action, {ok, Result}, S) when Action =:= <<"deploy">>; Action =:= <<"observe">>; Action =:= <<"delete">> ->
    O1 = O#{<<"stack_status">> => maps:get(<<"stack_status">>, Result),
        <<"stack_id">> => maps:get(<<"stack_id">>, Result, maps:get(<<"stack_id">>, O, null)),
        <<"events">> := maps:get(<<"events">>, Result, [])},
    case maps:get(<<"stack_status">>, Result) of
        <<"CREATE_COMPLETE">> ->
            case maps:get(<<"intent">>, O, <<"deploy">>) of
                <<"delete">> -> persist(O1#{<<"status">> := <<"delete_failed">>, <<"last_error">> := <<"delete_not_started">>}, S);
                _ -> import_environment(O1#{<<"outputs">> => maps:get(<<"outputs">>, Result)}, S)
            end;
        <<"ABSENT">> ->
            case maps:get(<<"intent">>, O, <<"deploy">>) of
                <<"delete">> -> environment_deleted(O1, S);
                _ -> persist(O1#{<<"status">> := <<"reconcile_required">>, <<"last_error">> := <<"stack_absent_do_not_assume_deployed">>}, S)
            end;
        <<"DELETE_COMPLETE">> -> environment_deleted(O1, S);
        State ->
            case binary:match(State, <<"IN_PROGRESS">>) of
                nomatch ->
                    Next = case maps:get(<<"intent">>, O, <<"deploy">>) of <<"delete">> -> <<"delete_failed">>; _ -> <<"deployment_failed">> end,
                    finish_session(O1#{<<"status">> := Next, <<"last_error">> := <<"inspect_cloudformation_events">>}, S);
                _ ->
                    Next = case maps:get(<<"intent">>, O, <<"deploy">>) of <<"delete">> -> <<"deleting">>; _ -> <<"deploying">> end,
                    persist(O1#{<<"status">> := Next}, S)
            end
    end;
complete(O, <<"verify">>, {ok, Result}, S) ->
    Owner = maps:get(<<"owner">>, O),
    case ecai_compute_settings:provider(Owner, <<"aws_batch">>) of
        {ok, P} ->
            Expected = maps:get(<<"imported_provider">>, O, <<>>),
            case fingerprint(P) =:= Expected of
                true ->
                    case ecai_compute_settings:mark_verified(Owner, <<"aws_batch">>, crypto:hash(sha256, term_to_binary(P))) of
                        {ok, NewP} -> persist(O#{<<"runtime_status">> := <<"verified">>, <<"runtime_checks">> => maps:get(<<"checks">>, Result, []), <<"imported_provider">> := fingerprint(NewP)}, S);
                        _ -> persist(O#{<<"runtime_status">> := <<"failed">>, <<"last_error">> := <<"connection_changed_during_verification">>}, S)
                    end;
                false -> persist(O#{<<"runtime_status">> := <<"failed">>, <<"last_error">> := <<"connection_changed_during_verification">>}, S)
            end;
        _ -> persist(O#{<<"runtime_status">> := <<"failed">>, <<"last_error">> := <<"connection_missing">>}, S)
    end;
complete(O, Action, {ok, Probe}, S) when Action =:= <<"probe_submit">>; Action =:= <<"probe_observe">> ->
    persist(O#{<<"probe">> => Probe}, S);
complete(O, Action, {error, Error}, S) ->
    Safe = case is_binary(Error) andalso byte_size(Error) =< 80 of true -> Error; false -> <<"aws_setup_failed">> end,
    O1 = O#{<<"last_error">> := Safe},
    Updated = case Action of
        <<"plan">> -> O1#{<<"status">> := <<"plan_failed">>};
        <<"verify">> -> O1#{<<"runtime_status">> := <<"failed">>};
        <<"probe_submit">> -> O1#{<<"probe">> := (maps:get(<<"probe">>, O1))#{<<"status">> := <<"UNKNOWN">>}};
        <<"probe_observe">> -> O1#{<<"probe">> := (maps:get(<<"probe">>, O1))#{<<"status">> := <<"UNKNOWN">>}};
        _ -> O1#{<<"status">> := <<"reconcile_required">>}
    end,
    persist(Updated, S).

import_environment(O, S) ->
    %% Reconciliation after success is read-only: do not re-import and clobber
    %% provider changes. Only a never-imported operation may use its pinned CAS.
    case maps:is_key(<<"imported_provider">>, O) of
        true -> finish_session(O#{<<"status">> := <<"deployed">>}, S);
        false ->
            Plan = maps:get(<<"plan">>, O), Owner = maps:get(<<"owner">>, O),
            Connection = maps:get(<<"connection">>, Plan),
            DefinitionArn = maps:get(<<"JobDefinitionArn">>, maps:get(<<"outputs">>, O)),
            Revision = lists:last(binary:split(DefinitionArn, <<":">>, [global])),
            Name = maps:get(<<"job_definition">>, Connection),
            PinnedConnection = Connection#{<<"job_definition">> := <<Name/binary, ":", Revision/binary>>},
            case ecai_compute_settings:import_aws_provider(Owner, maps:get(<<"expected_provider">>, O),
                    PinnedConnection, maps:get(<<"external_id">>, Plan)) of
                {ok, P} ->
                    self() ! {auto_verify, maps:get(<<"id">>, O)},
                    finish_session(O#{<<"status">> := <<"deployed">>, <<"imported_provider">> => fingerprint(P)}, S);
                _ -> finish_session(O#{<<"status">> := <<"connection_conflict">>, <<"last_error">> := <<"provider_changed_import_not_applied">>}, S)
            end
    end.
environment_deleted(O, S) ->
    case maps:find(<<"imported_provider">>, O) of
        {ok, Expected} -> ecai_compute_settings:remove_aws_provider(maps:get(<<"owner">>, O), Expected);
        error -> ok
    end,
    finish_session(O#{<<"status">> := <<"deleted">>, <<"runtime_status">> := <<"unchecked">>}, S).
finish_session(O, S) ->
    Id = maps:get(<<"id">>, O),
    S1 = case maps:find(Id, maps:get(links, S)) of {ok, Sid} -> close_session(Sid, S); error -> S end,
    persist(O#{<<"credential_session_active">> := false}, S1).
poll(Id, S) ->
    O = maps:get(Id, maps:get(operations, S)),
    case not maps:get(<<"busy">>, O) andalso ecai_aws_setup_config:allowed(maps:get(<<"owner">>, O)) of
        false -> S;
        true ->
            case lists:member(maps:get(<<"status">>, O), [<<"deploying">>, <<"deleting">>]) of
                true ->
                    Sid = maps:get(Id, maps:get(links, S), undefined),
                    case maps:find(Sid, maps:get(sessions, S)) of
                        {ok, Session} ->
                            {reply, _, S1} = started(O, <<"observe">>, maps:get(pid, Session), #{<<"plan">> => maps:get(<<"plan">>, O)}, S), S1;
                        error -> persist(O#{<<"status">> := <<"reconcile_required">>, <<"credential_session_active">> := false, <<"last_error">> := <<"reconnect_aws_to_reconcile">>}, S)
                    end;
                false ->
                    Probe = maps:get(<<"probe">>, O, #{}),
                    case lists:member(maps:get(<<"status">>, Probe, <<>>), [<<"SUBMITTED">>, <<"PENDING">>, <<"RUNNABLE">>, <<"STARTING">>, <<"RUNNING">>]) of
                        true -> {reply, _, S1} = runtime_started(O, <<"probe_observe">>, #{<<"probe">> => Probe}, S), S1;
                        false -> S
                    end
            end
    end.

owned(Owner, Id, S) ->
    case maps:find(Id, maps:get(operations, S)) of
        {ok, #{<<"owner">> := Owner} = O} -> {ok, O};
        _ -> {error, <<"operation_not_found">>}
    end.
session(Owner, Binding, Id, S) ->
    case maps:find(Id, maps:get(sessions, S)) of
        {ok, #{owner := Owner, binding := Binding, expires := Expires, pid := Pid} = Session} ->
            case Expires > now_ms() andalso is_process_alive(Pid) of
                true -> {ok, Session};
                false -> {error, <<"setup_session_expired">>}
            end;
        _ -> {error, <<"setup_session_not_found">>}
    end.
close_session(Id, S) ->
    case maps:take(Id, maps:get(sessions, S)) of
        {#{pid := Pid}, Sessions} ->
            ecai_aws_setup_session:close(Pid),
            Links = maps:get(links, S),
            Affected = [OpId || {OpId, Sid} <- maps:to_list(Links), Sid =:= Id],
            S1 = S#{sessions := Sessions, links := maps:without(Affected, Links)},
            lists:foldl(fun(OpId, Acc) ->
                O = maps:get(OpId, maps:get(operations, Acc)),
                persist(O#{<<"credential_session_active">> := false}, Acc)
            end, S1, Affected);
        error -> S
    end.
expire_sessions(S) ->
    lists:foldl(fun({Id, Session}, Acc) ->
        case maps:get(expires, Session) =< now_ms() orelse not is_process_alive(maps:get(pid, Session)) orelse
                not ecai_aws_setup_config:allowed(maps:get(owner, Session)) of
            true -> close_session(Id, Acc);
            false -> Acc
        end
    end, S, maps:to_list(maps:get(sessions, S))).
persist(O0, S) ->
    O = O0#{<<"updated_at_ms">> := now_ms()}, Id = maps:get(<<"id">>, O), T = maps:get(table, S),
    ok = dets:insert(T, {Id, O}), ok = dets:sync(T),
    S#{operations := (maps:get(operations, S))#{Id => O}}.
public(O, Details) ->
    Out = maps:without([<<"owner">>, <<"key_hash">>, <<"input_hash">>, <<"expected_provider">>, <<"imported_provider">>], O),
    case {Details, maps:find(<<"plan">>, Out)} of
        {false, {ok, Plan}} -> Out#{<<"plan">> := maps:without([<<"template">>], Plan)};
        _ -> Out
    end.
recovered(O) ->
    O1 = O#{<<"busy">> := false, <<"credential_session_active">> := false},
    O2 = case maps:get(<<"status">>, O1) of
        <<"planning">> -> O1#{<<"status">> := <<"plan_failed">>, <<"last_error">> := <<"node_restarted_create_new_plan">>};
        Status when Status =:= <<"deploying">>; Status =:= <<"deleting">> ->
            O1#{<<"status">> := <<"reconcile_required">>, <<"last_error">> := <<"node_restarted_reconnect_aws">>};
        _ -> O1
    end,
    case maps:find(<<"probe">>, O2) of
        {ok, P = #{<<"status">> := <<"SUBMITTING">>}} -> O2#{<<"probe">> := P#{<<"status">> := <<"UNKNOWN">>}};
        _ -> O2
    end.
valid_key(K) -> is_binary(K) andalso byte_size(K) >= 8 andalso byte_size(K) =< 128.
fingerprint(Term) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, term_to_binary(Term)))).
random_id() -> string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))).
now_ms() -> erlang:system_time(millisecond).
terminate(_, S) ->
    maps:foreach(fun(_, #{pid := Pid}) -> exit(Pid, kill) end, maps:get(tasks, S)),
    maps:foreach(fun(_, #{pid := Pid}) -> ecai_aws_setup_session:close(Pid) end, maps:get(sessions, S)),
    dets:close(maps:get(table, S)), ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) when is_map(Status) -> Status#{state => redacted, message => redacted, reason => redacted, log => []}.
format_status(_, _) -> [{data, [{"State", redacted}]}].
