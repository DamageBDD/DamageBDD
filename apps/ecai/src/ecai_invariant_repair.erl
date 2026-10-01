-module(ecai_invariant_repair).

%% Public facade for preparing, invoking and verifying invariant-constrained repairs.
-export([
    prepare/2,
    prepare/3,
    infer/2,
    repair/2,
    repair/3,
    verify/2,
    augment_request/3
]).

-spec prepare(file:filename_all(), map()) -> {ok, map()} | {error, term()}.
prepare(Repo, Problem) -> prepare(Repo, Problem, #{}).

-spec prepare(file:filename_all(), map(), map()) -> {ok, map()} | {error, term()}.
prepare(Repo, Problem, Opts) ->
    case ecai_code_invariants:build(Repo, Problem, Opts) of
        {ok, Context} ->
            RepoState = maps:get(repo_state, Context, #{}),
            CapsuleOpts = #{
                allowed_files => maps:get(allowed_files, Opts, maps:get(target_files, Context, [])),
                policy => maps:get(policy, Opts, #{}),
                invariants => maps:get(invariants, Opts, maps:get(extracted_invariants, Context, []))
            },
            case ecai_repair_capsule:new(RepoState, Problem, Context, CapsuleOpts) of
                {ok, Capsule} ->
                    StateRoot = maps:get(state_root, Opts, ecai_repair_store:default_root()),
                    Persisted = ecai_repair_store:persist_capsule(StateRoot, Capsule),
                    Task = maps:get(task_prompt, Opts, default_task(Problem)),
                    Prompt = ecai_repair_prompt:build(Capsule, Task, Opts),
                    {ok, #{
                        repo => unicode:characters_to_binary(filename:absname(to_list(Repo))),
                        problem => Problem,
                        context => Context,
                        capsule => Capsule,
                        capsule_path => Persisted,
                        prompt => Prompt
                    }};
                Error -> Error
            end;
        Error -> Error
    end.

-spec infer(map(), map()) -> {ok, map()} | {error, term()}.
infer(Prepared, Opts) ->
    ecai_repair_inference:request(
        maps:get(prompt, Prepared),
        maps:get(capsule, Prepared),
        Opts
    ).

-spec repair(file:filename_all(), map()) -> {ok, map()} | {error, term()}.
repair(Repo, Problem) -> repair(Repo, Problem, #{}).

-spec repair(file:filename_all(), map(), map()) -> {ok, map()} | {error, term()}.
repair(Repo, Problem, Opts) ->
    case prepare(Repo, Problem, Opts) of
        {ok, Prepared} ->
            case infer(Prepared, Opts) of
                {ok, Candidate} -> {ok, Prepared#{candidate => Candidate}};
                Error -> Error
            end;
        Error -> Error
    end.

-spec verify(file:filename_all(), map()) -> {ok, map()} | {error, map()}.
verify(Repo, PreparedOrCapsule) ->
    Capsule = case PreparedOrCapsule of
        #{capsule := C} -> C;
        C -> C
    end,
    ecai_repair_verify:verify_candidate(Repo, Capsule).

-spec augment_request(term(), file:filename_all(), map()) -> term().
augment_request(Task, Repo, Request) when is_map(Request) ->
    ecai_repair_bridge:maybe_enrich(Task, Request#{repo => Repo});
augment_request(_Task, _Repo, Request) -> Request.

default_task(Problem) ->
    iolist_to_binary(io_lib:format(
        "Produce the smallest correct code repair for this structured failure:~n~0tp",
        [Problem]
    )).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
