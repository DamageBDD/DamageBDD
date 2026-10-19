%% Durable account-scoped ledger. Dispatch always rechecks current node/account policy.
-module(ecai_eval_srv).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start_link/0, start_link/1, request/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
%% Owner is supplied by authenticated HTTP/BDD code, never copied from JSON.
request(Op, Owner, Body) -> gen_server:call(?MODULE, {Op, Owner, Body}, 30000).
init(Opts) ->
    Default = filename:join([ecai_paths:index_state_dir(), "evaluation", "ledger.dets"]),
    Path = ecai_paths:normalize(maps:get(path, Opts, application:get_env(ecai, eval_store_path, Default))),
    Dir = filename:dirname(Path), ok = filelib:ensure_dir(Path),
    ok = regular_directory(Dir), ok = file:change_mode(Dir, 8#700),
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, #file_info{type = regular}} -> ok;
        _ -> exit(unsafe_evaluation_store_path)
    end,
    {ok, T} = dets:open_file(ecai_eval_ledger, [{file, Path}, {type, set}, {repair, false}, {auto_save, 5000}]),
    ok = file:change_mode(Path, 8#600),
    ets:new(ecai_eval_index, [named_table, private, bag]),
    ets:new(ecai_eval_quota, [named_table, private, set]),
    ets:new(ecai_eval_attempt_briefs, [named_table, private, set]),
    Recover = dets:foldl(fun({K, V}, Acc) ->
        index_row(K, V),
        case element(1,K) =:= attempt andalso maps:get(<<"state">>, V, undefined) =:= <<"inflight">> of
            true -> [{K,V}|Acc]; false -> Acc end end, [], T),
    %% Never retry a possibly paid request after losing its process/receipt.
    lists:foreach(fun({K, A}) -> case maps:get(<<"state">>, A) of
        <<"inflight">> -> put(T, K, A#{<<"state">> => <<"uncertain">>, <<"reason">> => <<"node_restarted_during_request">>});
        _ -> ok end end, Recover),
    erlang:send_after(250, self(), tick),
    {ok, #{table => T, active => #{}, last_owner => undefined, ticks => 0}}.
regular_directory(Dir) -> case file:read_link_info(Dir) of
    {ok, #file_info{type = directory}} -> ok; _ -> {error, unsafe_evaluation_directory} end.

handle_call({Op, Owner, Body}, _From, S) ->
    try
        ecai_eval_util:text(Owner, 256), ecai_eval_util:require(is_map(Body), object_required),
        {Reply, S1} = operation(Op, Owner, Body, S),
        self() ! dispatch, {reply, {ok, Reply}, S1}
    catch
        throw:{eval_error, Why} -> {reply, {error, Why}, S};
        error:{badkey, _} -> {reply, {error, missing_required_field}, S};
        error:badarg -> {reply, {error, invalid_request}, S};
        error:_ -> {reply, {error, invalid_request}, S}
    end;
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(tick, S) ->
    N = maps:get(ticks, S) + 1,
    S0 = case N rem 240 of 0 -> purge(S); _ -> S end,
    erlang:send_after(250, self(), tick), {noreply, dispatch(S0#{ticks => N})};
handle_info(dispatch, S) -> {noreply, dispatch(S)};
handle_info({eval_result, Pid, Token, Result}, S) ->
    case maps:find(Pid, maps:get(active, S)) of
        {ok, #{token := Token} = Lease} ->
            T = maps:get(table, S), K = maps:get(key, Lease), A = get(T, K, #{}),
            case {maps:get(<<"state">>, A, undefined), maps:get(<<"token">>, A, undefined)} of
                {<<"inflight">>, Token} -> put(T, K, maps:merge(A, Result#{<<"completed_at_ms">> => ecai_eval_util:now_ms()}));
                _ -> ok
            end,
            {noreply, release(Pid, S)};
        _ -> {noreply, S}
    end;
handle_info({deadline, Pid, Token}, S) ->
    case maps:find(Pid, maps:get(active, S)) of
        {ok, #{token := Token} = Lease} ->
            exit(Pid, kill), uncertain(Lease, <<"request_deadline_exceeded">>, S), {noreply, release(Pid, S)};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Monitor, process, Pid, _Reason}, S) ->
    case maps:find(Pid, maps:get(active, S)) of
        {ok, #{monitor := Monitor} = Lease} ->
            uncertain(Lease, <<"worker_lost_before_receipt">>, S), {noreply, release(Pid, S)};
        _ -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.
terminate(_, S) ->
    maps:foreach(fun(Pid, _) -> exit(Pid, kill) end, maps:get(active, S, #{})),
    dets:close(maps:get(table, S)), ok.
code_change(_, S, _) -> {ok, S}.

operation(settings, O, B, S) ->
    ecai_eval_util:keys(B, []), T = maps:get(table, S),
    A = account(T, O), {Public, TargetError} = case ecai_eval_provider:catalog() of
        {ok, Ns} -> {[P || {P, _} <- Ns], null}; {error, Why} -> {[], ecai_eval_util:bin(Why)} end,
    {#{<<"version">> => maps:get(<<"version">>, A), <<"preferences">> => maps:get(<<"preferences">>, A),
       <<"effective">> => ecai_eval_policy:effective(maps:get(<<"preferences">>, A)),
       <<"node_policy">> => ecai_eval_util:public(ecai_eval_policy:node()),
       <<"targets">> => Public, <<"target_error">> => TargetError,
       <<"daily_reserved_calls">> => daily(T, O), <<"budget_scope">> => <<"account on this node">>}, S};
operation(save_settings, O, B, S) ->
    ecai_eval_util:keys(B, [<<"version">>, <<"changes">>]), T = maps:get(table, S), Old = account(T, O),
    V = maps:get(<<"version">>, Old), ecai_eval_util:require(maps:get(<<"version">>, B) =:= V, version_conflict),
    Pref = ecai_eval_policy:validate(maps:get(<<"changes">>, B), maps:get(<<"preferences">>, Old)),
    New = #{<<"version">> => V+1, <<"preferences">> => Pref}, put(T, {account, O}, New), {New, S};
operation(suites, O, B, S) ->
    ecai_eval_util:keys(B, []), T = maps:get(table, S),
    {[suite_summary(R) || {{suite, Who, _}, R} <- rows(T, suite), Who =:= O], S};
operation(import_suite, O, B, S) ->
    %% Total HTTP import bytes are bounded before normalization and term indexing.
    Suite = ecai_eval_spec:normalize(B), T = maps:get(table, S), Id = ecai_eval_util:hash(Suite), K = {suite, O, Id},
    case get(T, K, undefined) of
        undefined ->
            N = ecai_eval_policy:node(), All = rows(T, suite),
            ecai_eval_util:require(length(All) < 500, node_suite_capacity),
            ecai_eval_util:require(length([ok || {{suite, Who, _}, _} <- All, Who =:= O]) < maps:get(<<"max_account_suites">>, N), account_suite_capacity),
            R = #{<<"id">> => Id, <<"owner">> => O, <<"spec">> => Suite, <<"source">> => B,
                  <<"created_at_ms">> => ecai_eval_util:now_ms(), <<"approvals">> => #{}},
            put(T, K, R), {suite_summary(R), S};
        Old -> {suite_summary(Old), S}
    end;
operation(suite, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>]), {own_suite(maps:get(table, S), O, maps:get(<<"id">>, B)), S};
operation(approve_suite, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>, <<"owner">>, <<"note">>]), T = maps:get(table, S),
    Owner = maps:get(<<"owner">>, B, O), R = own_suite(T, Owner, maps:get(<<"id">>, B)), authorized(O, R),
    Note = ecai_eval_util:text(maps:get(<<"note">>, B), 4096),
    Approval = #{<<"at_ms">> => ecai_eval_util:now_ms(), <<"note">> => Note},
    %% First annotation approval is immutable; a changed label needs a new suite.
    As = maps:get(<<"approvals">>, R),
    New = R#{<<"approvals">> => case maps:is_key(O, As) of true -> As; false -> As#{O => Approval} end},
    put(T, {suite, Owner, maps:get(<<"id">>, R)}, New), {suite_summary(New), S};
operation(runs, O, B, S) ->
    ecai_eval_util:keys(B, []), T = maps:get(table, S),
    Runs = lists:reverse(lists:sort([{maps:get(<<"created_at_ms">>, R), R} || {{run, Who, _}, R} <- rows(T, run), Who =:= O])),
    {[run_summary(R, T) || {_, R} <- Runs], S};
operation(submit, O, B, S) -> submit(O, B, S);
operation(run, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>]), T = maps:get(table, S), R = own_run(T, O, maps:get(<<"id">>, B)),
    {#{<<"run">> => R, <<"report">> => report(R, T)}, S};
operation(attempt, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>, <<"task_id">>]), T = maps:get(table, S), R = own_run(T, O, maps:get(<<"id">>, B)),
    Task = find_task(R, maps:get(<<"task_id">>, B)),
    {get(T, {attempt, O, maps:get(<<"id">>, R), maps:get(<<"id">>, Task)}, #{<<"state">> => case maps:get(<<"cancelled">>, R) of true -> <<"cancelled">>; false -> <<"pending">> end}), S};
operation(cancel, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>]), T = maps:get(table, S), R = own_run(T, O, maps:get(<<"id">>, B)),
    Id = maps:get(<<"id">>, R),
    %% Stop scheduling before killing workers. Outstanding calls stay uncertain.
    put(T, {run, O, Id}, R#{<<"cancelled">> => true}),
    S1 = lists:foldl(fun({Pid, Lease}, Acc) ->
        case maps:get(owner, Lease) =:= O andalso maps:get(run_id, Lease) =:= Id of
            true -> exit(Pid, kill), uncertain(Lease, <<"cancelled_after_dispatch">>, Acc), release(Pid, Acc);
            false -> Acc end end, S, maps:to_list(maps:get(active, S))),
    lists:foreach(fun(Task) -> K = {attempt, O, Id, maps:get(<<"id">>, Task)},
        case get(T, K, undefined) of undefined -> put(T, K, #{<<"state">> => <<"cancelled">>}); _ -> ok end end, maps:get(<<"plan">>, R)),
    {#{<<"id">> => Id, <<"cancelled">> => true}, S1};
operation(review_queue, O, B, S) ->
    ecai_eval_util:keys(B, []), T = maps:get(table, S),
    Suites = [R || {_, R} <- rows(T, suite), is_authorized(O, R)],
    SuiteItems = [#{<<"kind">> => <<"suite">>, <<"owner">> => maps:get(<<"owner">>, R),
                   <<"id">> => maps:get(<<"id">>, R), <<"name">> => maps:get(<<"name">>, maps:get(<<"spec">>, R))} || R <- Suites, not maps:is_key(O, maps:get(<<"approvals">>, R))],
    TrialItems = lists:append([review_items(O, R, T) || {_, R} <- rows(T, run),
        lists:any(fun(SR) -> maps:get(<<"owner">>, SR) =:= maps:get(<<"owner">>, R) andalso maps:get(<<"id">>, SR) =:= maps:get(<<"suite_id">>, R) end, Suites)]),
    {#{<<"items">> => lists:sublist(SuiteItems ++ TrialItems, 100), <<"total">> => length(SuiteItems)+length(TrialItems)}, S};
operation(review_detail, O, B, S) ->
    ecai_eval_util:keys(B, [<<"kind">>, <<"owner">>, <<"id">>, <<"task_id">>]), T = maps:get(table, S), Owner = maps:get(<<"owner">>, B),
    case maps:get(<<"kind">>, B) of
        <<"suite">> -> SR = own_suite(T, Owner, maps:get(<<"id">>, B)), authorized(O, SR), {SR, S};
        <<"attempt">> ->
            R = own_run(T, Owner, maps:get(<<"id">>, B)), SR = own_suite(T, Owner, maps:get(<<"suite_id">>, R)), authorized(O, SR),
            Task = find_task(R, maps:get(<<"task_id">>, B)),
            A = get(T, {attempt, Owner, maps:get(<<"id">>, R), maps:get(<<"id">>, Task)}, #{}),
            {#{<<"case">> => ecai_eval_spec:case_by_id(maps:get(<<"spec">>, SR), maps:get(<<"case_id">>, Task)), <<"attempt">> => maps:without([<<"reviews">>, <<"provider_meta">>, <<"grade">>, <<"effective_config">>, <<"execution_policy">>], A)}, S};
        _ -> throw({eval_error, invalid_kind})
    end;
operation(review, O, B, S) ->
    ecai_eval_util:keys(B, [<<"owner">>, <<"id">>, <<"task_id">>, <<"verdict">>, <<"note">>]), T = maps:get(table, S),
    Owner = maps:get(<<"owner">>, B, O), R = own_run(T, Owner, maps:get(<<"id">>, B)), SR = own_suite(T, Owner, maps:get(<<"suite_id">>, R)), authorized(O, SR),
    Task = find_task(R, maps:get(<<"task_id">>, B)), K = {attempt, Owner, maps:get(<<"id">>, R), maps:get(<<"id">>, Task)},
    A = get(T, K, #{}), ecai_eval_util:require(maps:get(<<"state">>, A, <<>>) =:= <<"done">>, trial_not_ready),
    G = maps:get(<<"grade">>, A), ecai_eval_util:require(maps:get(<<"human_required">>, G), human_review_not_required),
    Votes = maps:get(<<"reviews">>, A, #{}), ecai_eval_util:require(not maps:is_key(O, Votes), review_already_recorded),
    V = #{<<"verdict">> => ecai_eval_util:enum(maps:get(<<"verdict">>, B), [<<"pass">>, <<"fail">>, <<"indeterminate">>]),
          <<"note">> => ecai_eval_util:text(maps:get(<<"note">>, B), 4096), <<"at_ms">> => ecai_eval_util:now_ms()},
    New = A#{<<"reviews">> => Votes#{O => V}}, put(T, K, New), {#{<<"recorded">> => true}, S};
operation(compare, O, B, S) ->
    ecai_eval_util:keys(B, [<<"baseline">>, <<"candidate">>, <<"baseline_target">>, <<"candidate_target">>]), T = maps:get(table, S),
    A = own_run(T, O, maps:get(<<"baseline">>, B)), C = own_run(T, O, maps:get(<<"candidate">>, B)),
    ecai_eval_util:require(maps:get(<<"split">>, A) =:= maps:get(<<"split">>, C), incompatible_split),
    TA = maps:get(<<"baseline_target">>, B), TC = maps:get(<<"candidate_target">>, B),
    Comparison = ecai_eval_stats:compare(report(A, T), TA, report(C, T), TC),
    {Comparison#{<<"baseline_config">> => maps:get(<<"config">>, A),
                 <<"candidate_config">> => maps:get(<<"config">>, C),
                 <<"baseline_target">> => maps:get(TA, maps:get(<<"targets">>, A)),
                 <<"candidate_target">> => maps:get(TC, maps:get(<<"targets">>, C))}, S};
operation(evidence, O, B, S) ->
    ecai_eval_util:keys(B, [<<"id">>]), T = maps:get(table, S), R = own_run(T, O, maps:get(<<"id">>, B)),
    SR = own_suite(T, O, maps:get(<<"suite_id">>, R)),
    Artifact = #{<<"schema">> => <<"ecai-eval-evidence/v1">>, <<"run">> => R,
                 <<"suite">> => SR, <<"attempts">> => attempts(R, T), <<"report">> => report(R, T)},
    Bytes = ecai_eval_util:json(Artifact),
    ecai_eval_util:require(byte_size(Bytes) =< 16*1024*1024, evidence_export_too_large),
    {#{<<"manifest_bytes">> => Bytes, <<"sha256">> => ecai_eval_util:hex(crypto:hash(sha256, Bytes)),
       <<"signed">> => false, <<"claim">> => <<"Integrity receipt only; not truth, model identity attestation or certification.">>}, S};
operation(_, _, _, _) -> throw({eval_error, unsupported}).

submit(O, B, S) ->
    ecai_eval_util:keys(B, [<<"suite_id">>, <<"split">>, <<"idempotency_key">>, <<"settings">>]), T = maps:get(table, S),
    Key = ecai_eval_util:text(maps:get(<<"idempotency_key">>, B), 128), SpecHash = ecai_eval_util:hash(B),
    Existing = [R || {{run, Who, _}, R} <- rows(T, run), Who =:= O, maps:get(<<"idempotency_key">>, R) =:= Key],
    case Existing of
        [R] -> ecai_eval_util:require(maps:get(<<"request_sha256">>, R) =:= SpecHash, idempotency_conflict), {run_summary(R, T), S};
        [] ->
            Pref = ecai_eval_policy:effective(maps:get(<<"preferences">>, account(T, O))),
            Override = maps:get(<<"settings">>, B, #{}),
            ecai_eval_util:keys(Override, [<<"target_ids">>, <<"repetitions">>, <<"max_output_tokens">>, <<"pass_bps">>, <<"knowledge_mode">>, <<"retrieval_k">>]),
            C0 = ecai_eval_policy:validate(Override, Pref),
            ecai_eval_util:require(lists:all(fun(I) -> lists:member(I, maps:get(<<"target_ids">>, Pref)) end, maps:get(<<"target_ids">>, C0)), target_not_allowed),
            N = ecai_eval_policy:node(), Min = maps:get(<<"min_reviewers">>, N),
            C = C0#{<<"min_reviewers">> => Min}, ecai_eval_util:require(maps:get(<<"enabled">>, C), evaluation_disabled),
            SR = own_suite(T, O, maps:get(<<"suite_id">>, B)), Suite = maps:get(<<"spec">>, SR),
            ecai_eval_util:require(map_size(maps:get(<<"approvals">>, SR)) >= Min, suite_review_required),
            Split = ecai_eval_util:enum(maps:get(<<"split">>, B), [<<"dev">>, <<"test">>, <<"holdout">>]),
            Cases = ecai_eval_spec:selected(Suite, Split), ecai_eval_util:require(Cases =/= [], empty_split),
            Ids = maps:get(<<"target_ids">>, C), ecai_eval_util:require(Ids =/= [], targets_required),
            Targets = maps:from_list([{I, approved_target(I, C)} || I <- Ids]),
            AllRuns = rows(T, run),
            ecai_eval_util:require(length(AllRuns) < 500, node_run_capacity),
            ecai_eval_util:require(length([ok || {{run, Who, _}, _} <- AllRuns, Who =:= O]) < maps:get(<<"max_account_runs">>, N), account_run_capacity),
            ecai_eval_util:require(length([ok || {_, R0} <- AllRuns, pending(R0, T) =/= []]) < maps:get(<<"max_queued_runs">>, N), queue_capacity),
            Id = ecai_eval_util:id(), Reps = maps:get(<<"repetitions">>, C),
            Plan0 = [#{<<"id">> => ecai_eval_util:hash([maps:get(<<"id">>, Case), Target, Rep]),
                        <<"case_id">> => maps:get(<<"id">>, Case), <<"target_id">> => Target,
                        <<"group">> => maps:get(<<"group">>, Case), <<"domain">> => maps:get(<<"domain">>, Case),
                        <<"dimension">> => maps:get(<<"dimension">>, Case), <<"evidence_ids">> => maps:get(<<"evidence_ids">>, Case),
                        <<"repetition">> => Rep} || Case <- Cases, Rep <- lists:seq(1, Reps), Target <- Ids],
            ecai_eval_util:require(length(Plan0) =< maps:get(<<"max_run_calls">>, N), run_call_limit),
            Plan = [Task || {_, Task} <- lists:sort([{ecai_eval_util:hash([Id, Task]), Task} || Task <- Plan0])],
            R = #{<<"id">> => Id, <<"owner">> => O, <<"suite_id">> => maps:get(<<"id">>, SR),
                  <<"split">> => Split, <<"idempotency_key">> => Key, <<"request_sha256">> => SpecHash,
                  <<"config">> => C, <<"targets">> => Targets,
                  <<"reviewer_ids">> => lists:usort([O | maps:get(<<"reviewers">>, Suite)]),
                  <<"approvals_at_admission">> => maps:get(<<"approvals">>, SR), <<"plan">> => Plan, <<"cancelled">> => false,
                  <<"node_policy_at_admission">> => ecai_eval_util:public(N),
                  <<"created_at_ms">> => ecai_eval_util:now_ms()},
            put(T, {run, O, Id}, R), {run_summary(R, T), S}
    end.
approved_target(I, C) ->
    case ecai_eval_provider:resolve(I) of
        {ok, P, _} -> ecai_eval_util:require(ecai_eval_policy:allowed(P, C), target_policy_denied), P;
        {error, Why} -> throw({eval_error, Why})
    end.

%% A serialized ledger reservation is synchronized BEFORE starting each worker.
%% This bounds this node's paid requests, not provider-internal usage or dollars.
dispatch(S) ->
    N = ecai_eval_policy:node(), A = maps:get(active, S),
    case maps:get(<<"enabled">>, N) andalso map_size(A) < maps:get(<<"max_parallel">>, N) of
        false -> S;
        true ->
            T = maps:get(table, S), Candidates = [{O, maps:get(<<"created_at_ms">>, R), R, Task} ||
                {{run, O, _}, R} <- rows(T, run), maps:get(<<"cancelled">>, R) =:= false,
                Task <- lists:sublist(pending(R, T), 1), owner_capacity(O, A, N)],
            Ordered = lists:sort(fun({O1, At1, _, _}, {O2, At2, _, _}) ->
                {O1 =:= maps:get(last_owner, S), At1, O1} =< {O2 =:= maps:get(last_owner, S), At2, O2} end, Candidates),
            dispatch_candidate(Ordered, S, N)
    end.
dispatch_candidate([], S, _) -> S;
dispatch_candidate([{O, _, R, Task} | Rest], S, N) ->
    T = maps:get(table, S), Current = ecai_eval_policy:effective(maps:get(<<"preferences">>, account(T, O))),
    Target = maps:get(maps:get(<<"target_id">>, Task), maps:get(<<"targets">>, R)),
    %% Revoked permission pauses unstarted work; limits never widen on a resume.
    BusyTarget = lists:any(fun(L) -> maps:get(target_id, L) =:= maps:get(<<"id">>, Target) end, maps:values(maps:get(active, S))),
    Allowed = ecai_eval_policy:allowed(Target, Current) andalso not BusyTarget andalso
              daily(T, O) < maps:get(<<"daily_calls">>, Current) andalso daily(T, all) < maps:get(<<"node_daily_calls">>, N),
    case Allowed of
        false -> dispatch_candidate(Rest, S, N);
        true ->
            RunId = maps:get(<<"id">>, R), TaskId = maps:get(<<"id">>, Task), Token = ecai_eval_util:id(),
            K = {attempt, O, RunId, TaskId},
            Reservation = #{<<"state">> => <<"inflight">>, <<"token">> => Token,
                            <<"reserved_day">> => ecai_eval_util:day(), <<"started_at_ms">> => ecai_eval_util:now_ms()},
            put(T, K, Reservation),
            SR = own_suite(T, O, maps:get(<<"suite_id">>, R)), Suite = maps:get(<<"spec">>, SR),
            Config0 = maps:get(<<"config">>, R), Config = Config0#{<<"max_output_tokens">> => min(maps:get(<<"max_output_tokens">>, Config0), maps:get(<<"max_output_tokens">>, Current))},
            Work = #{suite => Suite, 'case' => ecai_eval_spec:case_by_id(Suite, maps:get(<<"case_id">>, Task)),
                     target => Target, config => Config, node_policy => ecai_eval_util:public(N)},
            case ecai_eval_worker_sup:start_child(self(), Token, Work) of
                {ok, Pid} ->
                    Monitor = erlang:monitor(process, Pid), Timer = erlang:send_after(maps:get(<<"timeout_ms">>, N)+1000, self(), {deadline, Pid, Token}),
                    Lease = #{owner => O, run_id => RunId, key => K, token => Token, monitor => Monitor, timer => Timer, target_id => maps:get(<<"id">>, Target)},
                    S#{active => (maps:get(active, S))#{Pid => Lease}, last_owner => O};
                {error, _} ->
                    put(T, K, Reservation#{<<"state">> => <<"error">>, <<"reason">> => <<"worker_start_failed">>}), S#{last_owner => O}
            end
    end.
owner_capacity(O, Active, N) -> length([ok || L <- maps:values(Active), maps:get(owner, L) =:= O]) < maps:get(<<"max_parallel_per_account">>, N).
release(Pid, S) ->
    L = maps:get(Pid, maps:get(active, S)), erlang:cancel_timer(maps:get(timer, L)),
    erlang:demonitor(maps:get(monitor, L), [flush]), self() ! dispatch,
    S#{active => maps:remove(Pid, maps:get(active, S))}.
uncertain(L, Why, S) ->
    T = maps:get(table, S), K = maps:get(key, L), A = get(T, K, #{}),
    put(T, K, A#{<<"state">> => <<"uncertain">>, <<"reason">> => Why, <<"completed_at_ms">> => ecai_eval_util:now_ms()}).

account(T, O) -> get(T, {account, O}, #{<<"version">> => 0, <<"preferences">> => ecai_eval_policy:defaults()}).
own_suite(T, O, Id) -> found(get(T, {suite, O, Id}, undefined)).
own_run(T, O, Id) -> found(get(T, {run, O, Id}, undefined)).
found(undefined) -> throw({eval_error, not_found});
found(R) -> R.
is_authorized(O, SR) -> O =:= maps:get(<<"owner">>, SR) orelse lists:member(O, maps:get(<<"reviewers">>, maps:get(<<"spec">>, SR))).
authorized(O, SR) -> ecai_eval_util:require(is_authorized(O, SR), not_found).
find_task(R, Id) -> case [X || X <- maps:get(<<"plan">>, R), maps:get(<<"id">>, X) =:= Id] of [Task] -> Task; _ -> throw({eval_error, not_found}) end.
pending(#{<<"cancelled">> := true}, _) -> [];
pending(R, T) -> [Task || Task <- maps:get(<<"plan">>, R), get(T, {attempt, maps:get(<<"owner">>, R), maps:get(<<"id">>, R), maps:get(<<"id">>, Task)}, undefined) =:= undefined].
attempts(R, T) ->
    O = maps:get(<<"owner">>, R), Id = maps:get(<<"id">>, R),
    maps:from_list([{maps:get(<<"id">>, Task), get(T, {attempt, O, Id, maps:get(<<"id">>, Task)}, #{<<"state">> => case maps:get(<<"cancelled">>, R) of true -> <<"cancelled">>; false -> <<"pending">> end})} || Task <- maps:get(<<"plan">>, R)]).
report(R, T) ->
    SR = own_suite(T, maps:get(<<"owner">>, R), maps:get(<<"suite_id">>, R)),
    ecai_eval_stats:report(R, maps:get(<<"spec">>, SR), attempt_briefs(R)).
run_summary(R, T) ->
    _ = T, Report = ecai_eval_stats:brief(R, attempt_briefs(R)), maps:merge(maps:with([<<"id">>, <<"suite_id">>, <<"created_at_ms">>, <<"cancelled">>, <<"split">>], R),
                                    maps:with([<<"planned">>, <<"counts">>, <<"release_gate">>, <<"complete">>, <<"pass_bps">>, <<"critical_failures">>], Report)).
suite_summary(R) ->
    S = maps:get(<<"spec">>, R), #{<<"id">> => maps:get(<<"id">>, R), <<"owner">> => maps:get(<<"owner">>, R),
       <<"name">> => maps:get(<<"name">>, S), <<"version">> => maps:get(<<"version">>, S),
       <<"cases">> => length(maps:get(<<"cases">>, S)), <<"coverage">> => ecai_eval_spec:coverage(S),
       <<"approvals">> => maps:keys(maps:get(<<"approvals">>, R)), <<"created_at_ms">> => maps:get(<<"created_at_ms">>, R)}.
review_items(O, R, _T) ->
    [#{<<"kind">> => <<"attempt">>, <<"owner">> => maps:get(<<"owner">>, R), <<"id">> => maps:get(<<"id">>, R), <<"task_id">> => Id} ||
        {Id, A} <- maps:to_list(attempt_briefs(R)), maps:get(<<"state">>, A) =:= <<"done">>,
        maps:get(<<"human_required">>, maps:get(<<"grade">>, A)), not maps:is_key(O, maps:get(<<"reviews">>, A, #{}))].
daily(_T, Who) ->
    case ets:lookup(ecai_eval_quota, {ecai_eval_util:day(), Who}) of
        [{_, N}] -> N; [] -> 0 end.
rows(T, Kind) -> [{K, V} || {_, K} <- ets:lookup(ecai_eval_index, Kind), {_, V} <- dets:lookup(T, K)].
index_row(K, V) ->
    Kind = element(1,K), New = case Kind of
        attempt -> not ets:member(ecai_eval_attempt_briefs, K);
        _ -> not lists:member({Kind,K}, ets:lookup(ecai_eval_index, Kind))
    end,
    case Kind of attempt -> ok; _ -> ets:insert(ecai_eval_index, {Kind,K}) end,
    case Kind of
        attempt ->
            Brief = maps:with([<<"state">>, <<"grade">>, <<"reviews">>, <<"latency_ms">>, <<"retrieved_ids">>, <<"reserved_day">>], V),
            G = maps:get(<<"grade">>, Brief, #{}),
            SmallG = G#{<<"checks">> => [maps:with([<<"id">>, <<"type">>, <<"critical">>, <<"status">>, <<"reason">>], C) || C <- maps:get(<<"checks">>, G, [])]},
            ets:insert(ecai_eval_attempt_briefs, {K, Brief#{<<"grade">> => SmallG}}),
            case New andalso maps:is_key(<<"reserved_day">>, V) of
                true -> Day = maps:get(<<"reserved_day">>, V), Owner = element(2,K),
                        ets:update_counter(ecai_eval_quota, {Day, Owner}, 1, {{Day, Owner}, 0}),
                        ets:update_counter(ecai_eval_quota, {Day, all}, 1, {{Day, all}, 0});
                false -> ok
            end;
        _ -> ok
    end, ok.
attempt_briefs(R) ->
    maps:from_list([{maps:get(<<"id">>, Task), case ets:lookup(ecai_eval_attempt_briefs,
        {attempt, maps:get(<<"owner">>, R), maps:get(<<"id">>, R), maps:get(<<"id">>, Task)}) of
            [{_, V}] -> V; [] -> #{<<"state">> => case maps:get(<<"cancelled">>, R) of true -> <<"cancelled">>; false -> <<"pending">> end}
        end} || Task <- maps:get(<<"plan">>, R)]).
get(T, K, Default) -> case dets:lookup(T, K) of [{K, V}] -> V; [] -> Default end.
put(T, K, V) ->
    case dets:insert(T, {K, V}) of ok -> case dets:sync(T) of ok -> index_row(K, V); _ -> exit(evaluation_store_sync_failed) end; _ -> exit(evaluation_store_write_failed) end.
purge(S) ->
    T = maps:get(table, S), Cut = ecai_eval_util:now_ms() - maps:get(<<"retention_days">>, ecai_eval_policy:node()) * 86400000,
    ActiveIds = [maps:get(run_id, L) || L <- maps:values(maps:get(active, S))],
    Runs = rows(T, run),
    Expired = [R || {_, R} <- Runs, maps:get(<<"created_at_ms">>, R) < Cut,
                  not lists:member(maps:get(<<"id">>, R), ActiveIds), pending(R, T) =:= [],
                  lists:all(fun(A) -> maps:get(<<"reserved_day">>, A, -1) < ecai_eval_util:day()-1 end, maps:values(attempts(R, T)))],
    lists:foreach(fun(R) ->
        O = maps:get(<<"owner">>, R), Id = maps:get(<<"id">>, R),
        put(T, {run, O, Id}, R#{<<"cancelled">> => true, <<"purging">> => true}),
        lists:foreach(fun(Task) -> ok = delete(T, {attempt, O, Id, maps:get(<<"id">>, Task)}) end, maps:get(<<"plan">>, R)),
        ok = delete(T, {run, O, Id}) end, Expired),
    %% Referenced snapshots outlive their runs. Unreferenced old snapshots expire.
    Remaining = rows(T, run),
    lists:foreach(fun({K, SR}) ->
        InUse = lists:any(fun({_, R}) -> maps:get(<<"suite_id">>, R) =:= maps:get(<<"id">>, SR) andalso maps:get(<<"owner">>, R) =:= maps:get(<<"owner">>, SR) end, Remaining),
        case not InUse andalso maps:get(<<"created_at_ms">>, SR) < Cut of true -> ok = delete(T, K); false -> ok end end, rows(T, suite)),
    ok = dets:sync(T),
    lists:foreach(fun({K = {Day, _}, _}) ->
        case Day < ecai_eval_util:day()-1 of true -> ets:delete(ecai_eval_quota, K); false -> ok end
    end, ets:tab2list(ecai_eval_quota)), S.

delete(T, K) ->
    ok = dets:delete(T, K), ets:delete_object(ecai_eval_index, {element(1,K),K}),
    ets:delete(ecai_eval_attempt_briefs, K), ok.
