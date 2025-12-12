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

%% Build pipeline (build.sh)
-define(WHEN_BUILD_MINT22_BUILDER_IMAGE,
        ["I build the mint22 builder Docker image"]).
-define(WHEN_RUN_MINT22_BUILDER_TO_BUILD_DEBS,
        ["I build Debian packages using the mint22 builder container"]).

%% Test / run pipeline (run.sh)
-define(WHEN_RUN_MINT22_TEST_CONTAINER,
        ["I run a mint22 test container installing the built Debian package"]).
%% Build an image from an inline Dockerfile
-define(WHEN_BUILD_IMAGE_FROM_INLINE_DOCKERFILE,
        ["I build docker image", Image, "from this Dockerfile"]).

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
%% When: build the mint22 builder image (first half of build.sh)
%%   When I build the mint22 builder Docker image
%% ---------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?WHEN_BUILD_MINT22_BUILDER_IMAGE, _Raw) ->
    steps_utils:ensure_admin(Context),
    Command =
        "DOCKER_BUILDKIT=1 docker build "
        "--build-arg CACHEBUST=$(date +%s) "
        "-t damagebdd/mint22-builder:latest .",
    ?LOG_INFO("Building mint22 builder image with command: ~s", [Command]),
    %stream_chunk(Config, <<"Building mint22 builder image with command: ~s">>),
    run_cmd(Config, Command, Context);
%% ---------------------------------------------------------------------------
%% When: run the builder container to produce .deb packages (rest of build.sh)
%%   When I build Debian packages using the mint22 builder container
%% ---------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?WHEN_RUN_MINT22_BUILDER_TO_BUILD_DEBS, _Raw) ->
    steps_utils:ensure_admin(Context),
    %% This replicates the bash -lc '...' block from build.sh as closely as
    %% possible, but wrapped in a single docker run. :contentReference[oaicite:5]{index=5}
    InnerScript =
        "set -e\n"
        "git reset --hard\n"
        "if [ -d .git ]; then git pull --ff-only || true; fi\n"
        "rm -f rebar.lock\n"
        "rm -rf _build\n"
        "DEBUG=1\n"
        "rebar3 as prod release\n"
        "rebar3 pkg gen -t deb\n"
        "rm -f /out/*.deb\n"
        "cp -a _build/pkg/deb/*.deb /out/\n"
        "rm -f rebar.lock\n",
    Command =
        "docker run --rm -i "
        "-v \"$(pwd)/deb:/out\" "
        "-w /opt/workspace "
        "damagebdd/mint22-builder:latest "
        "bash -lc " ++ "\"" ++
            escape_for_double_quotes(InnerScript) ++ "\"",
    ?LOG_INFO("Running mint22 builder container with command: ~s", [Command]),
    run_cmd(Config, Command, Context);
%% ---------------------------------------------------------------------------
%% When: run a mint22 test container to install and run the built deb
%%   When I run a mint22 test container installing the built Debian package
%% ---------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?WHEN_RUN_MINT22_TEST_CONTAINER, _Raw) ->
    steps_utils:ensure_admin(Context),
    %% Directly mirrors run.sh behaviour. :contentReference[oaicite:6]{index=6}
    InnerScript =
        "set -e\n"
        "PKG_DEBUG=1 dpkg -i -D3 /deb/damage_*.deb\n"
        "export SHELL=sh\n"
        "bash\n"
        "/opt/damage/bin/damage foreground\n",
    Command =
        "docker run -i "
        "-v \"$(pwd)/deb:/deb\" "
        "-w /opt/workspace "
        "-p 8888:8080 "
        "linuxmintd/mint22-amd64 "
        "bash -xlc " ++ "\"" ++
            escape_for_double_quotes(InnerScript) ++ "\"",
    ?LOG_INFO("Running mint22 test container with command: ~s", [Command]),
    run_cmd(Config, Command, Context);
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
    build_image_from_inline_dockerfile(Config, Image, Raw, Context).

%% ===== Helpers ===============================================================

%% Run a shell command via erlexec, mirroring steps_cmd behaviour but keeping
%% the result under 'cmd_result' so the generic "Then the exit status must be"
%% and stdout assertion steps can be reused. :contentReference[oaicite:7]{index=7}
%% ===== Helpers ===============================================================

%% Run a shell command via erlexec, but:
%%   * stream stdout/stderr via logger (picked up by the text formatter
%%     when you're in streaming mode),
%%   * keep a result under 'cmd_result' compatible with the old shape
%%     so existing "Then the exit status must be" and stdout match steps
%%     continue to work.
%% Run a shell command via erlexec, but:
%%   * stream stdout/stderr via text_formatter when in HTTP mode
%%   * keep a result under 'cmd_result' compatible with old shape
run_cmd(Config, Command, Context) ->
    CWD = filename:absname(maps:get(cmd_cwd, Context, ".")),
    %Opts = [stdout, stderr, monitor, {cd, CWD}],
    ?LOG_INFO("steps_docker running command in ~s: ~s", [CWD, Command]),

    Parent = self(),
    Watcher =
        spawn_link(fun() ->
            docker_watcher(Config, Parent)
        end),

    case exec:run(Command, [{stdout, Watcher}, {stderr, Watcher}, monitor, {cd, CWD}]) of
        {ok, ExecPid, OsPid} ->
            %% Tell watcher which PIDs to care about
            Watcher ! {attach, ExecPid, OsPid},
            %% Block until watcher finishes and sends result
            receive
                {docker_done, Result} ->
                    ?LOG_DEBUG("steps_docker exec result ~p", [Result]),
                    maps:put(cmd_result, Result, Context)
            after 600000 ->
                %% Very defensive timeout
                ?LOG_ERROR("steps_docker: watcher timeout for command ~p", [Command]),
                maps:put(cmd_result, {error, [{stderr, [<<"watcher timeout">>]}]}, Context)
            end;
        {error, Reason} ->
            ?LOG_ERROR("steps_docker failed to start command ~p: ~p", [Command, Reason]),
            ErrorBin =
                iolist_to_binary(
                    io_lib:format("Failed to start command ~p: ~p~n", [Command, Reason])
                ),
            Result = {error, [{stderr, [ErrorBin]}]},
            maps:put(cmd_result, Result, Context)
    end.
docker_watcher(Config, Parent) ->
    receive
        {attach, ExecPid, OsPid} ->
            docker_loop(Config, Parent, ExecPid, OsPid, [])
    end.

docker_loop(Config, Parent, ExecPid, OsPid, Acc) ->
    receive
        %% stdout from OS process
        {stdout, OsPid, Data} ->
            ?LOG_INFO("docker stdout: ~s", [Data]),
            formatter:format(
                Config,
                stdout,
                Data
            ),
            docker_loop(Config, Parent, ExecPid, OsPid, [{stdout, Data} | Acc]);
        %% stderr from OS process
        {stderr, OsPid, Data} ->
            ?LOG_WARNING("docker stderr: ~s", [Data]),
            formatter:format(
                Config,
                stderr,
                Data
            ),
            docker_loop(Config, Parent, ExecPid, OsPid, [{stderr, Data} | Acc]);
        %% monitor message from erlexec
        {'DOWN', OsPid, process, ExecPid, ExitStatus} ->
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
            ?LOG_WARNING("docker_watcher got unexpected message: ~p", [Other]),
            docker_loop(Config, Parent, ExecPid, OsPid, Acc)
    after 600000 ->
        Timeout = <<"docker command timed out in watcher after 600s">>,
        ?LOG_ERROR("docker_watcher timeout"),
        formatter:format(
            Config,
            error,
            {-1, Timeout}
        ),
        Parent ! {docker_done, {error, [{stderr, [Timeout]}]}}
    end.

%% Build a docker image from an inline Dockerfile contained in Raw.
build_image_from_inline_dockerfile(Config, Image, Raw, Context) ->
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
                            "docker build -t ~s -f ~s ~s",
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

escape_for_double_quotes(Str) when is_list(Str) ->
    lists:flatten(
        [
            case C of
                $" -> "\\\"";
                $\n -> "\\n";
                $\\ -> "\\\\";
                _ -> [C]
            end
         || C <- Str
        ]
    ).
