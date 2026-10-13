-module(ecai_repair_capsule).

%% A content-addressed, deterministic envelope for code-repair facts and policy.
-export([
    new/3,
    new/4,
    validate/1,
    verify_id/1,
    id/1,
    payload/1,
    canonical_binary/1,
    encode/1,
    decode/1,
    allowed_files/1,
    fingerprint/1
]).

-define(SCHEMA, <<"ecai.code-repair-capsule">>).
-define(VERSION, 1).

-spec new(map(), map(), map()) -> {ok, map()} | {error, term()}.
new(RepoState, Problem, Context) ->
    new(RepoState, Problem, Context, #{}).

-spec new(map(), map(), map(), map()) -> {ok, map()} | {error, term()}.
new(RepoState, Problem, Context, Opts) when
    is_map(RepoState), is_map(Problem), is_map(Context), is_map(Opts)
->
    Files = lists:sort(
        lists:usort(
            maps:get(allowed_files, Opts, maps:get(target_files, Context, []))
        )
    ),
    ProblemFingerprint = digest(#{problem => Problem, files => Files}),
    Policy = maps:merge(default_policy(Files), maps:get(policy, Opts, #{})),
    Invariants = lists:sort(
        maps:get(invariants, Opts, maps:get(extracted_invariants, Context, [])) ++
            policy_invariants(Policy)
    ),
    StableRepoState = maps:without([path, repo_path, worktree, checkout], RepoState),
    Runtime = runtime_hints(RepoState),
    Payload = #{
        repo_state => StableRepoState,
        problem => Problem,
        problem_fingerprint => ProblemFingerprint,
        context => stable_context(Context),
        policy => Policy,
        invariants => Invariants
    },
    CapsuleId = digest(Payload),
    Capsule = #{
        schema => ?SCHEMA,
        version => ?VERSION,
        capsule_id => CapsuleId,
        commitment => ecai_repair_commitment:create(CapsuleId),
        runtime => Runtime,
        payload => Payload
    },
    case validate(Capsule) of
        ok -> {ok, Capsule};
        Error -> Error
    end;
new(_RepoState, _Problem, _Context, _Opts) ->
    {error, invalid_arguments}.

-spec validate(term()) -> ok | {error, term()}.
validate(#{
    schema := ?SCHEMA,
    version := ?VERSION,
    capsule_id := Id,
    commitment := Commitment,
    payload := Payload
}) when
    is_binary(Id), is_map(Payload)
->
    case maps:get(policy, Payload, undefined) of
        Policy when is_map(Policy) ->
            case maps:get(allowed_files, Policy, undefined) of
                Files when is_list(Files) ->
                    case verify_id_map(Id, Payload) of
                        ok -> ecai_repair_commitment:verify(Id, Commitment);
                        Error -> Error
                    end;
                _ ->
                    {error, missing_allowed_files}
            end;
        _ ->
            {error, missing_policy}
    end;
validate(#{schema := Schema}) ->
    {error, {unsupported_schema, Schema}};
validate(_) ->
    {error, invalid_capsule}.

-spec verify_id(map()) -> ok | {error, term()}.
verify_id(#{capsule_id := Id, payload := Payload}) -> verify_id_map(Id, Payload);
verify_id(_) -> {error, invalid_capsule}.

-spec id(map()) -> binary().
id(#{capsule_id := Id}) -> Id.

-spec payload(map()) -> map().
payload(#{payload := Payload}) -> Payload.

-spec allowed_files(map()) -> [binary()].
allowed_files(Capsule) ->
    maps:get(allowed_files, maps:get(policy, payload(Capsule), #{}), []).

-spec fingerprint(map()) -> binary().
fingerprint(Capsule) ->
    maps:get(problem_fingerprint, payload(Capsule)).

-spec canonical_binary(term()) -> binary().
canonical_binary(Term) ->
    term_to_binary(canonical(Term), [compressed]).

-spec encode(map()) -> binary().
encode(Capsule) ->
    base64:encode(term_to_binary(Capsule, [compressed])).

-spec decode(binary() | list()) -> {ok, map()} | {error, term()}.
decode(Encoded0) ->
    try
        Encoded = iolist_to_binary(Encoded0),
        Capsule = binary_to_term(base64:decode(Encoded), [safe]),
        case validate(Capsule) of
            ok -> {ok, Capsule};
            Error -> Error
        end
    catch
        Class:Reason -> {error, {decode_failed, Class, Reason}}
    end.

default_policy(Files) ->
    #{
        allowed_files => Files,
        preserve_exports => true,
        preserve_export_types => true,
        preserve_behaviours => true,
        preserve_callbacks => true,
        allow_file_deletion => false,
        require_change => true
    }.

policy_invariants(Policy) ->
    [
        #{kind => restrict_file_changes, expected => maps:get(allowed_files, Policy, [])},
        #{kind => preserve_exports, expected => maps:get(preserve_exports, Policy, true)},
        #{kind => preserve_behaviours, expected => maps:get(preserve_behaviours, Policy, true)},
        #{kind => preserve_callbacks, expected => maps:get(preserve_callbacks, Policy, true)}
    ].

verify_id_map(Id, Payload) ->
    Expected = digest(Payload),
    case secure_equal(Id, Expected) of
        true -> ok;
        false -> {error, {capsule_id_mismatch, Id, Expected}}
    end.

runtime_hints(RepoState) ->
    Path = first_defined([
        maps:get(repo_path, RepoState, undefined),
        maps:get(path, RepoState, undefined),
        maps:get(worktree, RepoState, undefined),
        maps:get(checkout, RepoState, undefined)
    ]),
    case Path of
        undefined -> #{};
        _ -> #{repo_path => Path}
    end.

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> undefined.

stable_context(Context) ->
    case maps:get(repo_state, Context, undefined) of
        RepoState when is_map(RepoState) ->
            Context#{repo_state => maps:without([path, repo_path, worktree, checkout], RepoState)};
        _ ->
            Context
    end.

digest(Term) ->
    hex(crypto:hash(sha256, canonical_binary(Term))).

canonical(Map) when is_map(Map) ->
    {map, lists:keysort(1, [{canonical(K), canonical(V)} || {K, V} <- maps:to_list(Map)])};
canonical(List) when is_list(List) ->
    {list, [canonical(V) || V <- List]};
canonical(Tuple) when is_tuple(Tuple) ->
    {tuple, [canonical(V) || V <- tuple_to_list(Tuple)]};
canonical(Value) ->
    Value.

secure_equal(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    0 =:=
        lists:foldl(
            fun({X, Y}, Acc) -> Acc bor (X bxor Y) end,
            0,
            lists:zip(binary_to_list(A), binary_to_list(B))
        );
secure_equal(_, _) ->
    false.

hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).
