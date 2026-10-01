-module(ecai_repair_bridge).

%% Drop-in bridge for the existing inference and verification boundaries.
-export([
    maybe_enrich/2,
    maybe_enrich_args/2,
    post_verify/2,
    extract_capsule/1,
    extract_repo/1
]).

-spec maybe_enrich(term(), term()) -> term().
maybe_enrich(Task, Request) when is_map(Request) ->
    case is_repair(Task, Request) of
        false -> Request;
        true ->
            case extract_capsule(Request) of
                {ok, Capsule} -> attach(Request, Capsule);
                error -> build_and_attach(Request)
            end
    end;
maybe_enrich(_Task, Request) -> Request.

-spec maybe_enrich_args(term(), [term()]) -> [term()].
maybe_enrich_args(Task, Args) when is_list(Args) ->
    case contains_repair_request(Args, 0) of
        true -> [maybe_enrich_term(Task, Arg, 0) || Arg <- Args];
        false -> Args
    end.

maybe_enrich_term(_Task, Term, Depth) when Depth > 5 -> Term;
maybe_enrich_term(Task, Map, Depth) when is_map(Map) ->
    case is_repair(Task, Map) of
        true -> maybe_enrich(Task, Map);
        false ->
            Keys = [request, job, context, metadata, repair, payload],
            lists:foldl(
                fun(Key, Acc) ->
                    case maps:find(Key, Acc) of
                        {ok, Value} -> Acc#{Key => maybe_enrich_term(Task, Value, Depth + 1)};
                        error -> Acc
                    end
                end,
                Map,
                Keys
            )
    end;
maybe_enrich_term(Task, List, Depth) when is_list(List) ->
    case is_charlist(List) of
        true -> List;
        false -> [maybe_enrich_term(Task, V, Depth + 1) || V <- List]
    end;
maybe_enrich_term(Task, Tuple, Depth) when is_tuple(Tuple) ->
    list_to_tuple([maybe_enrich_term(Task, V, Depth + 1) || V <- tuple_to_list(Tuple)]);
maybe_enrich_term(_Task, Term, _Depth) -> Term.

contains_repair_request(_Term, Depth) when Depth > 6 -> false;
contains_repair_request(Map, Depth) when is_map(Map) ->
    is_repair(undefined, Map) orelse
    lists:any(fun(V) -> contains_repair_request(V, Depth + 1) end, maps:values(Map));
contains_repair_request(List, Depth) when is_list(List) ->
    case is_charlist(List) of
        true -> false;
        false -> lists:any(fun(V) -> contains_repair_request(V, Depth + 1) end, List)
    end;
contains_repair_request(Tuple, Depth) when is_tuple(Tuple) ->
    contains_repair_request(tuple_to_list(Tuple), Depth + 1);
contains_repair_request(_, _) -> false.

-spec post_verify([term()], term()) -> term().
post_verify(Args, ExistingResult) ->
    case is_success(ExistingResult) of
        false -> ExistingResult;
        true ->
            case {extract_capsule(Args), extract_repo(Args)} of
                {{ok, Capsule}, {ok, Repo}} ->
                    case ecai_repair_verify:verify_candidate(Repo, Capsule) of
                        {ok, Report} ->
                            Root = extract_state_root(Args),
                            Evidence = #{
                                invariant_verification => Report,
                                existing_verifier => success_descriptor(ExistingResult),
                                patch => capture_patch(Repo, Capsule)
                            },
                            _ = ecai_repair_learning:record(Root, Capsule, Evidence),
                            ExistingResult;
                        {error, Report} ->
                            {error, {ecai_invariant_verification_failed, Report}}
                    end;
                _ -> ExistingResult
            end
    end.

build_and_attach(Request) ->
    case extract_repo(Request) of
        {ok, Repo} ->
            Problem = extract_problem(Request),
            Opts = #{
                relevant_files => maps:get(relevant_files, Request, []),
                max_files => maps:get(max_context_files, Request, 16),
                max_source_bytes => maps:get(max_source_bytes, Request, 32768)
            },
            case ecai_code_invariants:build(Repo, Problem, Opts) of
                {ok, Context} ->
                    RepoState0 = maps:get(repo_state, Context, #{}),
                    RepoState = merge_repo_pin(RepoState0, Request),
                    CapsuleOpts = #{
                        allowed_files => allowed_files(Request, Context),
                        policy => maps:get(repair_policy, Request, #{})
                    },
                    case ecai_repair_capsule:new(RepoState, Problem, Context, CapsuleOpts) of
                        {ok, Capsule} ->
                            Root = extract_state_root(Request),
                            _ = ecai_repair_store:persist_capsule(Root, Capsule),
                            attach(Request, Capsule);
                        {error, Reason} -> note_error(Request, Reason)
                    end;
                {error, Reason} -> note_error(Request, Reason)
            end;
        error ->
            case context_only_capsule(Request) of
                {ok, Capsule} -> attach(Request, Capsule);
                _ -> Request
            end
    end.

context_only_capsule(Request) ->
    case maps:get(context, Request, undefined) of
        Context when is_map(Context) ->
            RepoState = maps:get(repo_state, Context, #{}),
            Problem = extract_problem(Request),
            ecai_repair_capsule:new(RepoState, Problem, Context, #{
                allowed_files => allowed_files(Request, Context),
                policy => maps:get(repair_policy, Request, #{})
            });
        _ -> {error, no_context}
    end.

attach(Request0, Capsule) ->
    Block = ecai_repair_prompt:capsule_block(Capsule, #{}),
    Metadata0 = maps:get(metadata, Request0, #{}),
    Metadata = case is_map(Metadata0) of
        true -> Metadata0#{repair_capsule => Capsule, capsule_id => ecai_repair_capsule:id(Capsule)};
        false -> #{repair_capsule => Capsule, capsule_id => ecai_repair_capsule:id(Capsule)}
    end,
    Request1 = Request0#{
        repair_capsule => Capsule,
        capsule_id => ecai_repair_capsule:id(Capsule),
        metadata => Metadata
    },
    Request2 = case maps:get(prompt, Request1, undefined) of
        undefined -> Request1#{prompt => Block};
        Prompt -> Request1#{prompt => ecai_repair_prompt:inject(Prompt, Capsule)}
    end,
    attach_messages(Request2, Block).

attach_messages(Request, Block) ->
    case maps:get(messages, Request, undefined) of
        Messages when is_list(Messages) ->
            CapsuleMessage = #{role => <<"system">>, content => Block, ecai_capsule => true},
            Request#{messages => [CapsuleMessage | remove_capsule_messages(Messages)]};
        _ -> Request
    end.

remove_capsule_messages(Messages) ->
    [M || M <- Messages, not (is_map(M) andalso maps:get(ecai_capsule, M, false) =:= true)].

-spec extract_capsule(term()) -> {ok, map()} | error.
extract_capsule(Term) -> extract_capsule(Term, 0).

extract_capsule(_Term, Depth) when Depth > 8 -> error;
extract_capsule(#{schema := <<"ecai.code-repair-capsule">>} = Capsule, _Depth) -> {ok, Capsule};
extract_capsule(Map, Depth) when is_map(Map) ->
    Preferred = [repair_capsule, capsule, metadata, context, request, job, repair],
    find_first([maps:get(K, Map, undefined) || K <- Preferred] ++ maps:values(Map), fun(V) -> extract_capsule(V, Depth + 1) end);
extract_capsule(List, Depth) when is_list(List) ->
    find_first(List, fun(V) -> extract_capsule(V, Depth + 1) end);
extract_capsule(Tuple, Depth) when is_tuple(Tuple) ->
    extract_capsule(tuple_to_list(Tuple), Depth + 1);
extract_capsule(_Other, _Depth) -> error.

-spec extract_repo(term()) -> {ok, file:filename()} | error.
extract_repo(Term) -> extract_repo(Term, 0).

extract_repo(_Term, Depth) when Depth > 7 -> error;
extract_repo(Map, Depth) when is_map(Map) ->
    Keys = [worktree, repo_path, repo, checkout, source_root, repository],
    Direct = [maps:get(K, Map, undefined) || K <- Keys],
    case find_repo(Direct) of
        {ok, _} = Found -> Found;
        error ->
            NestedKeys = [context, source, metadata, job, repair, request],
            find_first([maps:get(K, Map, undefined) || K <- NestedKeys], fun(V) -> extract_repo(V, Depth + 1) end)
    end;
extract_repo(List, Depth) when is_list(List) ->
    case is_charlist(List) of
        true -> case filelib:is_dir(List) of true -> {ok, filename:absname(List)}; false -> error end;
        false -> find_first(List, fun(V) -> extract_repo(V, Depth + 1) end)
    end;
extract_repo(Bin, _Depth) when is_binary(Bin) ->
    Path = unicode:characters_to_list(Bin),
    case filelib:is_dir(Path) of true -> {ok, filename:absname(Path)}; false -> error end;
extract_repo(Tuple, Depth) when is_tuple(Tuple) -> extract_repo(tuple_to_list(Tuple), Depth + 1);
extract_repo(_Other, _Depth) -> error.

find_repo([Value | Rest]) ->
    case extract_repo(Value, 1) of {ok, _} = Found -> Found; error -> find_repo(Rest) end;
find_repo([]) -> error.

find_first([Value | Rest], Fun) ->
    case Fun(Value) of {ok, _} = Found -> Found; _ -> find_first(Rest, Fun) end;
find_first([], _Fun) -> error.

extract_problem(Request) ->
    Keys = [problem, failure, diagnostic, error, repair_request],
    case first_defined([maps:get(K, Request, undefined) || K <- Keys]) of
        undefined -> maps:without([prompt, messages, metadata, repair_capsule], Request);
        Value when is_map(Value) -> Value;
        Value -> #{description => Value}
    end.

allowed_files(Request, Context) ->
    normalize_path_list(first_nonempty([
        maps:get(allowed_files, Request, []),
        maps:get(permitted_files, Request, []),
        maps:get(target_files, Context, [])
    ])).

merge_repo_pin(RepoState, Request) ->
    Pin = first_defined([
        maps:get(base_commit, Request, undefined),
        maps:get(source_commit, Request, undefined),
        maps:get(pinned_commit, Request, undefined)
    ]),
    case Pin of undefined -> RepoState; _ -> RepoState#{head => to_binary(Pin)} end.

extract_state_root(Term) ->
    case find_key(Term, [state_root, state_dir, persistence_root], 0) of
        undefined -> ecai_repair_store:default_root();
        Value -> to_list(Value)
    end.

find_key(_Term, _Keys, Depth) when Depth > 6 -> undefined;
find_key(Map, Keys, Depth) when is_map(Map) ->
    case first_defined([maps:get(K, Map, undefined) || K <- Keys]) of
        undefined -> first_defined([find_key(V, Keys, Depth + 1) || V <- maps:values(Map)]);
        Value -> Value
    end;
find_key(List, Keys, Depth) when is_list(List) ->
    case is_charlist(List) of true -> undefined; false -> first_defined([find_key(V, Keys, Depth + 1) || V <- List]) end;
find_key(Tuple, Keys, Depth) when is_tuple(Tuple) -> find_key(tuple_to_list(Tuple), Keys, Depth + 1);
find_key(_, _, _) -> undefined.

is_repair(Task, Request) ->
    NormalizedTask = normalize_task(Task),
    RequestTask = normalize_task(maps:get(task, Request, undefined)),
    lists:member(NormalizedTask, [repair, code_repair, patch, fix, learning_repair]) orelse
    lists:member(RequestTask, [repair, code_repair, patch, fix]) orelse
    maps:is_key(repair_request, Request) orelse
    (maps:is_key(failure, Request) andalso has_repair_context(Request)).

has_repair_context(Request) ->
    RepoKeys = [worktree, repo_path, repo, checkout, source_root, repository],
    FileKeys = [allowed_files, permitted_files, target_files, target_file, file],
    lists:any(fun(Key) -> maps:is_key(Key, Request) end, RepoKeys ++ FileKeys) orelse
    case maps:get(context, Request, undefined) of
        Context when is_map(Context) ->
            lists:any(fun(Key) -> maps:is_key(Key, Context) end, RepoKeys ++ FileKeys);
        _ -> false
    end.

capture_patch(Repo, Capsule) ->
    Payload = ecai_repair_capsule:payload(Capsule),
    RepoState = maps:get(repo_state, Payload, #{}),
    case maps:get(head, RepoState, undefined) of
        undefined -> <<>>;
        Base ->
            case ecai_repair_git:run(Repo, ["diff", "--binary", Base, "--"], 30000) of
                {ok, Diff} -> bounded_binary(Diff, 1048576);
                _ -> <<>>
            end
    end.

success_descriptor(ok) -> ok;
success_descriptor(true) -> true;
success_descriptor({ok, Value}) when is_map(Value) -> {ok, maps:without([logs, output, stdout, stderr], Value)};
success_descriptor({ok, _Value}) -> ok;
success_descriptor(#{status := Status}) -> #{status => Status};
success_descriptor(_Other) -> success.

bounded_binary(Bin, Max) when byte_size(Bin) =< Max -> Bin;
bounded_binary(Bin, Max) -> <<(binary:part(Bin, 0, Max))/binary, "
[ECAI patch evidence truncated]
">>.

is_success(ok) -> true;
is_success(true) -> true;
is_success({ok, _}) -> true;
is_success(#{status := pass}) -> true;
is_success(#{status := ok}) -> true;
is_success(_) -> false.

note_error(Request, Reason) ->
    Metadata0 = maps:get(metadata, Request, #{}),
    Metadata = case is_map(Metadata0) of true -> Metadata0; false -> #{} end,
    Request#{metadata => Metadata#{ecai_capsule_error => Reason}}.

first_nonempty([Value | Rest]) when is_list(Value), Value =/= [] -> Value;
first_nonempty([_ | Rest]) -> first_nonempty(Rest);
first_nonempty([]) -> [].

normalize_path_list(Value) when is_binary(Value) -> [Value];
normalize_path_list(Value) when is_list(Value) ->
    case is_charlist(Value) of
        true -> [unicode:characters_to_binary(Value)];
        false -> lists:usort([to_binary(V) || V <- Value, is_binary(V) orelse is_list(V)])
    end;
normalize_path_list(_) -> [].

normalize_task(Value) when is_atom(Value) -> Value;
normalize_task(Value) when is_binary(Value) -> normalize_task(binary_to_list(Value));
normalize_task(Value) when is_list(Value) ->
    case string:lowercase(Value) of
        "repair" -> repair;
        "code_repair" -> code_repair;
        "patch" -> patch;
        "fix" -> fix;
        "learning_repair" -> learning_repair;
        _ -> undefined
    end;
normalize_task(_) -> undefined.

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> undefined.

is_charlist([]) -> false;
is_charlist(List) when is_list(List) -> lists:all(fun is_integer/1, List);
is_charlist(_) -> false.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
