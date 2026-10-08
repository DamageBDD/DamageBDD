%% Durable, human-gated queue for verifier-validated ECAI patches.
%% Approval NEVER implies publication. All decisions are serialized by this
%% process, tied to immutable patch bytes, and synchronously written to DETS.
-module(ecai_code_review_queue).
-behaviour(gen_server).

-export([start_link/0, list/0, get/1, get/2, status/0, approve/4, reject/4, publish/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, ecai_code_review_dets).
-define(MAX_PATCH, 524288).
-define(MAX_NOTE, 2048).
-record(state, {tab, file, current = undefined}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
list() -> gen_server:call(?MODULE, list, 60000).
get(Id) -> gen_server:call(?MODULE, {get, Id}, 30000).
%% The authenticated account is supplied by the HTTP authorization layer;
%% never accept an actor identity from a request body.
get(Id, Actor) -> gen_server:call(?MODULE, {get, Id, Actor}, 30000).
status() -> gen_server:call(?MODULE, status, 30000).
approve(Id, Actor, Sha, Note) -> gen_server:call(?MODULE, {approve, Id, Actor, Sha, Note}, 30000).
reject(Id, Actor, Sha, Note) -> gen_server:call(?MODULE, {reject, Id, Actor, Sha, Note}, 30000).
publish(Id, Actor, Sha, Rev) -> gen_server:call(?MODULE, {publish, Id, Actor, Sha, Rev}, 30000).

init([]) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root() of
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, "code_review_queue.dets"),
            case dets:open_file(?TAB, [{file, File}, {type, set}, {auto_save, 10000}]) of
                {ok, ?TAB} ->
                    recover_interrupted(?TAB),
                    {ok, #state{tab = ?TAB, file = File}};
                {error, Why} -> {stop, {review_dets_unavailable, Why}}
            end;
        {error, Why} -> {stop, Why}
    end.

handle_call(list, _From, State) ->
    case ingest_validated(State#state.tab) of
        {ok, _Added} ->
            Reviews = dets:foldl(fun
                ({{review, _}, R}, Acc) -> [redact(R) | Acc];
                (_, Acc) -> Acc
            end, [], State#state.tab),
            Sorted = lists:sort(fun(A, B) -> maps:get(created_at, A) >= maps:get(created_at, B) end, Reviews),
            {reply, {ok, lists:sublist(Sorted, 200)}, State};
        Error -> {reply, Error, State}
    end;
handle_call(status, _From, State) ->
    Counts = dets:foldl(fun
        ({{review, _}, R}, Acc) ->
            S = maps:get(status, R),
            Acc#{S => maps:get(S, Acc, 0) + 1};
        (_, Acc) -> Acc
    end, #{}, State#state.tab),
    {reply, #{counts => Counts, publishing => current_id(State#state.current),
              required_approvals => required_approvals(), publish_enabled => publish_enabled()}, State};
handle_call({get, Id}, _From, State) ->
    Reply = case lookup(State#state.tab, Id) of
        {ok, R} -> {ok, (redact(R))#{patch => maps:get(patch, R),
                          events => events(State#state.tab, Id)}};
        Other -> Other
    end,
    {reply, Reply, State};
handle_call({get, Id, Actor}, _From, State) ->
    Reply = case lookup(State#state.tab, Id) of
        {ok, R} ->
            {ok, (redact(R))#{patch => maps:get(patch, R),
                events => events(State#state.tab, Id),
                publication_gate => publication_gate(R, Actor)}};
        Other -> Other
    end,
    {reply, Reply, State};
handle_call({Action, Id, Actor, Sha, Note}, _From, State)
  when Action =:= approve; Action =:= reject ->
    {reply, decide(Action, Id, Actor, Sha, Note, State#state.tab), State};
handle_call({publish, Id, Actor, Sha, Rev}, _From, State = #state{current = undefined}) ->
    case publication_admission(Id, Actor, Sha, Rev, State#state.tab) of
        {ok, Review} ->
            Updated = transition(Review, publishing, Actor, <<"publish_requested">>, State#state.tab),
            Parent = self(),
            Ref = make_ref(),
            {Pid, Mon} = spawn_monitor(fun() ->
                Result = try ecai_code_review_git:publish(Updated)
                catch Class:Why -> {error, {publish_exception, Class, Why}} end,
                Parent ! {review_publish_result, Ref, Id, Result}
            end),
            Current = #{id => Id, ref => Ref, monitor => Mon, pid => Pid},
            {reply, {ok, redact(Updated)}, State#state{current = Current}};
        Error -> {reply, Error, State}
    end;
handle_call({publish, _, _, _, _}, _From, State) ->
    {reply, {error, publish_in_progress}, State};
handle_call(_Request, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info({review_publish_result, Ref, Id, Result},
            State = #state{current = #{ref := Ref, monitor := Mon}}) ->
    erlang:demonitor(Mon, [flush]),
    case lookup(State#state.tab, Id) of
        {ok, R} ->
            {NewStatus, Info} = case Result of
                {ok, Data} -> {published, #{publication => Data, last_error => undefined}};
                {error, {push_uncertain, Reason}} ->
                    {reconcile_required, #{last_error => pretty_error(Reason)}};
                {error, Reason} -> {publish_failed, #{last_error => pretty_error(Reason)}}
            end,
            _ = transition(maps:merge(R, Info), NewStatus, <<"system">>, <<"publication_finished">>, State#state.tab);
        _ -> ok
    end,
    {noreply, State#state{current = undefined}};
handle_info({'DOWN', Mon, process, _Pid, Why},
            State = #state{current = #{monitor := Mon, id := Id}}) when Why =/= normal ->
    %% Push may have happened just before worker failure: never auto-retry.
    case lookup(State#state.tab, Id) of
        {ok, R} ->
            _ = transition(R#{last_error => pretty_error({worker_down, Why})},
                           reconcile_required, <<"system">>, <<"worker_interrupted">>, State#state.tab);
        _ -> ok
    end,
    {noreply, State#state{current = undefined}};
handle_info(_Msg, State) -> {noreply, State}.

terminate(_Reason, State) -> dets:sync(State#state.tab), dets:close(State#state.tab), ok.
code_change(_Old, State, _Extra) -> {ok, State}.

%% A review candidate is keyed by fingerprint, finding version, base commit AND patch hash;
%% a regenerated repair can never silently alter previously approved bytes.
ingest_validated(Tab) ->
    try
        Repairs = ecai_learning_store:repairs(),
        Added = lists:foldl(fun(R, Count) ->
            case candidate(R) of
                {ok, Candidate} ->
                    Key = {review, maps:get(id, Candidate)},
                    case dets:lookup(Tab, Key) of
                        [] ->
                            persist(Tab, Candidate, <<"system">>, <<"candidate_imported">>),
                            Count + 1;
                        _ -> Count
                    end;
                _ -> Count
            end
        end, 0, Repairs),
        {ok, Added}
    catch Class:Why -> {error, {repair_queue_unavailable, Class, Why}} end.

candidate(R) when is_map(R) ->
    Patch = maps:get(patch, R, undefined),
    Sha = maps:get(patch_sha256, R, undefined),
    Base = maps:get(base_commit, R, undefined),
    Fingerprint = maps:get(fingerprint, R, undefined),
    Version = maps:get(finding_version, R, undefined),
    Verified = maps:get(verifier_output, R, #{}),
    Validated = maps:get(status, R, undefined) =:= validated andalso
                is_map(Verified) andalso maps:get(status, Verified, undefined) =:= validated,
    case Validated andalso is_binary(Patch) andalso byte_size(Patch) > 0
         andalso byte_size(Patch) =< ?MAX_PATCH andalso is_binary(Sha)
         andalso is_binary(Base) andalso is_binary(Fingerprint) andalso is_binary(Version) of
        false -> {error, ineligible_repair};
        true ->
            case Sha =:= sha(Patch) andalso valid_commit(Base) andalso
                 ecai_patch_verifier:validate_patch(Patch) =:= ok of
                false -> {error, untrusted_patch};
                true ->
                    Id = sha(<<Fingerprint/binary, 0, Version/binary, 0,
                               Base/binary, 0, Sha/binary>>),
                    {ok, #{id => Id, status => pending, revision => 1,
                      fingerprint => Fingerprint, finding_version => Version,
                      application => maps:get(application, R, undefined),
                      module => maps:get(module, R, undefined),
                      summary => maps:get(summary, R, <<>>),
                      security_property => maps:get(security_property, R, <<>>),
                      tests_requested => maps:get(tests_requested, R, []),
                      verification => compact_verification(Verified),
                      source_path => maps:get(source_path, R, undefined),
                      base_commit => Base, patch_sha256 => Sha, patch => Patch,
                      approvals => [], created_at => now(), updated_at => now()}}
            end
    end;
candidate(_) -> {error, invalid_repair}.

decide(Action, Id, Actor, Sha, Note, Tab) ->
    case lookup(Tab, Id) of
        {ok, R} ->
            case valid_actor(Actor) andalso valid_note(Note) andalso Sha =:= maps:get(patch_sha256, R) of
                false -> {error, invalid_review_input};
                true ->
                    case current_repair(R) of
                        ok -> decide_current(Action, R, Actor, Note, Tab);
                        Error -> Error
                    end
            end;
        Error -> Error
    end.

decide_current(approve, R, Actor, Note, Tab) ->
    case {maps:get(status, R), lists:any(fun(A) -> maps:get(actor, A) =:= Actor end,
                                           maps:get(approvals, R, []))} of
        {pending, false} ->
            Approval = #{actor => Actor, note => Note, at => now()},
            Approvals = maps:get(approvals, R, []) ++ [Approval],
            Status = case length(Approvals) >= required_approvals() of
                true -> approved; false -> pending end,
            {ok, redact(transition(R#{approvals => Approvals}, Status, Actor, <<"approved">>, Tab))};
        {approved, false} -> {error, already_approved};
        {_, true} -> {error, duplicate_reviewer};
        _ -> {error, invalid_review_state}
    end;
decide_current(reject, R, Actor, Note, Tab) ->
    case lists:member(maps:get(status, R), [pending, approved, publish_failed]) of
        true -> {ok, redact(transition(R#{rejection_reason => Note}, rejected,
                                      Actor, <<"rejected">>, Tab))};
        false -> {error, invalid_review_state}
    end.

publication_admission(Id, Actor, Sha, Rev, Tab) ->
    case lookup(Tab, Id) of
        {ok, R} ->
            case {Sha =:= maps:get(patch_sha256, R),
                  Rev =:= maps:get(revision, R)} of
                {false, _} -> {error, patch_hash_mismatch};
                {_, false} -> {error, stale_review_revision};
                {true, true} ->
                    case maps:get(blockers, publication_gate(R, Actor)) of
                        [] -> {ok, R};
                        [Reason | _] -> {error, Reason}
                    end
            end;
        Error -> Error
    end.

%% Explain *why* a signed-in administrator cannot publish a reviewed patch.
%% This is advisory only; publication_admission checks the same gate atomically
%% on the gen_server before it starts a Git worker. No push is done here.
publication_gate(R, Actor) ->
    Approvals = maps:get(approvals, R, []),
    Count = length(Approvals),
    Required = required_approvals(),
    Status = maps:get(status, R),
    Reviewer = lists:any(fun(A) -> maps:get(actor, A) =:= Actor end, Approvals),
    Blockers0 =
        case publish_enabled() of
            true -> [];
            false -> [push_disabled]
        end,
    Blockers1 =
        case Status of
            approved -> Blockers0;
            publish_failed -> Blockers0;
            published -> Blockers0 ++ [already_published];
            rejected -> Blockers0 ++ [review_rejected];
            reconcile_required -> Blockers0 ++ [reconcile_required];
            _ -> Blockers0 ++ [review_not_approved]
        end,
    Blockers2 =
        case Count >= Required of
            true -> Blockers1;
            false -> Blockers1 ++ [approvals_missing]
        end,
    Blockers3 =
        case valid_actor(Actor) of
            true -> Blockers2;
            false -> Blockers2 ++ [invalid_publisher_identity]
        end,
    Blockers4 =
        case Reviewer of
            true -> Blockers3 ++ [publisher_is_reviewer];
            false -> Blockers3
        end,
    Blockers = case current_repair(R) of
        ok -> Blockers4;
        {error, Reason} -> Blockers4 ++ [Reason]
    end,
    #{eligible => Blockers =:= [], blockers => Blockers,
      approvals => Count, required_approvals => Required,
      publisher_is_reviewer => Reviewer, publish_enabled => publish_enabled(),
      %% Remote/origin and base HEAD are still checked at publish time.
      git_preflight => not_checked}.

current_repair(R) ->
    case ecai_learning_store:get_repair(maps:get(fingerprint, R), maps:get(finding_version, R)) of
        {ok, Repair} when is_map(Repair) ->
            case maps:get(status, Repair, undefined) =:= validated andalso
                 maps:get(patch_sha256, Repair, undefined) =:= maps:get(patch_sha256, R) andalso
                 maps:get(base_commit, Repair, undefined) =:= maps:get(base_commit, R) of
                true -> ok;
                false -> {error, repair_superseded}
            end;
        _ -> {error, repair_not_available}
    end.

transition(R, Status, Actor, Action, Tab) ->
    Updated = R#{status => Status, revision => maps:get(revision, R) + 1, updated_at => now()},
    persist(Tab, Updated, Actor, Action),
    Updated.

persist(Tab, R, Actor, Action) ->
    Id = maps:get(id, R), Rev = maps:get(revision, R),
    Event = #{action => Action, actor => Actor, at => now(),
              revision => Rev, status => maps:get(status, R),
              patch_sha256 => maps:get(patch_sha256, R)},
    ok = dets:insert(Tab, [{{review, Id}, R}, {{event, Id, Rev}, Event}]),
    ok = dets:sync(Tab).

recover_interrupted(Tab) ->
    Interrupted = dets:foldl(fun
        ({{review, _}, #{status := publishing} = R}, Acc) -> [R | Acc];
        (_, Acc) -> Acc
    end, [], Tab),
    lists:foreach(fun(R) ->
        transition(R#{last_error => <<"Node restarted during publication; inspect remote branch before retrying.">>},
                   reconcile_required, <<"system">>, <<"interrupted_restart">>, Tab)
    end, Interrupted).

lookup(Tab, Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    case dets:lookup(Tab, {review, Id}) of
        [{{review, Id}, R}] -> {ok, R};
        _ -> {error, not_found}
    end;
lookup(_, _) -> {error, invalid_review_id}.

events(Tab, Id) ->
    Rows = dets:foldl(fun
        ({{event, EventId, _}, E}, Acc) when EventId =:= Id -> [E | Acc];
        (_, Acc) -> Acc
    end, [], Tab),
    lists:sort(fun(A, B) -> maps:get(revision, A) =< maps:get(revision, B) end, Rows).

redact(R) -> maps:without([patch], R).
compact_verification(Verified) ->
    %% A verifier command can generate large output. Preserve outcomes rather
    %% than embedding compiler logs in every queue-list response.
    Steps0 = maps:get(steps, Verified, []),
    Steps = case is_list(Steps0) of true -> Steps0; false -> [] end,
    Summary = maps:with([status, patch_disposition, validation_warnings,
                         base_commit, started_at, completed_at, failure], Verified),
    Summary#{steps => [compact_step(S) || S <- lists:sublist(Steps, 50)]}.
compact_step(S) when is_map(S) ->
    R = maps:get(result, S, undefined),
    Ok = case R of #{ok := Value} -> Value; _ -> undefined end,
    (maps:with([step, patch_index], S))#{ok => Ok};
compact_step(_) -> #{}.
current_id(undefined) -> null;
current_id(#{id := Id}) -> Id.
valid_actor(A) -> is_binary(A) andalso byte_size(A) > 0 andalso byte_size(A) =< 256.
valid_note(N) -> is_binary(N) andalso byte_size(N) >= 8 andalso byte_size(N) =< ?MAX_NOTE.
valid_commit(C) when is_binary(C) ->
    (byte_size(C) =:= 40 orelse byte_size(C) =:= 64) andalso
       lists:all(fun(X) -> (X >= $0 andalso X =< $9) orelse
                     (X >= $a andalso X =< $f) end, binary_to_list(C));
valid_commit(_) -> false.
required_approvals() ->
    case application:get_env(ecai, code_review_required_approvals, 1) of
        N when is_integer(N), N >= 1, N =< 5 -> N;
        _ -> 1
    end.
publish_enabled() -> application:get_env(ecai, code_review_push_enabled, false) =:= true.
sha(Bin) -> iolist_to_binary([io_lib:format("~2.16.0b", [N]) ||
                             <<N:8>> <= crypto:hash(sha256, Bin)]).
pretty_error(V) ->
    B = iolist_to_binary(io_lib:format("~0tp", [V])),
    binary:part(B, 0, min(byte_size(B), 1024)).
now() -> list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])).
