-module(ecai_git_snapshot).

-export([
    pin_context/2,
    check_analysis/2
]).

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(MAX_GIT_OUTPUT_BYTES, 2097152).

pin_context(Context, Opts) when is_map(Context), is_map(Opts) ->
    Analysis = maps:get(analysis, Context, #{}),
    case check_analysis(Analysis, Opts) of
        {ok, Snapshot} ->
            Source = maps:get(source, Snapshot),
            BaseCommit = maps:get(base_commit, Snapshot),
            SourcePath = maps:get(source_path, Snapshot),
            Analysis1 = Analysis#{
                base_commit => BaseCommit,
                repo_path => SourcePath,
                source_sha256 => maps:get(source_sha256, Snapshot)
            },
            {ok, Context#{
                source => Source,
                analysis => Analysis1,
                base_commit => BaseCommit,
                source_path => SourcePath
            }};
        {error, _} = Error ->
            Error
    end.

check_analysis(Analysis, Opts) when is_map(Analysis), is_map(Opts) ->
    SourceName = maps:get(source_name, Analysis, undefined),
    LearnedHash = maps:get(source_sha256, Analysis, undefined),
    case snapshot_repository(Analysis, Opts) of
        {error, _} = Error ->
            Error;
        {ok, RepoRoot, SnapshotOpts} ->
            case resolve_base_commit(RepoRoot, SnapshotOpts) of
                {error, _} = Error ->
                    Error;
                {ok, BaseCommit} ->
                    case repo_relative_source(RepoRoot, SourceName) of
                        {error, Reason} ->
                            {error, #{
                                kind => Reason,
                                base_commit => BaseCommit,
                                source_name => SourceName
                            }};
                        {ok, RelPath} ->
                            check_base_source(
                                RepoRoot,
                                BaseCommit,
                                RelPath,
                                LearnedHash,
                                SnapshotOpts
                            )
                    end
            end
    end.

snapshot_repository(
    #{source_origin := canonical_repository} = Analysis,
    Opts
) ->
    case maps:get(base_commit, Analysis, undefined) of
        Commit when is_binary(Commit), byte_size(Commit) > 0 ->
            case ecai_source_repository:base_for_commit(Commit, Opts) of
                {ok, #{root := Root}} ->
                    {ok, path_to_list(Root), Opts#{base_commit => Commit}};
                {error, Reason} ->
                    {error, #{
                        kind => canonical_source_unavailable,
                        base_commit => Commit,
                        reason => Reason
                    }}
            end;
        _ ->
            {error, #{
                kind => canonical_base_commit_missing,
                source_name => maps:get(source_name, Analysis, undefined)
            }}
    end;
snapshot_repository(Analysis, Opts) ->
    SnapshotOpts =
        case {
            maps:is_key(base_commit, Opts),
            maps:get(base_commit, Analysis, undefined)
        } of
            {false, Commit}
              when is_binary(Commit), byte_size(Commit) > 0 ->
                Opts#{base_commit => Commit};
            _ ->
                Opts
        end,
    {ok, repo_root(Opts), SnapshotOpts}.

check_base_source(RepoRoot, BaseCommit, RelPath, LearnedHash, Opts) ->
    Timeout = command_timeout(Opts),
    Object = binary_to_list(BaseCommit) ++ ":" ++ RelPath,
    Exists = run_git(
        RepoRoot,
        ["cat-file", "-e", Object],
        Timeout
    ),
    case step_ok(Exists) of
        false ->
            {error, #{
                kind => source_not_in_base_commit,
                base_commit => BaseCommit,
                source_path => to_binary(RelPath),
                learned_sha256 => LearnedHash,
                git => compact_result(Exists)
            }};
        true ->
            Show = run_git(
                RepoRoot,
                ["show", Object],
                Timeout
            ),
            case Show of
                #{ok := true, output := Source} ->
                    BaseHash = sha256_hex(Source),
                    case hashes_equal(LearnedHash, BaseHash) of
                        true ->
                            {ok, #{
                                base_commit => BaseCommit,
                                source_path => to_binary(RelPath),
                                source_sha256 => BaseHash,
                                source => Source
                            }};
                        false ->
                            {error, #{
                                kind => source_base_mismatch,
                                base_commit => BaseCommit,
                                source_path => to_binary(RelPath),
                                learned_sha256 => LearnedHash,
                                base_sha256 => BaseHash
                            }}
                    end;
                _ ->
                    {error, #{
                        kind => cannot_read_source_from_base,
                        base_commit => BaseCommit,
                        source_path => to_binary(RelPath),
                        learned_sha256 => LearnedHash,
                        git => compact_result(Show)
                    }}
            end
    end.

resolve_base_commit(RepoRoot, Opts) ->
    Base0 = maps:get(base_commit, Opts, "HEAD"),
    Base = path_to_list(Base0),
    Result = run_git(
        RepoRoot,
        ["rev-parse", "--verify", "--end-of-options", Base ++ "^{commit}"],
        command_timeout(Opts)
    ),
    case Result of
        #{ok := true, output := Output} ->
            {ok, trim_binary(Output)};
        _ ->
            {error, #{
                kind => invalid_base_commit,
                requested_base => to_binary(Base0),
                git => compact_result(Result)
            }}
    end.

repo_relative_source(_RepoRoot, undefined) ->
    {error, source_name_missing};
repo_relative_source(RepoRoot0, SourceName0) ->
    RepoRoot = filename:absname(path_to_list(RepoRoot0)),
    SourceName = path_to_list(SourceName0),
    SourceAbs =
        case filename:pathtype(SourceName) of
            absolute -> filename:absname(SourceName);
            _ -> filename:absname(filename:join(RepoRoot, SourceName))
        end,
    RootParts = filename:split(RepoRoot),
    SourceParts = filename:split(SourceAbs),
    case lists:prefix(RootParts, SourceParts) andalso
         length(SourceParts) > length(RootParts) of
        false ->
            {error, source_outside_repository};
        true ->
            RelParts = lists:nthtail(length(RootParts), SourceParts),
            {ok, filename:join(RelParts)}
    end.

repo_root(Opts) ->
    filename:absname(path_to_list(maps:get(
        repo_root,
        Opts,
        application:get_env(ecai, code_repo_root, ".")
    ))).

command_timeout(Opts) ->
    case maps:get(
        command_timeout_ms,
        Opts,
        application:get_env(
            ecai, code_patch_command_timeout_ms, ?DEFAULT_TIMEOUT_MS
        )
    ) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_TIMEOUT_MS
    end.

run_git(RepoRoot, Args, Timeout) ->
    case os:find_executable("git") of
        false ->
            #{ok => false, error => executable_not_found};
        Exe ->
            Port = open_port(
                {spawn_executable, Exe},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", RepoRoot | Args]},
                    {cd, RepoRoot}
                ]
            ),
            collect_port(Port, <<>>, Timeout)
    end.

collect_port(Port, Acc0, Timeout) ->
    receive
        {Port, {data, Data}} ->
            Acc = append_bounded(Acc0, Data),
            collect_port(Port, Acc, Timeout);
        {Port, {exit_status, 0}} ->
            #{ok => true, output => Acc0};
        {Port, {exit_status, Status}} ->
            #{ok => false, exit_status => Status, output => Acc0}
    after Timeout ->
        try port_close(Port)
        catch
            _:_ -> ok
        end,
        #{ok => false, error => timeout, output => Acc0}
    end.

append_bounded(Acc, Data) ->
    Combined = <<Acc/binary, Data/binary>>,
    case byte_size(Combined) =< ?MAX_GIT_OUTPUT_BYTES of
        true ->
            Combined;
        false ->
            <<Prefix:?MAX_GIT_OUTPUT_BYTES/binary, _/binary>> = Combined,
            Prefix
    end.

compact_result(Result) when is_map(Result) ->
    maps:with([ok, exit_status, error, output], Result);
compact_result(Result) ->
    Result.

step_ok(#{ok := true}) -> true;
step_ok(_) -> false.

hashes_equal(A, B) when is_binary(A), is_binary(B) ->
    A =:= B;
hashes_equal(_, _) ->
    false.

sha256_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary(
        [io_lib:format("~2.16.0b", [Byte]) ||
         <<Byte>> <= crypto:hash(sha256, Bin)]
    ).

trim_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P);
path_to_list(P) when is_atom(P) -> atom_to_list(P).

to_binary(undefined) -> undefined;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
