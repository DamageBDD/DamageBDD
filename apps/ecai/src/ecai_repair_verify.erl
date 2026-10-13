-module(ecai_repair_verify).

%% Verifies capsule identity, source pinning, changed-file scope and API invariants.
%% Compilation/tests remain the responsibility of the existing repair verifier.
-export([
    verify_base/2,
    verify_candidate/2,
    verify_candidate/3
]).

-spec verify_base(file:filename_all(), map()) -> {ok, map()} | {error, map()}.
verify_base(Repo, Capsule) ->
    case ecai_repair_capsule:validate(Capsule) of
        ok ->
            Payload = ecai_repair_capsule:payload(Capsule),
            Context = maps:get(context, Payload, #{}),
            Manifest = maps:get(source_manifest, Context, #{}),
            Checks = [
                check_manifest_hash(Repo, Path, Fact)
             || {Path, Fact} <- maps:to_list(Manifest)
            ],
            result(Checks, #{phase => base, capsule_id => ecai_repair_capsule:id(Capsule)});
        Error ->
            {error, #{phase => base, capsule => Error, checks => []}}
    end.

-spec verify_candidate(file:filename_all(), map()) -> {ok, map()} | {error, map()}.
verify_candidate(Repo, Capsule) -> verify_candidate(Repo, Capsule, #{}).

-spec verify_candidate(file:filename_all(), map(), map()) -> {ok, map()} | {error, map()}.
verify_candidate(Repo0, Capsule, _Opts) ->
    Repo = filename:absname(to_list(Repo0)),
    case ecai_repair_capsule:validate(Capsule) of
        ok ->
            Payload = ecai_repair_capsule:payload(Capsule),
            RepoState = maps:get(repo_state, Payload, #{}),
            Context = maps:get(context, Payload, #{}),
            Policy = maps:get(policy, Payload, #{}),
            Manifest = maps:get(source_manifest, Context, #{}),
            Base = maps:get(head, RepoState, undefined),
            Allowed = lists:usort(maps:get(allowed_files, Policy, [])),
            ChangedResult = changed(Repo, Base, Manifest),
            Checks0 = [
                check_capsule(Capsule),
                check_head(Repo, Base),
                check_change_scope(ChangedResult, Allowed),
                check_change_required(ChangedResult, Policy)
            ],
            Changed =
                case ChangedResult of
                    {ok, C} -> C;
                    _ -> []
                end,
            Checks1 =
                Checks0 ++
                    [
                        check_current_file(Repo, Path, Fact, Policy, lists:member(Path, Changed))
                     || {Path, Fact} <- maps:to_list(Manifest)
                    ],
            result(Checks1, #{
                phase => candidate,
                capsule_id => ecai_repair_capsule:id(Capsule),
                changed_files => Changed,
                allowed_files => Allowed
            });
        Error ->
            {error, #{phase => candidate, capsule => Error, checks => []}}
    end.

check_capsule(Capsule) ->
    case ecai_repair_capsule:verify_id(Capsule) of
        ok -> pass(capsule_id);
        Error -> fail(capsule_id, Error)
    end.

check_head(_Repo, undefined) ->
    pass(source_head_unavailable);
check_head(Repo, Expected) ->
    case ecai_repair_git:head(Repo) of
        {ok, Expected} -> pass(source_head);
        {ok, Actual} -> fail(source_head, #{expected => Expected, actual => Actual});
        {error, Reason} -> fail(source_head, Reason)
    end.

changed(_Repo, undefined, Manifest) ->
    {ok, [Path || {Path, Fact} <- maps:to_list(Manifest), not hash_matches(_Repo, Path, Fact)]};
changed(Repo, Base, _Manifest) ->
    ecai_repair_git:changed_files(Repo, Base).

check_change_scope({ok, Changed}, Allowed) ->
    Outside = [P || P <- Changed, not lists:member(P, Allowed)],
    case Outside of
        [] -> pass(changed_file_scope);
        _ -> fail(changed_file_scope, #{outside_allowed_files => Outside})
    end;
check_change_scope({error, Reason}, _Allowed) ->
    fail(changed_file_scope, Reason).

check_change_required({ok, []}, #{require_change := true}) ->
    fail(require_change, no_files_changed);
check_change_required({ok, _}, _Policy) ->
    pass(require_change);
check_change_required({error, Reason}, _Policy) ->
    fail(require_change, Reason).

check_manifest_hash(Repo, Path, Fact) ->
    case hash_matches(Repo, Path, Fact) of
        true -> pass({source_hash, Path});
        false -> fail({source_hash, Path}, mismatch)
    end.

hash_matches(Repo, Path, Fact) ->
    case ecai_repair_git:safe_join(Repo, Path) of
        {ok, Full} ->
            case file:read_file(Full) of
                {ok, Bin} -> hex(crypto:hash(sha256, Bin)) =:= maps:get(sha256, Fact, undefined);
                _ -> false
            end;
        _ ->
            false
    end.

check_current_file(Repo, Path, Baseline, Policy, Changed) ->
    case ecai_repair_git:safe_join(Repo, Path) of
        {ok, Full} ->
            case filelib:is_regular(Full) of
                false ->
                    case maps:get(allow_file_deletion, Policy, false) of
                        true -> pass({file_deleted, Path});
                        false -> fail({file_exists, Path}, deleted)
                    end;
                true when Changed =:= false ->
                    check_manifest_hash(Repo, Path, Baseline);
                true ->
                    case
                        ecai_code_invariants:file(Full, #{
                            relative_path => Path, max_source_bytes => 0
                        })
                    of
                        {ok, Current} -> check_api(Path, Baseline, Current, Policy);
                        {error, Reason} -> fail({parse_current, Path}, Reason)
                    end
            end;
        Error ->
            fail({safe_path, Path}, Error)
    end.

check_api(Path, Baseline, Current, Policy) ->
    Pairs = [
        {preserve_exports, exports},
        {preserve_export_types, export_types},
        {preserve_behaviours, behaviours},
        {preserve_callbacks, callbacks}
    ],
    Differences = [
        #{
            field => Field,
            expected => maps:get(Field, Baseline, []),
            actual => maps:get(Field, Current, [])
        }
     || {PolicyKey, Field} <- Pairs,
        maps:get(PolicyKey, Policy, true) =:= true,
        maps:get(Field, Baseline, []) =/= maps:get(Field, Current, [])
    ],
    case Differences of
        [] -> pass({api_invariants, Path});
        _ -> fail({api_invariants, Path}, Differences)
    end.

result(Checks, Meta) ->
    Failed = [C || C = #{status := fail} <- Checks],
    Report = Meta#{
        checks => Checks,
        status =>
            case Failed of
                [] -> pass;
                _ -> fail
            end
    },
    case Failed of
        [] -> {ok, Report};
        _ -> {error, Report}
    end.

pass(Name) -> #{check => Name, status => pass}.
fail(Name, Reason) -> #{check => Name, status => fail, reason => Reason}.

hex(Bin) -> iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
