%%%-------------------------------------------------------------------
%%% steps_docker.erl
%%%   Docker BDD steps using erlexec and macro-defined phrases
%%%-------------------------------------------------------------------
-module(steps_docker).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("damage.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-export([step/6]).

%% erlfmt:ignore-begin

%% ===== Phrase Macros =========================================================

%% Cleanup / housekeeping
-define(GIVEN_UNUSED_SINCE,
        ["the system has unused Docker containers or resources since", Relative]).
-define(WHEN_CLEANUP_UNUSED_SINCE,
        ["I clean up all unused Docker containers, images, volumes and networks since",
         Relative]).
-define(THEN_NO_UNUSED_OLDER_THAN,
        ["the Docker system should have no unused resources older than", Relative]).

%% Build an image from an inline Dockerfile
-define(WHEN_BUILD_IMAGE_FROM_INLINE_DOCKERFILE,
        ["I build docker image", Image, "from this Dockerfile"]).
-define(WHEN_BUILD_IMAGE_FROM_DOCKERFILE,
        ["I build an image from Dockerfile at", Src,"as tag", Tag]).

-define(WHEN_BUILD_IMAGE_FROM_DOCKERFILE_PARAMS,
  ["I build an image from Dockerfile at", Src,
    "as tag", Tag,
    "with params", Params]).

-define(THEN_COPY_FILE_FROM_CONTAINER_TO_IPFS_STORE_HASH,
        ["I copy file", PathGlob, "from the container to ipfs and store the hash in", Var]).

-define(RUN_DOCKER_IMAGE_TAGGED,
    ["I run docker image tagged", Tag]).
-define(DOCKER_LOOP_TIMEOUT, infinity).
%% erlfmt:ignore-end

%% ===== Types / spec ==========================================================
-spec step(
    proplists:proplist(),
    map(),
    binary(),
    integer(),
    [string() | binary()],
    iodata()
) -> map().

%% ===== Step clauses ==========================================================

%% ---------------------------------------------------------------------------
%% Given: mark a relative "since" time for docker cleanup
%%   Given the system has unused Docker containers or resources since "3 days ago"
%% ---------------------------------------------------------------------------
step(_Config, Context, <<"Given">>, _N, ?GIVEN_UNUSED_SINCE, _Raw) ->
    steps_utils:ensure_admin(Context),
    {ok, ISODate} = relative_string_to_date(Relative),
    ?LOG_NOTICE("Checking for Docker resources older than ~s", [ISODate]),
    Context#{since => ISODate};
%% ---------------------------------------------------------------------------
%% When: prune unused docker resources since relative time
%%   When I clean up all unused Docker containers, images, volumes and networks
%%   since "3 days ago"
%% ---------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?WHEN_CLEANUP_UNUSED_SINCE, _Raw) ->
    steps_utils:ensure_admin(Context),
    {ok, ISODate} = relative_string_to_date(Relative),
    Args = [
        "system",
        "prune",
        "-a",
        "--force",
        "--filter",
        "until=" ++ ISODate
    ],
    Ctx1 = run_docker(Config, Args, Context),
    ?LOG_NOTICE("Docker cleanup command executed for resources before ~s", [ISODate]),
    Ctx1#{since => ISODate};
%% ---------------------------------------------------------------------------
%% Then: assert that no unused resources older than relative time remain
%%   Then the Docker system should have no unused resources older than "3 days ago"
%% ---------------------------------------------------------------------------
step(Config, Context, <<"Then">>, _N, ?THEN_NO_UNUSED_OLDER_THAN, _Raw) ->
    steps_utils:ensure_admin(Context),
    {ok, ISODate} = relative_string_to_date(Relative),
    Args = [
        "ps",
        "-a",
        "--filter",
        "status=exited",
        "--filter",
        "until=" ++ ISODate,
        "--format",
        "{{.ID}}"
    ],
    Ctx1 = run_docker(Config, Args, Context),
    case maps:is_key(fail, Ctx1) of
        true ->
            %% Preserve the actual Docker failure; stderr is not a list of IDs.
            Ctx1;
        false ->
            case cmd_stdout(Ctx1) of
                <<>> ->
                    Ctx1;
                Bin ->
                    Trimmed = string:trim(binary_to_list(Bin)),
                    case Trimmed of
                        "" ->
                            Ctx1;
                        _ ->
                            ?LOG_ERROR("Docker cleanup left unused containers behind: ~s", [Trimmed]),
                            maps:put(
                                fail,
                                damage_utils:strf(
                                    "Docker cleanup completed but unused containers still remain: ~s. "
                                    "Inspect them with `docker ps -a`; they may still be in use or outside "
                                    "the requested age filter.",
                                    [Trimmed]
                                ),
                                Ctx1
                            )
                    end
            end
    end;
%% ---------------------------------------------------------------------------
%% When: build a docker image from an inline Dockerfile body
%%   When I build docker image "damagebdd/mint22-inline:latest" from this Dockerfile
%%   """
%%   FROM debian:12-slim
%%   RUN apt-get update && apt-get install -y curl
%%   CMD ["bash"]
%%   """
%% ---------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?WHEN_BUILD_IMAGE_FROM_INLINE_DOCKERFILE, Raw) ->
    steps_utils:ensure_admin(Context),
    build_image_from_inline_dockerfile(Config, Image, Raw, Context);
step(Config, Context, <<"When">>, _N, ?WHEN_BUILD_IMAGE_FROM_DOCKERFILE, _Raw) ->
    build_image_from_dockerfile(Config, Src, Tag, <<>>, undefined, Context);
step(Config, Context, <<"When">>, _N, ?WHEN_BUILD_IMAGE_FROM_DOCKERFILE_PARAMS, _Raw) ->
    build_image_from_dockerfile(Config, Src, Tag, Params, undefined, Context);
step(Config, Context, Kw, _N, ?THEN_COPY_FILE_FROM_CONTAINER_TO_IPFS_STORE_HASH, _Raw) when
    Kw =:= <<"Then">>; Kw =:= <<"And">>; Kw =:= <<"But">>
->
    steps_utils:ensure_admin(Context),
    copy_file_from_container_to_ipfs(Config, Context, PathGlob, Var);
step(Config, Context, <<"Then">>, _N, ?RUN_DOCKER_IMAGE_TAGGED, ScriptBin) ->
    run_docker_tagged(Config, Tag, ScriptBin, Context).

run_docker_tagged(Config, Tag0, ScriptBin0, Ctx0) ->
    steps_utils:ensure_admin(Ctx0),
    Tag = require_docker_ref(Tag0),
    ScriptBin = to_binary(ScriptBin0),

    WorkDir = filename:absname(docker_workdir(Config)),
    OutDir = filename:join(WorkDir, "out"),

    ok = ensure_dir(WorkDir),
    ok = ensure_dir(OutDir),

    %% The Gherkin docstring is intentionally executable *inside the container*.
    %% Never interpolate it into a host shell command. Write it to a file and
    %% bind-mount that file read-only into the container.
    ScriptPath = filename:join(WorkDir, "script-" ++ unique_stage_id() ++ ".sh"),
    case file:write_file(ScriptPath, ScriptBin, [binary]) of
        ok ->
            ok;
        {error, Reason} ->
            throw(
                damage_utils:strf(
                    "Docker step could not write the container script to ~s: ~p. "
                    "Check that the DamageBDD run directory exists, is writable, and has free disk space.",
                    [ScriptPath, Reason]
                )
            )
    end,

    ContainerName = unique_container_name(),
    OutMount = OutDir ++ ":/out/",
    ScriptMount = ScriptPath ++ ":/tmp/damagebdd-script.sh:ro",

    Args = [
        "run",
        "--network=host",
        "--name",
        binary_to_list(ContainerName),
        "--user",
        "damage",
        "--security-opt",
        "no-new-privileges:true",
        "--cap-drop",
        "ALL",
        "-v",
        OutMount,
        "-v",
        ScriptMount,
        "-w",
        "/opt/workspace",
        binary_to_list(Tag),
        "/bin/sh",
        "/tmp/damagebdd-script.sh"
    ],

    ?LOG_DEBUG(
        "Docker run image=~p container=~p script_path=~p",
        [Tag, ContainerName, ScriptPath]
    ),
    Ctx1 =
        try
            run_docker(Config, Args, Ctx0)
        after
            %% Keep the bind source path present while the stopped container is
            %% retained.  `docker cp` may remount the stopped container and Docker
            %% expects every recorded bind source to still exist with the same
            %% type.  Deleting this file here can make a later `docker cp` fail
            %% with e.g. `mkdirat tmp/damagebdd-script.sh: file exists`.
            %%
            %% Scrub the contents immediately instead: the executable build script
            %% is not retained, but the empty regular file keeps the bind mount
            %% valid until the run directory/container is cleaned up.
            scrub_script_file(ScriptPath)
        end,

    maps:merge(Ctx1, #{
        docker_workdir => WorkDir,
        docker_outdir => OutDir,
        docker_script_path => ScriptPath,
        docker_container_name => ContainerName,
        docker_container => ContainerName
    }).

scrub_script_file(ScriptPath) ->
    case file:write_file(ScriptPath, <<>>, [binary]) of
        ok ->
            ok;
        {error, Reason} ->
            %% Do not mask the Docker result if cleanup itself fails.
            ?LOG_WARNING(
                "Unable to scrub Docker script bind source ~s: ~p",
                [ScriptPath, Reason]
            ),
            ok
    end.

unique_container_name() ->
    Enc = base64:encode(crypto:strong_rand_bytes(9)),
    Safe = binary:replace(binary:replace(Enc, <<"/">>, <<"_">>, [global]), <<"+">>, <<"-">>, [
        global
    ]),
    <<"damagebdd-", Safe/binary>>.

build_image_from_dockerfile(Config, Src, Tag, Params, ContextRel0, Ctx0) ->
    steps_utils:ensure_admin(Ctx0),
    WorkDir = docker_workdir(Config),
    ok = ensure_dir(WorkDir),

    %% 1) Fetch Dockerfile contents. Do not let a failed URL/IPFS fetch turn
    %% into an opaque badmatch.
    case fetch_dockerfile(Src) of
        {ok, DockerfileBin} ->
            build_image_from_dockerfile_bin(
                Config,
                Src,
                Tag,
                Params,
                ContextRel0,
                WorkDir,
                DockerfileBin,
                Ctx0
            );
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Unable to load Dockerfile from ~p: ~p. "
                    "If this is a URL, check reachability and the HTTP status. "
                    "If this is an IPFS CID, check that the configured IPFS service can retrieve it.",
                    [Src, Reason]
                ),
                Ctx0
            );
        Other ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Unable to load Dockerfile from ~p: unexpected response ~p.",
                    [Src, Other]
                ),
                Ctx0
            )
    end.

build_image_from_dockerfile_bin(
    Config, _Src, Tag0, Params0, ContextRel0, WorkDir0, DockerfileBin, Ctx0
) ->
    Tag = require_docker_ref(Tag0),
    WorkDir = filename:absname(WorkDir0),
    DockerfilePath = filename:join(WorkDir, "Dockerfile"),

    case parse_docker_build_params(Params0) of
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Unsafe or invalid Docker build parameters: ~p. "
                    "Only explicitly allowed build flags are accepted.",
                    [Reason]
                ),
                Ctx0
            );
        {ok, ParamArgs} ->
            case safe_build_context(WorkDir, ContextRel0) of
                {error, Reason} ->
                    maps:put(
                        fail,
                        damage_utils:strf("Invalid Docker build context: ~p", [Reason]),
                        Ctx0
                    );
                {ok, ContextDir} ->
                    case file:write_file(DockerfilePath, DockerfileBin, [binary]) of
                        ok ->
                            Args =
                                [
                                    "build",
                                    "--network=host",
                                    "-f",
                                    DockerfilePath,
                                    "-t",
                                    binary_to_list(Tag)
                                ] ++
                                    ParamArgs ++
                                    [ContextDir],
                            Ctx1 = run_docker(Config, Args, Ctx0),
                            maps:put(docker_image_tag, Tag, Ctx1);
                        {error, Reason} ->
                            maps:put(
                                fail,
                                damage_utils:strf(
                                    "Docker build could not write ~s: ~p. "
                                    "Check run-directory permissions and available disk space.",
                                    [DockerfilePath, Reason]
                                ),
                                Ctx0
                            )
                    end
            end
    end.

require_docker_ref(Ref0) ->
    Ref = to_binary(Ref0),
    %% This intentionally validates a conservative subset of Docker references.
    %% It prevents whitespace/control characters and keeps malformed values away
    %% from Docker even though argv execution already prevents shell injection.
    case
        re:run(
            Ref,
            <<"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$">>,
            [{capture, none}]
        )
    of
        match ->
            Ref;
        nomatch ->
            throw(damage_utils:strf("Invalid Docker image reference: ~p", [Ref]))
    end.

safe_build_context(WorkDir0, ContextRel0) ->
    WorkDir = filename:absname(WorkDir0),
    case filelib:is_dir(WorkDir) of
        true ->
            safe_build_context_rel(WorkDir, ContextRel0);
        false ->
            {error, {workdir_not_directory, WorkDir}}
    end.

safe_build_context_rel(WorkDir, undefined) ->
    {ok, WorkDir};
safe_build_context_rel(WorkDir, Rel0) ->
    Rel = normalize_exec_arg(Rel0),
    case filename:pathtype(Rel) of
        absolute ->
            {error, absolute_context_not_allowed};
        _ ->
            %% safe_relative_path/2 is symlink-aware. In addition to normal
            %% ".." traversal, reject any symlink within Rel that resolves
            %% above WorkDir.
            case filelib:safe_relative_path(Rel, WorkDir) of
                unsafe ->
                    {error, context_escapes_workdir};
                SafeRel ->
                    Candidate =
                        case SafeRel of
                            [] ->
                                WorkDir;
                            _ ->
                                filename:absname(filename:join(WorkDir, SafeRel))
                        end,
                    case filelib:is_dir(Candidate) of
                        true ->
                            {ok, Candidate};
                        false ->
                            {error, {context_not_directory, Candidate}}
                    end
            end
    end.

parse_docker_build_params(undefined) ->
    {ok, []};
parse_docker_build_params(<<>>) ->
    {ok, []};
parse_docker_build_params([]) ->
    {ok, []};
parse_docker_build_params(Params0) ->
    Params = normalize_exec_arg(Params0),
    case split_cli_args(Params) of
        {ok, Args} ->
            validate_docker_build_args(Args);
        Error ->
            Error
    end.

%% Parse shell-like quoting only as data. No expansion, command substitution,
%% globbing, variable expansion, redirections, or shell execution occurs.
split_cli_args(Input) when is_list(Input) ->
    split_cli_args(Input, unquoted, [], [], false).

split_cli_args([], unquoted, Current, Acc, InToken) ->
    {ok, lists:reverse(finish_cli_token(Current, Acc, InToken))};
split_cli_args([], Quote, _Current, _Acc, _InToken) ->
    {error, {unterminated_quote, Quote}};
split_cli_args([$\\], _Quote, _Current, _Acc, _InToken) ->
    {error, trailing_escape};
split_cli_args([$\\, C | Rest], unquoted, Current, Acc, _InToken) ->
    split_cli_args(Rest, unquoted, [C | Current], Acc, true);
split_cli_args([$\\, C | Rest], double, Current, Acc, _InToken) ->
    split_cli_args(Rest, double, [C | Current], Acc, true);
split_cli_args([$' | Rest], unquoted, Current, Acc, _InToken) ->
    split_cli_args(Rest, single, Current, Acc, true);
split_cli_args([$' | Rest], single, Current, Acc, InToken) ->
    split_cli_args(Rest, unquoted, Current, Acc, InToken);
split_cli_args([$" | Rest], unquoted, Current, Acc, _InToken) ->
    split_cli_args(Rest, double, Current, Acc, true);
split_cli_args([$" | Rest], double, Current, Acc, InToken) ->
    split_cli_args(Rest, unquoted, Current, Acc, InToken);
split_cli_args([C | Rest], unquoted, Current, Acc, InToken) when
    C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n
->
    Acc1 = finish_cli_token(Current, Acc, InToken),
    split_cli_args(Rest, unquoted, [], Acc1, false);
split_cli_args([C | Rest], Quote, Current, Acc, _InToken) ->
    split_cli_args(Rest, Quote, [C | Current], Acc, true).

finish_cli_token(_Current, Acc, false) ->
    Acc;
finish_cli_token(Current, Acc, true) ->
    [lists:reverse(Current) | Acc].

validate_docker_build_args(Args) ->
    validate_docker_build_args(Args, []).

validate_docker_build_args([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_docker_build_args(["--build-arg", Value | Rest], Acc) ->
    case validate_build_arg(Value) of
        ok -> validate_docker_build_args(Rest, [Value, "--build-arg" | Acc]);
        Error -> Error
    end;
validate_docker_build_args([Arg | Rest], Acc) ->
    case string:prefix(Arg, "--build-arg=") of
        nomatch ->
            validate_safe_build_flag(Arg, Rest, Acc);
        Value ->
            case validate_build_arg(Value) of
                ok -> validate_docker_build_args(Rest, [Arg | Acc]);
                Error -> Error
            end
    end.

validate_safe_build_flag("--pull", Rest, Acc) ->
    validate_docker_build_args(Rest, ["--pull" | Acc]);
validate_safe_build_flag("--no-cache", Rest, Acc) ->
    validate_docker_build_args(Rest, ["--no-cache" | Acc]);
validate_safe_build_flag("--target", [Value | Rest], Acc) ->
    validate_named_value(target, Value, Rest, Acc);
validate_safe_build_flag("--platform", [Value | Rest], Acc) ->
    validate_named_value(platform, Value, Rest, Acc);
validate_safe_build_flag("--label", [Value | Rest], Acc) ->
    case validate_assignment(Value) of
        ok -> validate_docker_build_args(Rest, [Value, "--label" | Acc]);
        Error -> Error
    end;
validate_safe_build_flag("--progress", [Value | Rest], Acc) ->
    case lists:member(Value, ["auto", "plain", "tty", "rawjson"]) of
        true -> validate_docker_build_args(Rest, [Value, "--progress" | Acc]);
        false -> {error, {invalid_progress, Value}}
    end;
validate_safe_build_flag(Flag, _Rest, _Acc) ->
    {error, {unsupported_build_parameter, Flag}}.

validate_named_value(Name, Value, Rest, Acc) ->
    case
        re:run(
            to_binary(Value),
            <<"^[A-Za-z0-9][A-Za-z0-9._/,:+-]*$">>,
            [{capture, none}]
        )
    of
        match ->
            Flag =
                case Name of
                    target -> "--target";
                    platform -> "--platform"
                end,
            validate_docker_build_args(Rest, [Value, Flag | Acc]);
        nomatch ->
            {error, {invalid_build_parameter_value, Name, Value}}
    end.

validate_build_arg(Value) ->
    case binary:split(to_binary(Value), <<"=">>) of
        [Key, _Val] ->
            case re:run(Key, <<"^[A-Za-z_][A-Za-z0-9_]*$">>, [{capture, none}]) of
                match -> ok;
                nomatch -> {error, {invalid_build_arg_name, Key}}
            end;
        [_KeyOnly] ->
            %% Do not allow Docker to inherit a value from the DamageBDD
            %% service environment by using `--build-arg NAME`.
            {error, build_arg_requires_explicit_value}
    end.

validate_assignment(Value) ->
    case binary:split(to_binary(Value), <<"=">>) of
        [<<>>, _] -> {error, invalid_empty_assignment_key};
        [_Key, _Val] -> ok;
        [_] -> {error, assignment_requires_value}
    end.

docker_workdir(Config) ->
    case lists:keyfind(run_dir, 1, Config) of
        {run_dir, RunDir} ->
            filename:join(RunDir, "docker");
        false ->
            throw(
                <<
                    "Docker step cannot start because `run_dir` is missing from the DamageBDD "
                    "configuration. Ensure the normal DamageBDD run configuration is initialized "
                    "before executing Docker steps."
                >>
            )
    end.

fetch_dockerfile(Src0) ->
    Src = to_binary(Src0),
    case is_ipfs_cid(Src) of
        true -> damage_ipfs:cat(Src);
        false -> fetch_url(Src)
    end.
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    list_to_binary(List).

is_ipfs_cid(<<"Qm", _/binary>>) -> true;
is_ipfs_cid(<<"bafy", _/binary>>) -> true;
is_ipfs_cid(_) -> false.

fetch_url(Url) ->
    inets:start(),
    ssl:start(),
    case httpc:request(get, {Url, []}, [{timeout, 60000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Code, _}, _, Body}} -> {error, {http_error, Code, Body}};
        Err -> Err
    end.

run_docker(Config, Args0, Context) when is_list(Args0) ->
    Docker = docker_executable(),
    Args = [normalize_exec_arg(A) || A <- Args0],
    run_exec(Config, [Docker | Args], Context).

docker_executable() ->
    case os:find_executable("docker") of
        false ->
            throw(
                <<
                    "Docker CLI is not available in the DamageBDD service PATH. "
                    "Install Docker and ensure the service can execute it."
                >>
            );
        Path ->
            filename:absname(Path)
    end.

normalize_exec_arg(B) when is_binary(B) ->
    binary_to_list(B);
normalize_exec_arg(L) when is_list(L) ->
    L;
normalize_exec_arg(A) when is_atom(A) ->
    atom_to_list(A);
normalize_exec_arg(I) when is_integer(I) ->
    integer_to_list(I).

%% ===== Helpers ===============================================================
run_exec(Config, ExecSpec, Context) ->
    steps_utils:ensure_admin(Context),
    DockerDir = docker_workdir(Config),
    ?LOG_DEBUG("steps_docker exec in ~s: ~p", [DockerDir, redact_exec_spec(ExecSpec)]),

    LogDir0 = filename:join(DockerDir, "logs"),
    ok = ensure_dir(LogDir0),

    Parent = self(),
    Watcher =
        spawn_link(fun() ->
            docker_loop(Config, Parent, [])
        end),

    ExecResult =
        try
            exec:run(
                ExecSpec,
                [{stdout, Watcher}, {stderr, Watcher}, monitor, {cd, DockerDir}, sync]
            )
        catch
            ExecClass:ExecReason:ExecStack ->
                ?LOG_ERROR(
                    "steps_docker command runner crashed class=~p reason=~p stack=~p",
                    [ExecClass, ExecReason, ExecStack]
                ),
                {error, {exec_exception, ExecClass, ExecReason}}
        end,

    case ExecResult of
        {ok, _ExecInfo} ->
            Ctx1 =
                receive
                    {docker_done, Result} ->
                        docker_result_context(Result, Context)
                after 1000 ->
                    maps:put(cmd_result, ok, Context)
                end,
            Ctx1;
        {error, Reason} ->
            ?LOG_ERROR("steps_docker command exited with error spec=~p reason=~p", [
                redact_exec_spec(ExecSpec), Reason
            ]),
            Details =
                receive
                    {docker_done, WatchResult} -> docker_error_details(WatchResult)
                after 100 ->
                    docker_error_details(Reason)
                end,
            stop_docker_watcher(Watcher),
            ErrorBin = docker_error_message(Details),
            Result = {error, [{stderr, [Details]}]},
            Ctx1 = maps:put(fail, ErrorBin, maps:put(cmd_result, Result, Context)),
            Ctx1;
        Other ->
            ?LOG_ERROR("steps_docker command returned unexpected result ~p", [Other]),
            stop_docker_watcher(Watcher),
            Details = docker_error_details(Other),
            ErrorBin = docker_error_message(Details),
            Result = {error, [{stderr, [Details]}]},
            Ctx1 = maps:put(fail, ErrorBin, maps:put(cmd_result, Result, Context)),
            Ctx1
    end.

stop_docker_watcher(Watcher) when is_pid(Watcher) ->
    unlink(Watcher),
    try
        exit(Watcher, kill)
    catch
        _:_ -> ok
    end,
    ok.

redact_exec_spec([Executable | Args]) ->
    [Executable | redact_exec_args(Args)];
redact_exec_spec(Other) ->
    Other.

redact_exec_args(["--build-arg", Value | Rest]) ->
    ["--build-arg", redact_assignment(Value) | redact_exec_args(Rest)];
redact_exec_args([Arg | Rest]) ->
    case string:prefix(Arg, "--build-arg=") of
        nomatch ->
            [Arg | redact_exec_args(Rest)];
        Value ->
            ["--build-arg=" ++ redact_assignment(Value) | redact_exec_args(Rest)]
    end;
redact_exec_args([]) ->
    [].

redact_assignment(Value0) ->
    Value = normalize_exec_arg(Value0),
    case string:split(Value, "=", leading) of
        [Key, _] -> Key ++ "=REDACTED";
        _ -> "REDACTED"
    end.

docker_result_context({ok, _} = Result, Context) ->
    maps:put(cmd_result, Result, Context);
docker_result_context({error, _} = Result, Context) ->
    Details = docker_error_details(Result),
    ErrorBin = docker_error_message(Details),
    maps:put(fail, ErrorBin, maps:put(cmd_result, Result, Context));
docker_result_context(Result, Context) ->
    maps:put(cmd_result, Result, Context).

docker_error_details({error, Parts}) when is_list(Parts) ->
    case lists:keyfind(stderr, 1, Parts) of
        {stderr, Chunks} ->
            iolist_to_binary(Chunks);
        false ->
            case lists:keyfind(stdout, 1, Parts) of
                {stdout, Chunks} -> iolist_to_binary(Chunks);
                false -> iolist_to_binary(io_lib:format("~p", [{error, Parts}]))
            end
    end;
docker_error_details(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

docker_error_message(Details0) ->
    Details = truncate_error(Details0, 3000),
    Lower = list_to_binary(string:lowercase(binary_to_list(Details))),
    Hint = docker_error_hint(Lower),
    <<"Docker command failed. ", Hint/binary, " Docker reported: ", Details/binary>>.

docker_error_hint(Lower) ->
    first_docker_error_hint(
        Lower,
        [
            {<<"cannot connect to the docker daemon">>, <<
                "The Docker daemon is unavailable. Check that Docker is running and that "
                "DOCKER_HOST points to the correct daemon/socket."
            >>},
            {<<"is the docker daemon running">>,
                <<"The Docker daemon is unavailable. Start Docker and verify access to its socket.">>},
            {<<"error during connect">>, <<
                "DamageBDD could not connect to Docker. Check the Docker daemon, DOCKER_HOST, "
                "and the Docker socket."
            >>},
            {<<"permission denied">>, <<
                "Docker access was denied. Check permissions for the Docker socket "
                "(commonly /var/run/docker.sock), the DamageBDD user, and any bind-mounted paths."
            >>},
            {<<"no space left on device">>, <<
                "Docker ran out of disk space. Check `docker system df` and free space in the "
                "Docker data/root filesystem before retrying."
            >>},
            {<<"pull access denied">>, <<
                "Docker could not pull the image. Verify the image/tag and registry permissions; "
                "authenticate with the registry when required."
            >>},
            {<<"authentication required">>, <<
                "The container registry requires authentication. Verify registry credentials "
                "and run the appropriate `docker login` outside the feature."
            >>},
            {<<"unauthorized">>,
                <<"The registry rejected the request. Verify image access and registry credentials.">>},
            {<<"manifest unknown">>,
                <<"The requested image tag does not exist in the registry. Verify the image name and tag.">>},
            {<<"no matching manifest">>, <<
                "The image has no manifest for this host platform/architecture. Use a compatible "
                "image or build for the required platform."
            >>},
            {<<"no such image">>,
                <<"The Docker image is not available locally. Build it first or verify that it can be pulled.">>},
            {<<"unable to find image">>, <<
                "Docker could not find the requested image locally and could not obtain it. "
                "Verify the image name/tag and registry connectivity."
            >>},
            {<<"damagebdd-script.sh: file exists">>, <<
                "Docker could not remount the stopped container's script bind. This usually "
                "means the host bind-source file was removed or changed type after `docker run`. "
                "Keep the bind source as a regular file until artifact copies are complete."
            >>},
            {<<"conflict. the container name">>, <<
                "A container with the requested name already exists. Remove/rename the old "
                "container or use a different name."
            >>},
            {<<"container name">>, <<
                "Docker reported a container-name problem. Check for an existing container with "
                "`docker ps -a` and remove or rename it if appropriate."
            >>},
            {<<"no such container">>, <<
                "The referenced container does not exist. Ensure the preceding `docker run` "
                "succeeded and that the scenario retained the correct container name/id."
            >>},
            {<<"no matching entries in passwd file">>, <<
                "The image does not contain the requested container user. This step runs as user "
                "`damage`; add that user to the image or use an image that provides it."
            >>},
            {<<"unable to find user damage">>,
                <<"The image does not contain the `damage` user required by this Docker run step.">>},
            {<<"dockerfile parse error">>,
                <<"Docker could not parse the Dockerfile. Check the reported Dockerfile line and syntax.">>},
            {<<"failed to compute cache key">>, <<
                "Docker could not resolve a build-context file, commonly from COPY/ADD. "
                "Verify that the referenced path exists inside the selected build context."
            >>},
            {<<"failed to solve">>, <<
                "The Docker build failed. Inspect the build output above, especially Dockerfile "
                "instructions, COPY/ADD source paths, package/network access, and the build context."
            >>},
            {<<"bind source path does not exist">>,
                <<"A bind-mounted host path does not exist. Create it or correct the mount path before running the container.">>},
            {<<"invalid mount config">>,
                <<"Docker rejected a mount. Check the host path, container path, and mount syntax.">>},
            {<<"mounts denied">>,
                <<"Docker denied a bind mount. Check Docker file-sharing permissions and the host path.">>},
            {<<"read-only file system">>,
                <<"The container or bind mount is read-only. Check mount flags and write to a writable path.">>},
            {<<"port is already allocated">>, <<
                "A requested host port is already in use. Stop the conflicting container/process "
                "or choose another host port."
            >>},
            {<<"has active endpoints">>, <<
                "Docker cannot remove the network because containers are still attached. "
                "Disconnect/remove those containers before pruning the network."
            >>},
            {<<"volume is in use">>, <<
                "Docker cannot remove the volume because a container still uses it. "
                "Remove or detach the dependent container first."
            >>},
            {<<"network is unreachable">>,
                <<"Docker cannot reach the network. Check host/container networking, firewall rules, proxy settings, and DNS.">>},
            {<<"temporary failure in name resolution">>,
                <<"DNS resolution failed inside Docker/build. Check Docker DNS and host network configuration.">>},
            {<<"could not resolve host">>,
                <<"DNS resolution failed. Check Docker DNS, proxy configuration, and network connectivity.">>},
            {<<"tls handshake timeout">>,
                <<"The registry/network TLS handshake timed out. Check connectivity, proxy settings, and registry availability.">>},
            {<<"i/o timeout">>,
                <<"The Docker network operation timed out. Check registry/network reachability and proxy settings.">>},
            {<<"exec format error">>,
                <<"The container executable is incompatible with the image/host architecture or has an invalid format.">>},
            {<<"executable file not found">>, <<
                "The requested command is not installed in the container or is not on PATH. "
                "Check the image contents and command name."
            >>},
            {<<"docker: command not found">>,
                <<"The Docker CLI is not installed or is not available in the DamageBDD service PATH.">>},
            {<<"docker: not found">>,
                <<"The Docker CLI is not installed or is not available in the DamageBDD service PATH.">>},
            {<<"enoent">>, <<
                "The Docker command runner could not start a required executable. Ensure the "
                "`docker` CLI is installed and available in the DamageBDD service PATH."
            >>},
            {<<"undef">>, <<
                "The DamageBDD OS command runner is unavailable or incomplete. Ensure the "
                "erlexec/exec application is installed and started."
            >>},
            {<<"noproc">>, <<
                "The DamageBDD OS command runner is not running. Ensure the erlexec/exec "
                "application is started before Docker steps execute."
            >>}
        ],
        <<
            "Check the Docker error above, verify the daemon is running, and reproduce with the "
            "same Docker operation on the node if more detail is needed."
        >>
    ).

first_docker_error_hint(Bin, [{Needle, Hint} | Rest], Default) ->
    case binary:match(Bin, Needle) of
        nomatch -> first_docker_error_hint(Bin, Rest, Default);
        _ -> Hint
    end;
first_docker_error_hint(_Bin, [], Default) ->
    Default.

truncate_error(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncate_error(Bin, Max) when is_binary(Bin) ->
    <<Prefix:Max/binary, _/binary>> = Bin,
    <<Prefix/binary, "...">>.

docker_loop(Config, Parent, Acc) ->
    receive
        %% stdout from OS process
        {stdout, _OsPid, Data} ->
            ?LOG_DEBUG("docker stdout: ~s", [Data]),
            formatter:format(
                Config,
                stdout,
                Data
            ),
            docker_loop(Config, Parent, [{stdout, Data} | Acc]);
        %% stderr from OS process
        {stderr, _OsPid, Data} ->
            ?LOG_WARNING("docker stderr: ~s", [Data]),
            formatter:format(
                Config,
                stderr,
                Data
            ),
            docker_loop(Config, Parent, [{stderr, Data} | Acc]);
        {'DOWN', _OsPid, process, _ExecPid, ExitStatus} ->
            ?LOG_WARNING("docker down: ~p", [ExitStatus]),
            Rev = lists:reverse(Acc),
            Stdouts = [D || {stdout, D} <- Rev],
            Stderrs = [D || {stderr, D} <- Rev],
            StdoutBin = iolist_to_binary(Stdouts),
            StderrBin = iolist_to_binary(Stderrs),

            Result =
                case ExitStatus of
                    normal ->
                        {ok, [{stdout, [StdoutBin]}]};
                    {exit_status, 0} ->
                        {ok, [{stdout, [StdoutBin]}]};
                    Other ->
                        ErrBin =
                            case StderrBin of
                                <<>> -> StdoutBin;
                                _ -> StderrBin
                            end,
                        {error, [{stderr, [ErrBin]}, {exit_status, Other}]}
                end,

            Parent ! {docker_done, Result};
        Other ->
            ?LOG_DEBUG("docker_loop got unexpected message: ~p", [Other]),
            docker_loop(Config, Parent, Acc)
    after ?DOCKER_LOOP_TIMEOUT ->
        Timeout = damage_utils:strf("docker command timed out in watcher after ~p", [
            ?DOCKER_LOOP_TIMEOUT
        ]),
        ?LOG_ERROR("docker_loop timeout"),
        formatter:format(
            Config,
            error,
            {-1, Timeout}
        ),
        Parent ! {docker_done, {error, [{stderr, [Timeout]}]}}
    end.

%% -------------------------------------------------------
%% Helpers
%% -------------------------------------------------------

ensure_dir(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Cannot create Docker working directory ~s (~p)", [Dir, Reason]),
            throw(
                damage_utils:strf(
                    "Docker step cannot create working directory ~s: ~p. "
                    "Check DamageBDD run-directory permissions and available disk space.",
                    [Dir, Reason]
                )
            )
    end.

%% Build a docker image from an inline Dockerfile contained in Raw.
build_image_from_inline_dockerfile(Config, Image, Raw, Context) ->
    steps_utils:ensure_admin(Context),
    %% Raw is iodata() from the feature body
    BodyBin = iolist_to_binary(Raw),
    Trimmed = binary:trim(BodyBin, both, " \t\r\n"),

    case Trimmed of
        <<>> ->
            %% Fail fast if the feature forgot to provide the Dockerfile body.
            maps:put(
                fail,
                damage_utils:strf(
                    "Docker image ~p cannot be built because the Dockerfile body is empty. "
                    "Provide the Dockerfile in the step docstring.",
                    [Image]
                ),
                Context
            );
        DockerfileBin ->
            CWD = filename:absname(maps:get(cmd_cwd, Context, ".")),
            %% We keep a dedicated build context directory under the current CWD
            BuildDir = filename:join(CWD, ".damage_docker_build"),
            DockerfilePath = filename:join(BuildDir, "Dockerfile"),

            %% Ensure directory exists
            ok = ensure_dir(BuildDir),

            %% Write Dockerfile
            case file:write_file(DockerfilePath, DockerfileBin) of
                ok ->
                    ImageRef = require_docker_ref(Image),
                    ?LOG_INFO(
                        "Building docker image ~s from inline Dockerfile at ~s (context ~s)",
                        [ImageRef, DockerfilePath, BuildDir]
                    ),
                    run_docker(
                        Config,
                        [
                            "build",
                            "--network=host",
                            "-t",
                            binary_to_list(ImageRef),
                            "-f",
                            DockerfilePath,
                            BuildDir
                        ],
                        Context
                    );
                {error, Reason} ->
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "Docker build could not write ~s: ~p. "
                            "Check directory permissions and available disk space.",
                            [DockerfilePath, Reason]
                        ),
                        Context
                    )
            end
    end.

%% Extract stdout in the same way as before so existing steps keep working.
cmd_stdout(Context) ->
    case maps:get(cmd_result, Context, undefined) of
        {ok, [{stdout, [Bin]}]} ->
            Bin;
        {error, List} ->
            case lists:keyfind(stderr, 1, List) of
                {stderr, [Bin]} -> Bin;
                _ -> <<>>
            end;
        _Other ->
            <<>>
    end.

%% Convert "3 days ago" into "YYYY-MM-DD" using date_util, as in the original
%% steps_docker.
relative_string_to_date(Relative) ->
    try
        case string:tokens(string:lowercase(Relative), " ") of
            [NumStr, Unit, "ago"] ->
                {ok, Num} = string:to_integer(NumStr),
                Seconds = seconds_for_unit(Unit, Num),
                EpochAgo = date_util:epoch() - Seconds,
                {{Y, M, D}, _Time} = date_util:timestamp_to_datetime(EpochAgo),
                {ok, lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]))};
            _ ->
                erlang:error({unrecognized_format, Relative})
        end
    catch
        _:Reason ->
            {error, {invalid_relative_date, Relative, Reason}}
    end.

seconds_for_unit("second", N) -> N;
seconds_for_unit("seconds", N) -> N;
seconds_for_unit("minute", N) -> N * 60;
seconds_for_unit("minutes", N) -> N * 60;
seconds_for_unit("hour", N) -> N * 3600;
seconds_for_unit("hours", N) -> N * 3600;
seconds_for_unit("day", N) -> date_util:days_to_seconds(N);
seconds_for_unit("days", N) -> date_util:days_to_seconds(N);
seconds_for_unit("week", N) -> date_util:days_to_seconds(N * 7);
seconds_for_unit("weeks", N) -> date_util:days_to_seconds(N * 7);
seconds_for_unit("month", N) -> date_util:days_to_seconds(N * 30);
seconds_for_unit("months", N) -> date_util:days_to_seconds(N * 30);
seconds_for_unit("year", N) -> date_util:days_to_seconds(N * 365);
seconds_for_unit("years", N) -> date_util:days_to_seconds(N * 365);
seconds_for_unit(Unit, _) -> erlang:error({unknown_unit, Unit}).
copy_file_from_container_to_ipfs(Config, Context0, Path0, Variable0) ->
    steps_utils:ensure_admin(Context0),

    Container = docker_container_id(Context0),
    Path = to_binary(Path0),
    %% Preserve the key type emitted by the step tokenizer.  Other DamageBDD
    %% variable-producing steps store the captured variable name directly.
    Variable = Variable0,

    DockerDir = docker_workdir(Config),
    StageRoot = filename:join(DockerDir, "ipfs_stage"),
    ok = ensure_dir(StageRoot),

    %% Leave the destination itself absent. `docker cp` will create this exact
    %% path for either a source file or source directory, avoiding an extra
    %% random wrapper directory around the artifact.
    StageDir = filename:join(
        StageRoot,
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))
    ),

    Source = <<Container/binary, ":", Path/binary>>,

    ?LOG_INFO(
        "Copying Docker artifact container=~p source=~p stage=~p",
        [Container, Path, StageDir]
    ),

    %% Execute Docker directly as argv.  Do not construct a host shell command:
    %% paths and container names are data, and this also removes the old
    %% shell-quoting/temp-script collision path entirely.
    Context1 = run_docker(
        Config,
        ["cp", Source, StageDir],
        Context0
    ),

    case maps:is_key(fail, Context1) of
        true ->
            maybe_remove_stage_path(StageDir),
            Context1;
        false ->
            try
                Hash = ipfs_add_path_and_get_hash(StageDir),
                maps:put(Variable, Hash, Context1)
            catch
                Class:Reason:Stack ->
                    ?LOG_ERROR(
                        "Docker artifact IPFS staging failed class=~p reason=~p stack=~p",
                        [Class, Reason, Stack]
                    ),
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "Failed to add Docker artifact to IPFS: ~p",
                            [Reason]
                        ),
                        Context1
                    )
            after
                maybe_remove_stage_path(StageDir)
            end
    end.

maybe_remove_stage_path(StagePath) ->
    Result =
        case file:read_link_info(StagePath) of
            {ok, #file_info{type = directory}} ->
                file:del_dir_r(StagePath);
            {ok, _Info} ->
                file:delete(StagePath);
            {error, enoent} ->
                ok;
            {error, Reason0} ->
                {error, Reason0}
        end,
    case Result of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(
                "Unable to remove Docker IPFS staging path ~p: ~p",
                [StagePath, Reason]
            ),
            ok
    end.

ipfs_add_path_and_get_hash(Path0) ->
    Path = normalize_filename(Path0),
    assert_upload_target(Path),

    AddResult =
        case filelib:is_dir(binary_to_list(Path)) of
            true ->
                damage_ipfs:add({directory, Path});
            false ->
                damage_ipfs:add({file, Path})
        end,

    case AddResult of
        {ok, HashList} ->
            RootName = filename:basename(binary_to_list(Path)),
            pick_ipfs_root_hash(HashList, RootName);
        Error ->
            erlang:error({ipfs_add_failed, Path, Error})
    end.

pick_ipfs_root_hash(HashList, RootName0) ->
    RootName =
        case RootName0 of
            B when is_binary(B) -> B;
            L when is_list(L) -> list_to_binary(L)
        end,

    case
        [
            Cid
         || #{<<"Name">> := Name, <<"Hash">> := Cid} <- HashList,
            to_binary(Name) =:= RootName
        ]
    of
        [Cid0 | _] ->
            Cid0;
        [] ->
            %% fallback: for file adds or some directory adds, root CID is last
            case lists:reverse(HashList) of
                [#{<<"Hash">> := Cid0} | _] ->
                    Cid0;
                _ ->
                    erlang:error({ipfs_add_no_hash_returned, HashList})
            end
    end.

assert_upload_target(Path0) ->
    Path = normalize_filename(Path0),
    case file:read_file_info(Path) of
        {ok, Info} ->
            ?LOG_INFO(
                "IPFS upload target path=~p type=~p size=~p",
                [Path, Info#file_info.type, Info#file_info.size]
            ),
            ok;
        Error ->
            ?LOG_ERROR("IPFS upload target missing path=~p error=~p", [Path, Error]),
            erlang:error({ipfs_upload_target_missing, Path, Error})
    end.

docker_container_id(Ctx) ->
    case
        first_defined(
            [docker_container, docker_container_name, docker_container_id, container_id, container],
            Ctx
        )
    of
        undefined ->
            throw(
                <<
                    "No Docker container is available in the scenario context. Ensure a preceding "
                    "Docker run step completed successfully before copying files from the container."
                >>
            );
        V ->
            to_binary(V)
    end.

first_defined([], _Ctx) ->
    undefined;
first_defined([K | Ks], Ctx) ->
    case maps:get(K, Ctx, undefined) of
        undefined -> first_defined(Ks, Ctx);
        V -> V
    end.

unique_stage_id() ->
    Enc = base64:encode(crypto:strong_rand_bytes(12)),
    Safe0 = binary:replace(Enc, <<"/">>, <<"_">>, [global]),
    Safe1 = binary:replace(Safe0, <<"+">>, <<"-">>, [global]),
    Safe2 = binary:replace(Safe1, <<"=">>, <<>>, [global]),
    binary_to_list(Safe2).

normalize_filename(Bin) when is_binary(Bin) ->
    Bin;
normalize_filename(List) when is_list(List) ->
    unicode:characters_to_binary(List);
normalize_filename(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8).
