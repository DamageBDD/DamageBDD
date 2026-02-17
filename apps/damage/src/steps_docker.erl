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
    CmdIO =
        io_lib:format(
            "docker system prune -a --force --filter \"until=~s\"",
            [ISODate]
        ),
    Command = lists:flatten(CmdIO),
    Ctx1 = run_cmd(Config, Command, Context),
    ?LOG_NOTICE("Docker cleanup command executed: ~s", [Command]),
    Ctx1#{since => ISODate};
%% ---------------------------------------------------------------------------
%% Then: assert that no unused resources older than relative time remain
%%   Then the Docker system should have no unused resources older than "3 days ago"
%% ---------------------------------------------------------------------------
step(Config, Context, <<"Then">>, _N, ?THEN_NO_UNUSED_OLDER_THAN, _Raw) ->
    steps_utils:ensure_admin(Context),
    {ok, ISODate} = relative_string_to_date(Relative),
    CmdIO =
        io_lib:format(
            "docker ps -a --filter \"status=exited\" "
            "--filter \"until=~s\" --format '{{.ID}}'",
            [ISODate]
        ),
    Command = lists:flatten(CmdIO),
    Ctx1 = run_cmd(Config, Command, Context),
    case cmd_stdout(Ctx1) of
        <<>> ->
            Ctx1;
        Bin ->
            Trimmed = string:trim(binary_to_list(Bin)),
            case Trimmed of
                "" ->
                    Ctx1;
                _ ->
                    ?LOG_ERROR("Docker cleanup failed, leftover IDs: ~s", [Trimmed]),
                    erlang:error({docker_cleanup_failed, Trimmed})
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
step(Config, Context, <<"Then">>, _N, ?RUN_DOCKER_IMAGE_TAGGED, ScriptBin) ->
    run_docker_tagged(Config, Tag, ScriptBin, Context).

run_docker_tagged(Config, Tag, ScriptBin0, Ctx0) ->
    steps_utils:ensure_admin(Ctx0),
    ScriptBin = to_binary(ScriptBin0),

    {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
    WorkDir = filename:join(RunDir, "docker"),
    OutDir = filename:join(RunDir, "out"),

    ok = filelib:ensure_dir(WorkDir),
    ok = filelib:ensure_dir(OutDir),

    %% Write script to file (useful for debugging / artifacts)
    ScriptPath = filename:join(WorkDir, "script.sh"),
    ok = file:write_file(ScriptPath, ScriptBin),

    %% Execute using sh -lc so heredoc-style scripts work naturally
    %% Note: we pass the script contents directly to sh -lc for simplicity.
    Cmd =
        iolist_to_binary([
            "docker run --network=host --rm ",
            "-v ",
            shell_quote(OutDir),
            ":/out ",
            "-w /opt/workspace ",
            shell_quote(Tag),
            " ",
            "sh -lc ",
            shell_quote(ScriptBin)
        ]),

    ?LOG_DEBUG("Docker cmd ~p script path ~p", [Cmd, ScriptPath]),
    %% Use your existing command runner (whatever you already call for docker)
    %% If you already default cwd to <run_dir>/docker, this is fine.
    Ctx1 = run_cmd_in_docker_dir(Config, Cmd, Ctx0),

    %% Save locations for later steps (eg: IPFS upload of built artifacts)
    maps:merge(Ctx1, #{
        docker_workdir => WorkDir,
        docker_outdir => OutDir
    }).

build_image_from_dockerfile(Config, Src, Tag, Params, ContextRel0, Ctx0) ->
    steps_utils:ensure_admin(Context),
    WorkDir = docker_workdir(Config),
    ok = filelib:ensure_dir(filename:join(WorkDir, "x")),

    %% 1) Fetch Dockerfile contents
    {ok, DockerfileBin} = fetch_dockerfile(Src),

    %% 2) Write Dockerfile into workdir
    DockerfilePath = filename:join(WorkDir, "Dockerfile"),
    ok = file:write_file(DockerfilePath, DockerfileBin),

    %% 3) Resolve build context
    ContextDir =
        case ContextRel0 of
            undefined ->
                WorkDir;
            Rel when is_binary(Rel) ->
                %% relative to WorkDir
                filename:join(WorkDir, binary_to_list(Rel))
        end,

    %% 4) Run docker build inside WorkDir
    %% NOTE: Params is appended verbatim (user-controlled).
    Cmd =
        iolist_to_binary([
            "docker build --network=host -f ",
            shell_quote(DockerfilePath),
            " -t ",
            shell_quote(Tag),
            " ",
            Params,
            " ",
            shell_quote(ContextDir)
        ]),
    Ctx1 = run_cmd_in_docker_dir(Config, Cmd, Ctx0),

    maps:put(docker_image_tag, Tag, Ctx1).

docker_workdir(Config) ->
    {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
    filename:join(RunDir, "docker").

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

run_cmd_in_docker_dir(Config, CmdBin, Ctx0) ->
    %% Use your existing run_cmd but force cwd to docker workdir
    %% (If you already refactored run_cmd to use <run_dir>/docker by default, just call it.)
    %% Placeholder:
    run_cmd(Config, CmdBin, Ctx0).

shell_quote(List) when is_list(List) ->
    shell_quote(list_to_binary(List));
shell_quote(Bin) when is_binary(Bin) ->
    %% minimal safe quoting for paths/tags (single quotes)
    <<"'", (binary:replace(Bin, <<"'>">>, <<"'\"'\"'">>, [global]))/binary, "'">>.

%% ===== Helpers ===============================================================
run_cmd(Config, Command, Context) ->
    steps_utils:ensure_admin(Context),
    DockerDir = docker_workdir(Config),
    ?LOG_INFO("steps_docker running command in ~s: ~s", [DockerDir, Command]),
    LogDir0 =
        filename:join(DockerDir, "logs"),
    ok = ensure_dir(LogDir0),

    %LogFile = filename:join(LogDir0, gen_log_name("docker")),

    %Opts = [stdout, stderr, monitor, {cd, CWD}],
    ?LOG_INFO("steps_docker running command in ~s: ~s", [DockerDir, Command]),

    Parent = self(),
    Watcher =
        spawn_link(fun() ->
            docker_loop(Config, Parent, [])
        end),

    case
        exec:run(Command, [{stdout, Watcher}, {stderr, Watcher}, monitor, {cd, DockerDir}, sync])
    of
        {ok, []} ->
            ?LOG_DEBUG("steps_docker exec result ~p", [[]]),
            maps:put(cmd_result, ok, Context);
        {error, Reason} ->
            ?LOG_ERROR("steps_docker failed to start command ~p: ~p", [Command, Reason]),
            ErrorBin = damage_utils:strf("Failed to start command ~p: ~p~n", [Command, Reason]),
            Result = {error, [{stderr, [ErrorBin]}]},
            maps:put(
                fail,
                ErrorBin,
                maps:put(cmd_result, Result, Context)
            )
    end.
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
            ?LOG_INFO("docker_loop got unexpected message: ~p", [Other]),
            docker_loop(Config, Parent, Acc)
    after ?DOCKER_LOOP_TIMEOUT ->
        Timeout = damage_utils:strf("docker command timed out in watcher after ~p",[?DOCKER_LOOP_TIMEOUT]),
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
            ?LOG_ERROR("Cannot create directory ~s (~p)", [Dir, Reason]),
            error({cannot_create_dir, Dir, Reason})
    end.

%% Build a docker image from an inline Dockerfile contained in Raw.
build_image_from_inline_dockerfile(Config, Image, Raw, Context) ->
    steps_utils:ensure_admin(Context),
    %% Raw is iodata() from the feature body
    BodyBin = iolist_to_binary(Raw),
    Trimmed = binary:trim(BodyBin, both, " \t\r\n"),

    case Trimmed of
        <<>> ->
            %% Fail fast if the feature forgot to provide the Dockerfile body
            erlang:error({missing_dockerfile_body, Image});
        DockerfileBin ->
            CWD = filename:absname(maps:get(cmd_cwd, Context, ".")),
            %% We keep a dedicated build context directory under the current CWD
            BuildDir = filename:join(CWD, ".damage_docker_build"),
            DockerfilePath = filename:join(BuildDir, "Dockerfile"),

            %% Ensure directory exists
            ok = filelib:ensure_dir(DockerfilePath),

            %% Write Dockerfile
            case file:write_file(DockerfilePath, DockerfileBin) of
                ok ->
                    CmdIO =
                        io_lib:format(
                            "docker build --network=host -t ~s -f ~s ~s",
                            [Image, DockerfilePath, BuildDir]
                        ),
                    Command = lists:flatten(CmdIO),
                    ?LOG_INFO(
                        "Building docker image ~s from inline Dockerfile at ~s (context ~s)",
                        [Image, DockerfilePath, BuildDir]
                    ),
                    run_cmd(Config, Command, Context);
                {error, Reason} ->
                    erlang:error({dockerfile_write_failed, DockerfilePath, Reason})
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
