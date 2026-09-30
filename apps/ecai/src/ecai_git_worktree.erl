-module(ecai_git_worktree).

-export([filter_learning_files/3]).

%% By default the learner only consumes source that is both tracked by Git and
%% byte-for-byte clean relative to HEAD. This keeps learned source reproducible
%% by the patch verifier's immutable base commit.
%%
%% Overrides:
%%   {code_learning_include_dirty_files, true}
%%       Include all discovered files, restoring the legacy behaviour.
%%
%%   {code_learning_dirty_allowlist, ["path", "dir/"]}
%%       Explicitly allow selected dirty or untracked paths. Directory entries
%%       ending in "/" act as prefixes.

filter_learning_files(RepoRoot0, Files, Opts)
  when is_list(Files), is_map(Opts) ->
    RepoRoot = filename:absname(path_to_list(RepoRoot0)),
    case include_dirty_files(Opts) of
        true ->
            {ok, Files, []};
        false ->
            filter_clean_tracked(RepoRoot, Files, Opts)
    end.

filter_clean_tracked(RepoRoot, Files, Opts) ->
    case git_paths(
        RepoRoot,
        ["ls-files", "-z", "--"]
    ) of
        {error, _} = Error ->
            Error;
        {ok, TrackedPaths} ->
            case git_paths(
                RepoRoot,
                ["diff", "--name-only", "-z", "HEAD", "--"]
            ) of
                {error, _} = Error ->
                    Error;
                {ok, DirtyTrackedPaths} ->
                    Tracked = path_set(TrackedPaths),
                    DirtyTracked = path_set(DirtyTrackedPaths),
                    Allow = dirty_allowlist(Opts),
                    classify_files(
                        RepoRoot,
                        Files,
                        Tracked,
                        DirtyTracked,
                        Allow,
                        [],
                        []
                    )
            end
    end.

classify_files(
    _RepoRoot, [], _Tracked, _DirtyTracked, _Allow,
    Included0, Skipped0
) ->
    {ok, lists:reverse(Included0), lists:reverse(Skipped0)};
classify_files(
    RepoRoot, [File | Rest], Tracked, DirtyTracked, Allow,
    Included0, Skipped0
) ->
    case repo_relative(RepoRoot, File) of
        {error, Reason} ->
            classify_files(
                RepoRoot, Rest, Tracked, DirtyTracked, Allow,
                Included0,
                [
                    #{
                        path => to_binary(File),
                        reason => Reason
                    }
                    | Skipped0
                ]
            );
        {ok, RelPath} ->
            Explicit = allowed_dirty_path(RelPath, Allow),
            IsTracked = maps:is_key(RelPath, Tracked),
            IsDirty = maps:is_key(RelPath, DirtyTracked),
            case Explicit orelse (IsTracked andalso not IsDirty) of
                true ->
                    classify_files(
                        RepoRoot, Rest, Tracked, DirtyTracked, Allow,
                        [File | Included0], Skipped0
                    );
                false ->
                    Reason = case IsTracked of
                        true -> dirty_tracked;
                        false -> untracked_or_generated
                    end,
                    classify_files(
                        RepoRoot, Rest, Tracked, DirtyTracked, Allow,
                        Included0,
                        [
                            #{
                                path => RelPath,
                                reason => Reason
                            }
                            | Skipped0
                        ]
                    )
            end
    end.

include_dirty_files(Opts) ->
    maps:get(
        include_dirty_files,
        Opts,
        application:get_env(
            ecai,
            code_learning_include_dirty_files,
            false
        )
    ) =:= true.

dirty_allowlist(Opts) ->
    Value = maps:get(
        dirty_allowlist,
        Opts,
        application:get_env(
            ecai,
            code_learning_dirty_allowlist,
            []
        )
    ),
    case Value of
        Paths when is_list(Paths) ->
            [
                normalize_rel_path(Path)
             || Path <- Paths,
                valid_path_value(Path)
            ];
        _ ->
            []
    end.

valid_path_value(Path) when is_binary(Path) ->
    byte_size(Path) > 0;
valid_path_value(Path) when is_list(Path) ->
    Path =/= [];
valid_path_value(_) ->
    false.

allowed_dirty_path(_RelPath, []) ->
    false;
allowed_dirty_path(RelPath, [Allowed | Rest]) ->
    case allowed_path_match(RelPath, Allowed) of
        true -> true;
        false -> allowed_dirty_path(RelPath, Rest)
    end.

allowed_path_match(RelPath, Allowed) ->
    case binary:last(Allowed) of
        $/ ->
            binary:match(RelPath, Allowed) =:= {0, byte_size(Allowed)};
        _ ->
            RelPath =:= Allowed
    end.

repo_relative(RepoRoot0, File0) ->
    RepoRoot = filename:absname(path_to_list(RepoRoot0)),
    File = filename:absname(path_to_list(File0)),
    RepoParts = filename:split(RepoRoot),
    FileParts = filename:split(File),
    case lists:prefix(RepoParts, FileParts) of
        false ->
            {error, outside_repository};
        true ->
            RelParts = lists:nthtail(length(RepoParts), FileParts),
            case RelParts of
                [] ->
                    {error, repository_root_is_not_source_file};
                _ ->
                    {ok, normalize_rel_path(filename:join(RelParts))}
            end
    end.

git_paths(RepoRoot, Args) ->
    case git_command(RepoRoot, Args) of
        {ok, Output} ->
            {ok, nul_paths(Output)};
        {error, Reason} ->
            {error, {git_worktree_query_failed, Args, Reason}}
    end.

git_command(RepoRoot, Args) ->
    case os:find_executable("git") of
        false ->
            {error, git_not_found};
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", RepoRoot | Args]}
                ]
            ),
            collect_port(Port, <<>>)
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, Acc}}
    after 30000 ->
        try port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, timeout}
    end.

nul_paths(<<>>) ->
    [];
nul_paths(Output) when is_binary(Output) ->
    [
        normalize_rel_path(Path)
     || Path <- binary:split(Output, <<0>>, [global]),
        Path =/= <<>>
    ].

path_set(Paths) ->
    maps:from_list([{Path, true} || Path <- Paths]).

normalize_rel_path(Path0) ->
    Bin0 = to_binary(Path0),
    Bin1 = binary:replace(Bin0, <<"\\">>, <<"/">>, [global]),
    strip_dot_slash(Bin1).

strip_dot_slash(<<"./", Rest/binary>>) ->
    strip_dot_slash(Rest);
strip_dot_slash(Bin) ->
    Bin.

path_to_list(Path) when is_list(Path) ->
    Path;
path_to_list(Path) when is_binary(Path) ->
    binary_to_list(Path).

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    unicode:characters_to_binary(List).
