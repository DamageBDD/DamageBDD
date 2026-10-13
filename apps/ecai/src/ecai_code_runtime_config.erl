%% Runtime configuration for collaborative ECAI code learning and patch review.
%% Settings are durable, node-admin managed, and intentionally contain no credentials.
-module(ecai_code_runtime_config).

-compile({no_auto_import, [get/0]}).

-export([
    get/0,
    status/0,
    learning_config/0,
    repository_config/0,
    review_config/0,
    sharing_config/0,
    update/1,
    reload/0,
    learning_admission/0,
    prepare_learning_repo/0,
    repository_status/0,
    fetch/0,
    pull_ff/0,
    reviewer_allowed/1,
    publisher_allowed/1,
    add_reviewer/1,
    remove_reviewer/1,
    add_publisher/1,
    remove_publisher/1
]).

-define(SCHEMA, 1).
-define(GIT_TIMEOUT, 60000).

get() ->
    Base = defaults(),
    Config =
        case load_persisted() of
            {ok, Persisted} ->
                Candidate = deep_merge(Base, Persisted),
                case validate(Candidate) of
                    ok -> Candidate;
                    {error, _} -> Base
                end;
            _ -> Base
        end,
    _ = apply_env(Config),
    Config.

learning_config() -> maps:get(learning, get()).
repository_config() -> maps:get(repository, get()).
review_config() -> maps:get(review, get()).
sharing_config() -> maps:get(sharing, get()).

status() ->
    Config = get(),
    #{
        settings => Config,
        repository => repository_status(Config),
        learning_admission => learning_admission(Config)
    }.

update(Patch0) when is_map(Patch0) ->
    case normalize_patch(Patch0) of
        {ok, Patch} ->
            Current = get(),
            Candidate = deep_merge(Current, Patch),
            case validate(Candidate) of
                ok ->
                    case persist(Candidate) of
                        ok ->
                            ok = apply_env(Candidate),
                            _ = maybe_reload_learner(),
                            {ok, Candidate};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
update(_) ->
    {error, settings_object_required}.

reload() ->
    Config = get(),
    _ = maybe_reload_learner(),
    {ok, Config}.

learning_admission() ->
    learning_admission(get()).

prepare_learning_repo() ->
    Config = get(),
    Learning = maps:get(learning, Config),
    case maps:get(fetch_before_learning, Learning, false) of
        true ->
            case fetch(Config) of
                {ok, _} -> learning_admission(Config);
                {error, Reason} -> {error, {fetch_before_learning_failed, Reason}}
            end;
        false ->
            learning_admission(Config)
    end.

repository_status() ->
    repository_status(get()).

fetch() ->
    fetch(get()).

pull_ff() ->
    Config = get(),
    Repo = maps:get(repository, Config),
    Root = to_list(maps:get(working_root, Repo)),
    Remote = to_list(maps:get(remote, Repo)),
    WantedBranch = maps:get(branch, Repo),
    case {ecai_repair_git:branch(Root), clean_worktree(Root)} of
        {{ok, WantedBranch}, true} ->
            case ecai_repair_git:run(
                Root,
                ["-c", "core.askPass=/bin/false", "pull", "--ff-only", Remote, to_list(WantedBranch)],
                120000
            ) of
                {ok, Output} ->
                    {ok, (repository_status(Config))#{
                        operation => pull_ff,
                        output => trim_output(Output)
                    }};
                {error, _} = Error -> Error
            end;
        {{ok, WantedBranch}, false} ->
            {error, dirty_worktree};
        {{ok, Branch}, _} ->
            {error, {working_branch_mismatch, Branch, WantedBranch}};
        {Error, _} ->
            {error, {git_repository_unavailable, Error}}
    end.

reviewer_allowed(Account) ->
    role_allowed(Account, reviewers).

publisher_allowed(Account) ->
    role_allowed(Account, publishers).

add_reviewer(Account) -> role_update(reviewers, add, Account).
remove_reviewer(Account) -> role_update(reviewers, remove, Account).
add_publisher(Account) -> role_update(publishers, add, Account).
remove_publisher(Account) -> role_update(publishers, remove, Account).

%% ------------------------------------------------------------------
%% Defaults and persistence
%% ------------------------------------------------------------------

defaults() ->
    Root0 = application:get_env(ecai, code_repo_root, "."),
    Root = to_binary(filename:absname(to_list(Root0))),
    ReviewRoot = to_binary(filename:absname(to_list(application:get_env(ecai, code_review_repo_root, Root0)))),
    #{
        schema_version => ?SCHEMA,
        learning => #{
            enabled => application:get_env(ecai, code_learning_enabled, true) =:= true,
            branches => binary_list(application:get_env(ecai, code_learning_branches, [<<"main">>])),
            interval_ms => bounded_int(application:get_env(ecai, code_learning_interval_ms, 300000), 10000, 604800000, 300000),
            parallelism => default_parallelism(application:get_env(ecai, code_learning_parallelism, auto)),
            capacity_reserve => bounded_int(application:get_env(ecai, code_learning_capacity_reserve, 1), 0, 64, 1),
            require_clean_worktree => application:get_env(ecai, code_learning_require_clean_worktree, true) =:= true,
            fetch_before_learning => application:get_env(ecai, code_learning_fetch_before, false) =:= true
        },
        repository => #{
            working_root => Root,
            remote => to_binary(application:get_env(ecai, code_learning_remote, "origin")),
            branch => to_binary(application:get_env(ecai, code_learning_branch, "main"))
        },
        review => #{
            repo_root => ReviewRoot,
            remote => to_binary(application:get_env(ecai, code_review_remote, "origin")),
            branch_prefix => to_binary(application:get_env(ecai, code_review_branch_prefix, "ecai/reviews/")),
            push_enabled => application:get_env(ecai, code_review_push_enabled, false) =:= true,
            required_approvals => bounded_int(application:get_env(ecai, code_review_required_approvals, 1), 1, 5, 1),
            run_eunit => application:get_env(ecai, code_review_run_eunit, true) =:= true,
            run_ct => application:get_env(ecai, code_review_run_ct, false) =:= true,
            verify_timeout_ms => bounded_int(application:get_env(ecai, code_review_verify_timeout_ms, 600000), 30000, 3600000, 600000),
            reviewers => binary_list(application:get_env(ecai, code_review_accounts, [])),
            publishers => binary_list(application:get_env(ecai, code_publish_accounts, []))
        },
        sharing => #{
            enabled => application:get_env(ecai, code_learning_share_enabled, false) =:= true,
            directory => default_share_dir()
        }
    }.

config_file() ->
    case ecai_code_paths:state_root() of
        {ok, Root} -> {ok, filename:join([Root, "runtime", "code_admin_settings.json"])};
        {error, _} = Error -> Error
    end.

default_share_dir() ->
    case ecai_code_paths:state_root() of
        {ok, Root} -> to_binary(filename:join([Root, "git", "security", "learning-exchange"]));
        _ -> <<"">>
    end.

load_persisted() ->
    case config_file() of
        {ok, File} ->
            case file:read_file(File) of
                {ok, Bin} ->
                    try jsx:decode(Bin, [return_maps]) of
                        Map when is_map(Map) -> normalize_patch(Map);
                        _ -> {error, invalid_persisted_settings}
                    catch
                        _:_ -> {error, invalid_persisted_settings}
                    end;
                {error, enoent} -> {ok, #{}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

persist(Config) ->
    case config_file() of
        {ok, File} ->
            ok = filelib:ensure_dir(File),
            Tmp = File ++ ".tmp",
            Encoded = jsx:encode(json_safe(Config)),
            case file:write_file(Tmp, Encoded, [binary]) of
                ok ->
                    _ = file:change_mode(Tmp, 8#600),
                    case file:rename(Tmp, File) of
                        ok -> ok;
                        {error, _} = Error -> _ = file:delete(Tmp), Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

apply_env(Config) ->
    Learning = maps:get(learning, Config),
    Repo = maps:get(repository, Config),
    Review = maps:get(review, Config),
    Sharing = maps:get(sharing, Config),
    Pairs = [
        {code_repo_root, maps:get(working_root, Repo)},
        {code_learning_enabled, maps:get(enabled, Learning)},
        {code_learning_branches, maps:get(branches, Learning)},
        {code_learning_interval_ms, maps:get(interval_ms, Learning)},
        {code_learning_parallelism, maps:get(parallelism, Learning)},
        {code_learning_capacity_reserve, maps:get(capacity_reserve, Learning)},
        {code_learning_require_clean_worktree, maps:get(require_clean_worktree, Learning)},
        {code_learning_fetch_before, maps:get(fetch_before_learning, Learning)},
        {code_learning_remote, maps:get(remote, Repo)},
        {code_learning_branch, maps:get(branch, Repo)},
        {code_review_repo_root, maps:get(repo_root, Review)},
        {code_review_remote, maps:get(remote, Review)},
        {code_review_branch_prefix, maps:get(branch_prefix, Review)},
        {code_review_push_enabled, maps:get(push_enabled, Review)},
        {code_review_required_approvals, maps:get(required_approvals, Review)},
        {code_review_run_eunit, maps:get(run_eunit, Review)},
        {code_review_run_ct, maps:get(run_ct, Review)},
        {code_review_verify_timeout_ms, maps:get(verify_timeout_ms, Review)},
        {code_review_accounts, maps:get(reviewers, Review)},
        {code_publish_accounts, maps:get(publishers, Review)},
        {code_learning_share_enabled, maps:get(enabled, Sharing)},
        {code_learning_share_dir, maps:get(directory, Sharing)}
    ],
    lists:foreach(fun({Key, Value}) -> application:set_env(ecai, Key, Value) end, Pairs),
    ok.

maybe_reload_learner() ->
    case whereis(ecai_codebase_learner) of
        undefined -> ok;
        _ ->
            try ecai_codebase_learner:reload_runtime() of
                _ -> ok
            catch
                _:_ -> ok
            end
    end.

%% ------------------------------------------------------------------
%% Repository operations and policy
%% ------------------------------------------------------------------

repository_status(Config) ->
    Repo = maps:get(repository, Config),
    RootBin = maps:get(working_root, Repo),
    Root = to_list(RootBin),
    RemoteBin = maps:get(remote, Repo),
    Remote = to_list(RemoteBin),
    Head = value(ecai_repair_git:head(Root)),
    Branch = value(ecai_repair_git:branch(Root)),
    Dirty = not clean_worktree(Root),
    FetchUrl = remote_url(Root, Remote, false),
    PushUrl = remote_url(Root, Remote, true),
    Canonical =
        case ecai_source_repository:status(#{repo_root => RootBin}) of
            {ok, SourceStatus} -> SourceStatus;
            {error, Reason} -> #{error => Reason}
        end,
    #{
        working_root => RootBin,
        head => Head,
        branch => Branch,
        dirty => Dirty,
        configured_branch => maps:get(branch, Repo),
        remote => RemoteBin,
        fetch_url => sanitize_remote_url(FetchUrl),
        push_url => sanitize_remote_url(PushUrl),
        canonical_source => Canonical
    }.

fetch(Config) ->
    Repo = maps:get(repository, Config),
    Root = to_list(maps:get(working_root, Repo)),
    Remote = to_list(maps:get(remote, Repo)),
    case ecai_repair_git:run(
        Root,
        ["-c", "core.askPass=/bin/false", "fetch", "--prune", Remote],
        ?GIT_TIMEOUT
    ) of
        {ok, Output} ->
            {ok, (repository_status(Config))#{
                operation => fetch,
                output => trim_output(Output)
            }};
        {error, _} = Error -> Error
    end.

learning_admission(Config) ->
    Learning = maps:get(learning, Config),
    case maps:get(enabled, Learning) of
        false -> {error, code_learning_disabled};
        true ->
            Repo = maps:get(repository, Config),
            Root = to_list(maps:get(working_root, Repo)),
            case {ecai_repair_git:branch(Root), ecai_repair_git:head(Root)} of
                {{ok, <<"HEAD">>}, _} -> {error, detached_head_not_allowed};
                {{ok, Branch}, {ok, Head}} ->
                    Allowed = maps:get(branches, Learning, []),
                    BranchAllowed = Allowed =:= [] orelse lists:member(Branch, Allowed),
                    CleanAllowed =
                        maps:get(require_clean_worktree, Learning, true) =:= false orelse
                            clean_worktree(Root),
                    case {BranchAllowed, CleanAllowed} of
                        {true, true} -> {ok, #{branch => Branch, head => Head, working_root => to_binary(Root), allowed_branches => Allowed}};
                        {false, _} -> {error, {code_learning_branch_not_allowed, Branch, Allowed}};
                        {_, false} -> {error, dirty_worktree}
                    end;
                {BranchError, HeadError} ->
                    {error, {git_repository_unavailable, BranchError, HeadError}}
            end
    end.

clean_worktree(Root) ->
    case ecai_repair_git:run(Root, ["status", "--porcelain=v1"], 15000) of
        {ok, Output} -> trim_output(Output) =:= <<>>;
        _ -> false
    end.

remote_url(Root, Remote, Push) ->
    Args =
        case Push of
            true -> ["remote", "get-url", "--push", Remote];
            false -> ["remote", "get-url", Remote]
        end,
    value(ecai_repair_git:run(Root, Args, 15000)).

sanitize_remote_url(undefined) -> undefined;
sanitize_remote_url(Bin) when is_binary(Bin) ->
    case binary:match(Bin, <<"://">>) of
        nomatch -> Bin;
        {Pos, 3} ->
            PrefixLen = Pos + 3,
            Prefix = binary:part(Bin, 0, PrefixLen),
            Rest = binary:part(Bin, PrefixLen, byte_size(Bin) - PrefixLen),
            HostPart = hd(binary:split(Rest, <<"/">>)),
            case binary:match(HostPart, <<"@">>) of
                nomatch -> Bin;
                {At, 1} ->
                    TailOffset = At + 1,
                    <<Prefix/binary, (binary:part(Rest, TailOffset, byte_size(Rest) - TailOffset))/binary>>
            end
    end;
sanitize_remote_url(Value) -> Value.

%% ------------------------------------------------------------------
%% Review roles
%% ------------------------------------------------------------------

role_allowed(Account, Key) ->
    ecai_node_admin:can_manage_code(Account) andalso
        case maps:get(Key, maps:get(review, get()), []) of
            [] -> true;
            Accounts -> lists:member(Account, Accounts)
        end.

role_update(Key, Action, Account0) ->
    Account = to_binary(Account0),
    case valid_account(Account) of
        false -> {error, invalid_account};
        true when Action =:= add ->
            case ecai_node_admin:can_manage_code(Account) of
                false -> {error, account_is_not_code_admin};
                true ->
                    Review = maps:get(review, get()),
                    Accounts = lists:usort([Account | maps:get(Key, Review, [])]),
                    update(#{review => #{Key => Accounts}})
            end;
        true ->
            Review = maps:get(review, get()),
            Accounts = lists:delete(Account, maps:get(Key, Review, [])),
            update(#{review => #{Key => Accounts}})
    end.

valid_account(Account) -> is_binary(Account) andalso byte_size(Account) > 0 andalso byte_size(Account) =< 256.

%% ------------------------------------------------------------------
%% Validation / normalization
%% ------------------------------------------------------------------

normalize_patch(Map) ->
    try
        Patch0 = #{},
        Patch1 = maybe_section(learning, Map, Patch0),
        Patch2 = maybe_section(repository, Map, Patch1),
        Patch3 = maybe_section(review, Map, Patch2),
        Patch4 = maybe_section(sharing, Map, Patch3),
        {ok, Patch4}
    catch
        throw:Reason -> {error, Reason}
    end.

maybe_section(Name, Source, Acc) ->
    case lookup(Name, Source) of
        missing -> Acc;
        Value when is_map(Value) -> Acc#{Name => normalize_section(Name, Value)};
        _ -> throw({invalid_settings_section, Name})
    end.

normalize_section(learning, Map) ->
    section_values(Map, [enabled, branches, interval_ms, parallelism, capacity_reserve, require_clean_worktree, fetch_before_learning]);
normalize_section(repository, Map) ->
    section_values(Map, [working_root, remote, branch]);
normalize_section(review, Map) ->
    section_values(Map, [repo_root, remote, branch_prefix, push_enabled, required_approvals, run_eunit, run_ct, verify_timeout_ms, reviewers, publishers]);
normalize_section(sharing, Map) ->
    section_values(Map, [enabled, directory]).

section_values(Map, Keys) ->
    lists:foldl(
        fun(Key, Acc) ->
            case lookup(Key, Map) of
                missing -> Acc;
                Value -> Acc#{Key => normalize_value(Key, Value)}
            end
        end,
        #{},
        Keys
    ).

normalize_value(Key, Value) when Key =:= enabled; Key =:= require_clean_worktree; Key =:= fetch_before_learning;
                                 Key =:= push_enabled; Key =:= run_eunit; Key =:= run_ct ->
    case Value of true -> true; false -> false; _ -> throw({invalid_boolean, Key}) end;
normalize_value(branches, Value) when is_list(Value) -> binary_list(Value);
normalize_value(reviewers, Value) when is_list(Value) -> binary_list(Value);
normalize_value(publishers, Value) when is_list(Value) -> binary_list(Value);
normalize_value(parallelism, Value) -> normalize_parallelism(Value);
normalize_value(Key, Value) when Key =:= interval_ms; Key =:= capacity_reserve; Key =:= required_approvals; Key =:= verify_timeout_ms ->
    case is_integer(Value) of true -> Value; false -> throw({invalid_integer, Key}) end;
normalize_value(Key, Value) when Key =:= working_root; Key =:= repo_root; Key =:= directory; Key =:= remote; Key =:= branch; Key =:= branch_prefix ->
    to_binary(Value).

validate(Config) ->
    Learning = maps:get(learning, Config),
    Repo = maps:get(repository, Config),
    Review = maps:get(review, Config),
    Sharing = maps:get(sharing, Config),
    Checks = [
        valid_range(maps:get(interval_ms, Learning), 10000, 604800000, interval_ms),
        valid_parallelism(maps:get(parallelism, Learning)),
        valid_range(maps:get(capacity_reserve, Learning), 0, 64, capacity_reserve),
        valid_list(maps:get(branches, Learning), fun valid_branch/1, branches),
        valid_path(maps:get(working_root, Repo), working_root),
        valid_remote(maps:get(remote, Repo), repository_remote),
        valid_branch(maps:get(branch, Repo), repository_branch),
        valid_path(maps:get(repo_root, Review), review_repo_root),
        valid_remote(maps:get(remote, Review), review_remote),
        valid_prefix(maps:get(branch_prefix, Review)),
        valid_range(maps:get(required_approvals, Review), 1, 5, required_approvals),
        valid_range(maps:get(verify_timeout_ms, Review), 30000, 3600000, verify_timeout_ms),
        valid_role_list(maps:get(reviewers, Review), reviewers),
        valid_role_list(maps:get(publishers, Review), publishers),
        valid_sharing(Sharing)
    ],
    first_error(Checks).

valid_range(N, Min, Max, _Key) when is_integer(N), N >= Min, N =< Max -> ok;
valid_range(_, _, _, Key) -> {error, {invalid_range, Key}}.
valid_parallelism(auto) -> ok;
valid_parallelism(N) when is_integer(N), N >= 1, N =< 64 -> ok;
valid_parallelism(_) -> {error, invalid_parallelism}.
valid_list(List, Fun, _Key) when is_list(List) ->
    case lists:all(Fun, List) andalso length(List) =< 64 of true -> ok; false -> {error, invalid_list} end;
valid_list(_, _, Key) -> {error, {invalid_list, Key}}.
valid_role_list(List, Key) when is_list(List) ->
    case valid_list(List, fun valid_account/1, Key) of
        ok ->
            case lists:all(fun ecai_node_admin:can_manage_code/1, List) of
                true -> ok;
                false -> {error, {unauthorized_code_admin_in_role, Key}}
            end;
        {error, _} = Error -> Error
    end;
valid_role_list(_, Key) -> {error, {invalid_list, Key}}.
valid_path(Bin, _Key) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 4096 -> ok;
valid_path(_, Key) -> {error, {invalid_path, Key}}.
valid_sharing(#{enabled := true, directory := <<>>}) -> {error, sharing_directory_required};
valid_sharing(#{directory := Bin}) -> valid_directory(Bin);
valid_sharing(_) -> {error, invalid_sharing_settings}.
valid_directory(<<>>) -> ok;
valid_directory(Bin) -> valid_path(Bin, sharing_directory).
valid_remote(Bin, _Key) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 128 ->
    case re:run(Bin, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) of match -> ok; _ -> {error, invalid_remote} end;
valid_remote(_, Key) -> {error, {invalid_remote, Key}}.
valid_branch(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 128 ->
    case re:run(Bin, <<"^[A-Za-z0-9][A-Za-z0-9._/-]*$">>, [{capture, none}]) of
        match -> not_bad_ref(Bin);
        _ -> false
    end;
valid_branch(_) -> false.
valid_branch(Bin, _Key) -> case valid_branch(Bin) of true -> ok; false -> {error, invalid_branch} end.
valid_prefix(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 128 ->
    case valid_branch(<<Bin/binary, "x">>) of true -> ok; false -> {error, invalid_review_branch_prefix} end;
valid_prefix(_) -> {error, invalid_review_branch_prefix}.
not_bad_ref(Bin) ->
    binary:match(Bin, <<"..">>) =:= nomatch andalso
        binary:match(Bin, <<"//">>) =:= nomatch andalso
        binary:last(Bin) =/= $/.
first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error;
first_error([false | _]) -> {error, invalid_settings}.

lookup(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            Bin = atom_to_binary(Key, utf8),
            case maps:find(Bin, Map) of {ok, Value} -> Value; error -> missing end
    end.

deep_merge(Base, Patch) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            case {maps:get(Key, Acc, undefined), Value} of
                {Existing, V} when is_map(Existing), is_map(V) -> Acc#{Key => maps:merge(Existing, V)};
                _ -> Acc#{Key => Value}
            end
        end,
        Base,
        Patch
    ).

default_parallelism(Value) ->
    try normalize_parallelism(Value) of
        Result -> Result
    catch
        throw:_ -> auto
    end.

normalize_parallelism(<<"auto">>) -> auto;
normalize_parallelism("auto") -> auto;
normalize_parallelism(auto) -> auto;
normalize_parallelism(N) when is_integer(N) -> N;
normalize_parallelism(_) -> throw(invalid_parallelism).

bounded_int(N, Min, Max, _Default) when is_integer(N), N >= Min, N =< Max -> N;
bounded_int(_, _, _, Default) -> Default.

binary_list(List) when is_list(List) ->
    lists:usort([to_binary(V) || V <- List, to_binary(V) =/= <<>>]);
binary_list(_) -> [].

value({ok, V}) -> trim_output(V);
value(_) -> undefined.

trim_output(Bin) when is_binary(Bin) -> unicode:characters_to_binary(string:trim(binary_to_list(Bin)));
trim_output(Value) -> to_binary(Value).

to_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
to_list(List) when is_list(List) -> List;
to_list(Atom) when is_atom(Atom) -> atom_to_list(Atom);
to_list(Value) -> io_lib:format("~0tp", [Value]).

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Int) when is_integer(Int) -> integer_to_binary(Int);
to_binary(undefined) -> <<>>;
to_binary(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).

json_safe(Map) when is_map(Map) -> maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(auto) -> <<"auto">>;
json_safe(undefined) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Tuple) when is_tuple(Tuple) -> to_binary(Tuple);
json_safe(V) -> V.
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_binary(K) -> K;
json_key(K) -> to_binary(K).
