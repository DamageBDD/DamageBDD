-module(ecai_repair_git).

%% Shell-free Git helpers used by the repair capsule and verifier.
-export([
    head/1,
    branch/1,
    changed_files/2,
    run/3,
    safe_join/2,
    relative/2
]).

-type path() :: file:filename_all().

-spec head(path()) -> {ok, binary()} | {error, term()}.
head(Repo) ->
    one_line(Repo, ["rev-parse", "HEAD"]).

-spec branch(path()) -> {ok, binary()} | {error, term()}.
branch(Repo) ->
    one_line(Repo, ["rev-parse", "--abbrev-ref", "HEAD"]).

-spec changed_files(path(), binary() | list()) -> {ok, [binary()]} | {error, term()}.
changed_files(Repo, Base0) ->
    Base = to_list(Base0),
    case run(Repo, ["diff", "--name-only", "--no-renames", Base, "--"], 30000) of
        {ok, Diff} ->
            case run(Repo, ["ls-files", "--others", "--exclude-standard"], 30000) of
                {ok, Untracked} ->
                    {ok, lists:usort(lines(Diff) ++ lines(Untracked))};
                Error -> Error
            end;
        Error -> Error
    end.

-spec run(path(), [binary() | list() | atom() | integer()], pos_integer()) ->
    {ok, binary()} | {error, term()}.
run(Repo0, Args0, Timeout) when is_integer(Timeout), Timeout > 0 ->
    Repo = to_list(Repo0),
    Args = [to_list(A) || A <- Args0],
    case os:find_executable("git") of
        false ->
            {error, git_not_found};
        Git ->
            try
                Port = open_port(
                    {spawn_executable, Git},
                    [
                        binary,
                        use_stdio,
                        stderr_to_stdout,
                        exit_status,
                        eof,
                        {args, ["-C", Repo | Args]}
                    ]
                ),
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                collect(Port, Deadline, [], undefined, false)
            catch
                Class:Reason:Stack ->
                    {error, {git_port_failed, Class, Reason, Stack}}
            end
    end.

-spec safe_join(path(), path()) -> {ok, file:filename()} | {error, term()}.
safe_join(Root0, Candidate0) ->
    Root = filename:absname(to_list(Root0)),
    Candidate = to_list(Candidate0),
    Full = case filename:pathtype(Candidate) of
        absolute -> filename:absname(Candidate);
        _ -> filename:absname(filename:join(Root, Candidate))
    end,
    case within(Root, Full) of
        true -> {ok, Full};
        false -> {error, {path_outside_repository, Candidate0}}
    end.

-spec relative(path(), path()) -> binary().
relative(Root0, Path0) ->
    Root = filename:absname(to_list(Root0)),
    Path = filename:absname(to_list(Path0)),
    Prefix = ensure_sep(Root),
    Rel = case lists:prefix(Prefix, ensure_sep_or_path(Path)) of
        true -> lists:nthtail(length(Prefix), Path);
        false when Path =:= Root -> ".";
        false -> Path
    end,
    unicode:characters_to_binary(Rel).

one_line(Repo, Args) ->
    case run(Repo, Args, 15000) of
        {ok, Output} ->
            case lines(Output) of
                [Line | _] -> {ok, Line};
                [] -> {error, empty_git_output}
            end;
        Error -> Error
    end.

collect(Port, Deadline, Acc, Status, Eof) ->
    case {Status, Eof} of
        {S, true} when is_integer(S) ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            case S of
                0 -> {ok, Output};
                _ -> {error, {git_exit, S, Output}}
            end;
        _ ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    ecai_otp_compat:catch_value(fun() -> port_close(Port) end),
                    {error, git_timeout};
                false ->
                    receive
                        {Port, {data, Data}} ->
                            collect(Port, Deadline, [Data | Acc], Status, Eof);
                        {Port, {exit_status, S}} ->
                            collect(Port, Deadline, Acc, S, Eof);
                        {Port, eof} ->
                            collect(Port, Deadline, Acc, Status, true);
                        {'EXIT', Port, Reason} ->
                            {error, {git_port_exit, Reason}}
                    after Remaining ->
                        ecai_otp_compat:catch_value(fun() -> port_close(Port) end),
                        {error, git_timeout}
                    end
            end
    end.

lines(Bin) ->
    [trim(Line) || Line <- binary:split(Bin, <<"\n">>, [global]), trim(Line) =/= <<>>].

trim(Bin) ->
    list_to_binary(string:trim(binary_to_list(Bin))).

within(Root, Full) ->
    Full =:= Root orelse lists:prefix(ensure_sep(Root), Full).

ensure_sep(Path) ->
    case lists:reverse(Path) of
        [$/ | _] -> Path;
        _ -> Path ++ "/"
    end.

ensure_sep_or_path(Path) -> Path.

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_atom(Value) -> atom_to_list(Value);
to_list(Value) when is_integer(Value) -> integer_to_list(Value).
