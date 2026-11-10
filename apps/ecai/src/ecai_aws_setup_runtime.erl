%% Local Python environment lifecycle. No AWS credentials, SDK requests or shell.
%% The asynchronous port keeps pip/network delays out of startup and HTTP calls.
-module(ecai_aws_setup_runtime).
-behaviour(gen_server).
-export([start_link/0, status/0, public/0, python/0, recheck/0, settings/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/1]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
status() ->
    try gen_server:call(?MODULE, status, 2000)
    catch _:_ -> info(<<"unavailable">>, <<"runtime_not_started">>) end.
public() -> maps:without([<<"python">>], status()).
python() ->
    case status() of
        #{<<"ready">> := true, <<"python">> := Path} when is_binary(Path) ->
            binary_to_list(Path);
        _ -> false
    end.
%% Erlang operator API only. No dashboard endpoint installs node packages.
recheck() -> gen_server:cast(?MODULE, check).

init([]) ->
    process_flag(trap_exit, true),
    self() ! check,
    {ok, #{info => info(<<"starting">>, <<>>), port => undefined,
           timer => undefined, deadline => undefined, result => undefined,
           signature => undefined, failures => 0}}.
handle_call(status, _From, S) ->
    Current = case same_settings(S) of
        true -> maps:get(info, S);
        false -> info(<<"pending">>, <<"runtime_settings_changed">>)
    end,
    {reply, Current, S};
handle_call(_, _From, S) -> {reply, {error, unsupported}, S}.
handle_cast(check, #{port := undefined} = S) -> {noreply, begin_check(cancel_timer(S))};
handle_cast(check, S) ->
    case same_settings(S) of
        true -> {noreply, S};
        false -> {noreply, begin_check(close_port(cancel_timer(cancel_deadline(S))))}
    end;
handle_cast(_, S) -> {noreply, S}.
handle_info(check, #{port := undefined} = S) -> {noreply, begin_check(cancel_timer(S))};
handle_info(check, S) -> {noreply, S};
handle_info({timeout, Ref, check}, #{timer := Ref, port := undefined} = S) ->
    {noreply, begin_check(S#{timer := undefined})};
handle_info({Port, {data, {eol, Bytes}}}, #{port := Port} = S) when is_port(Port) ->
    {noreply, packet(Bytes, S)};
handle_info({Port, {data, {noeol, _}}}, #{port := Port} = S) when is_port(Port) ->
    {noreply, finish_error(<<"invalid_health_output">>, close_port(S))};
handle_info({Port, {exit_status, 0}}, #{port := Port, result := #{<<"ok">> := true} = Result} = S) ->
    case same_settings(S) of
        true ->
            Value = maps:merge(info(<<"ready">>, <<>>),
                maps:with([<<"python">>, <<"mode">>, <<"versions">>, <<"reused">>], Result)),
            Ready = Value#{<<"ready">> => true, <<"checked_at_ms">> => now_ms()},
            {noreply, schedule(300000, cancel_deadline(S#{port := undefined,
                info := Ready, result := undefined, failures := 0}))};
        false ->
            {noreply, schedule(0, cancel_deadline(S#{port := undefined, result := undefined,
                info := info(<<"pending">>, <<"runtime_settings_changed">>)}))}
    end;
handle_info({Port, {exit_status, _}}, #{port := Port, result := Result} = S) ->
    Code = case Result of #{<<"error">> := E} -> E; _ -> <<"runtime_bootstrap_failed">> end,
    {noreply, finish_error(Code, S#{port := undefined})};
handle_info({timeout, Ref, runtime_deadline}, #{deadline := Ref} = S) ->
    {noreply, finish_error(<<"runtime_timeout">>, close_port(S))};
handle_info({'EXIT', Port, Reason}, #{port := Port} = S) when is_port(Port), Reason =/= normal ->
    {noreply, finish_error(<<"runtime_bootstrap_failed">>, S#{port := undefined})};
handle_info(_, S) -> {noreply, S}.
terminate(_, S) -> close_port(cancel_timer(cancel_deadline(S))), ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) when is_map(Status) ->
    Status#{state => runtime_state_redacted, message => redacted, reason => redacted, log => []}.

begin_check(S) ->
    S0 = S#{result := undefined, signature := current_signature()},
    case application:get_env(ecai, aws_setup_enabled, false) of
        true ->
            try
                case settings() of
                    {ok, Bootstrap, Spec} -> start_helper(Bootstrap, Spec, S0);
                    {error, Code} -> finish_error(Code, S0)
                end
            catch _:_ -> finish_error(<<"invalid_runtime_settings">>, S0) end;
        _ -> schedule(60000, S0#{info := info(<<"disabled">>, <<>>), failures := 0})
    end.
start_helper(Bootstrap, Spec, S) ->
    try
        Script = filename:join([code:priv_dir(ecai), "aws_setup", "runtime.py"]),
        Port = open_port({spawn_executable, Bootstrap},
            [binary, exit_status, use_stdio, {line, 16384},
             {args, ["-I", "-u", Script]}, {env, bootstrap_environment()}]),
        try
            true = port_command(Port, [jsx:encode(Spec), "\n"]),
            Ref = erlang:start_timer((maps:get(<<"timeout_seconds">>, Spec) + 5) * 1000,
                                     self(), runtime_deadline),
            S#{port := Port, deadline := Ref,
               info := (info(<<"checking">>, <<>>))#{<<"mode">> => maps:get(<<"mode">>, Spec)}}
        catch _:_ -> finish_error(<<"bootstrap_start_failed">>, close_port(S#{port := Port})) end
    catch _:_ -> finish_error(<<"bootstrap_start_failed">>, S) end.

%% Explicit paths are verified, never installed into or modified. Omitted/auto
%% selects a private runtime beneath the existing Damage/ECAI data root.
settings() ->
    Bootstrap = executable(application:get_env(ecai, aws_setup_bootstrap_python, "python3")),
    Timeout = application:get_env(ecai, aws_setup_runtime_timeout_seconds, 600),
    AutoInstall = application:get_env(ecai, aws_setup_runtime_auto_install, true),
    case {Bootstrap, is_integer(Timeout) andalso Timeout >= 10 andalso Timeout =< 1800,
          is_boolean(AutoInstall)} of
        {false, _, _} -> {error, <<"bootstrap_python_missing">>};
        {_, false, _} -> {error, <<"invalid_runtime_settings">>};
        {_, _, false} -> {error, <<"invalid_runtime_settings">>};
        _ -> runtime_settings(Bootstrap, Timeout, AutoInstall)
    end.
runtime_settings(Bootstrap, Timeout, AutoInstall) ->
    Value = application:get_env(ecai, aws_setup_python, auto),
    case Value =:= auto orelse Value =:= undefined of
        true ->
            Root = case application:get_env(ecai, aws_setup_runtime_dir) of
                undefined -> filename:join([ecai_paths:runtime_dir(), "python", "aws-setup"]);
                {ok, Path} -> absolute_path(Path)
            end,
            Wheels = case application:get_env(ecai, aws_setup_wheelhouse) of
                undefined -> <<>>;
                {ok, <<>>} -> <<>>;
                {ok, []} -> <<>>;
                {ok, Path1} -> unicode:characters_to_binary(absolute_path(Path1))
            end,
            {ok, Bootstrap, #{<<"mode">> => <<"managed">>,
                <<"root">> => unicode:characters_to_binary(Root), <<"install">> => AutoInstall,
                <<"wheelhouse">> => Wheels, <<"timeout_seconds">> => Timeout}};
        false ->
            {ok, Bootstrap, #{<<"mode">> => <<"external">>,
                <<"python">> => unicode:characters_to_binary(absolute_path(Value)),
                <<"timeout_seconds">> => Timeout}}
    end.
absolute_path(Value) ->
    List = unicode:characters_to_list(Value),
    case List of
        [$/ | _] -> case lists:member(0, List) of false -> List; true -> error(invalid_path) end;
        _ -> error(invalid_path)
    end.
executable(Value) ->
    try unicode:characters_to_list(Value) of
        [$/ | _] = Path -> case filelib:is_regular(Path) of true -> Path; false -> false end;
        Name when is_list(Name), Name =/= [] ->
            case lists:member($/, Name) orelse lists:member(0, Name) of
                true -> false;
                false -> os:find_executable(Name)
            end;
        _ -> false
    catch _:_ -> false end.

%% Remove sensitive/provider/install overrides from the installer parent too.
%% The helper gives child processes a tiny fresh environment and disables pip
%% configuration. Runtime AWS sessions retain their existing credential chain.
bootstrap_environment() ->
    [{Name, false} || Entry <- os:getenv(),
        Name <- [hd(string:split(Entry, "="))],
        lists:any(fun(Prefix) -> lists:prefix(Prefix, Name) end,
            ["AWS_", "PYTHON", "PIP_", "UV_", "VIRTUAL_ENV", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
             "http_proxy", "https_proxy", "all_proxy"])].
current_signature() ->
    Keys = [aws_setup_enabled, aws_setup_python, aws_setup_bootstrap_python,
            aws_setup_runtime_dir, aws_setup_runtime_auto_install,
            aws_setup_runtime_timeout_seconds, aws_setup_wheelhouse],
    Values = [application:get_env(ecai, Key) || Key <- Keys],
    Root = try ecai_paths:runtime_dir() catch _:_ -> invalid end,
    Requirements = try file:read_file(filename:join([code:priv_dir(ecai), "aws_setup", "requirements.txt"]))
                   catch _:_ -> invalid end,
    erlang:md5(term_to_binary({Values, Root, Requirements})).
same_settings(S) -> maps:get(signature, S) =:= current_signature().

packet(Bytes, S) ->
    try
        case jsx:decode(Bytes, [return_maps]) of
        #{<<"phase">> := <<"ready">>, <<"ok">> := true, <<"python">> := Path,
          <<"versions">> := Versions} = R when is_binary(Path), is_map(Versions) ->
            _ = absolute_path(Path),
            S#{result := maps:with([<<"ok">>, <<"python">>, <<"mode">>, <<"versions">>, <<"reused">>], R)};
        #{<<"phase">> := <<"failed">>, <<"error">> := Code} when is_binary(Code) ->
            S#{result := #{<<"ok">> => false, <<"error">> => safe_code(Code)}};
        #{<<"phase">> := Phase} ->
            case lists:member(Phase, [<<"checking">>, <<"waiting_for_lock">>, <<"creating">>,
                                     <<"installing">>, <<"verifying">>]) of
                true -> S#{info := (maps:get(info, S))#{<<"phase">> => Phase, <<"message">> => phase_message(Phase)}};
                false -> finish_error(<<"invalid_health_output">>, close_port(S))
            end;
        _ -> finish_error(<<"invalid_health_output">>, close_port(S))
        end
    catch _:_ -> finish_error(<<"invalid_health_output">>, close_port(S)) end.
finish_error(Code, S) ->
    N = min(5, maps:get(failures, S) + 1),
    schedule(min(900000, 60000 * (1 bsl (N - 1))), cancel_deadline(S#{port := undefined,
        result := undefined, failures := N, info := info(<<"failed">>, safe_code(Code))})).
schedule(Ms, S) ->
    Ref = erlang:start_timer(Ms, self(), check),
    S#{timer := Ref, info := (maps:get(info, S))#{<<"next_check_at_ms">> => now_ms() + Ms}}.
cancel_timer(#{timer := Ref} = S) -> cancel(Ref), S#{timer := undefined}.
cancel_deadline(#{deadline := Ref} = S) -> cancel(Ref), S#{deadline := undefined}.
cancel(Ref) when is_reference(Ref) -> erlang:cancel_timer(Ref), ok;
cancel(_) -> ok.
close_port(#{port := Port} = S) when is_port(Port) ->
    %% Send cancellation before closing the pipe. runtime.py kills its child
    %% process group; it also detects EOF if this node exits unexpectedly.
    try port_command(Port, <<"x">>) catch _:_ -> ok end,
    try erlang:port_close(Port) catch _:_ -> ok end,
    S#{port := undefined};
close_port(S) -> S.
info(Phase, Code) -> #{<<"phase">> => Phase, <<"ready">> => false,
    <<"error">> => Code, <<"message">> => case Code of <<>> -> phase_message(Phase); _ -> error_message(Code) end}.
now_ms() -> erlang:system_time(millisecond).
phase_message(<<"disabled">>) -> <<"Local AWS helper is disabled with automatic setup.">>;
phase_message(<<"ready">>) -> <<"Local Python and AWS SDK checks passed. This is not AWS account or permission verification.">>;
phase_message(<<"creating">>) -> <<"Creating the node-local AWS virtual environment.">>;
phase_message(<<"installing">>) -> <<"Installing the bundled AWS dependency requirements into the managed environment.">>;
phase_message(<<"waiting_for_lock">>) -> <<"Waiting for another local runtime initializer to finish.">>;
phase_message(<<"verifying">>) -> <<"Verifying SDK imports, pinned versions and pip dependency consistency.">>;
phase_message(_) -> <<"Checking the local AWS helper environment; credential intake is paused until checks pass.">>.
safe_code(Code) ->
    case error_message(Code) of
        <<"Local AWS helper initialization failed. Inspect node configuration and retry.">> -> <<"runtime_bootstrap_failed">>;
        _ -> Code
    end.
error_message(<<"python_too_old">>) -> <<"The local AWS helper requires Python 3.11 or newer.">>;
error_message(<<"bootstrap_python_missing">>) -> <<"Install Python 3 or set aws_setup_bootstrap_python to its executable.">>;
error_message(<<"bootstrap_start_failed">>) -> <<"Cannot execute bootstrap Python. Check its path, permissions and runtime.py deployment.">>;
error_message(<<"venv_creation_failed">>) -> <<"Python could not create a virtual environment. Install the OS venv/ensurepip support and check disk permissions.">>;
error_message(<<"dependency_install_failed">>) -> <<"Dependency installation failed. Check PyPI DNS/TLS access or configure an offline aws_setup_wheelhouse. Automatic retry is scheduled.">>;
error_message(<<"dependency_check_failed">>) -> <<"AWS SDK imports or pinned versions failed. Explicit Python paths are check-only; repair that environment or choose aws_setup_python=auto.">>;
error_message(<<"pip_check_failed">>) -> <<"pip check found inconsistent dependencies. Repair the explicit environment or use a dedicated managed environment.">>;
error_message(<<"automatic_install_disabled">>) -> <<"No healthy managed environment exists and aws_setup_runtime_auto_install is false.">>;
error_message(<<"unsafe_runtime_directory">>) -> <<"Managed runtime directory is unsafe. Use a service-owned directory, not a symlink or group/world-writable location.">>;
error_message(<<"runtime_directory_not_writable">>) -> <<"The node cannot write its managed runtime directory. Fix ownership or configure aws_setup_runtime_dir.">>;
error_message(<<"runtime_directory_unavailable">>) -> <<"Managed runtime directory is unavailable. Check the data mount and permissions.">>;
error_message(<<"runtime_timeout">>) -> <<"Local runtime initialization timed out; it will retry with backoff.">>;
error_message(<<"runtime_cancelled">>) -> <<"Local runtime initialization was cancelled.">>;
error_message(<<"invalid_requirements">>) -> <<"Bundled requirements must contain reviewed exact package pins. Check the deployed requirements.txt.">>;
error_message(<<"invalid_external_interpreter">>) -> <<"aws_setup_python must be auto or an absolute Python executable path.">>;
error_message(<<"invalid_wheelhouse">>) -> <<"aws_setup_wheelhouse must point to an existing absolute directory of approved wheels.">>;
error_message(<<"invalid_runtime_settings">>) -> <<"Invalid local runtime settings. Check absolute paths, boolean flags and timeout (10-1800 seconds).">>;
error_message(<<"invalid_runtime_manifest">>) -> <<"Managed runtime manifest is invalid. Inspect the directory; it will not be overwritten automatically.">>;
error_message(<<"invalid_health_output">>) -> <<"The local helper returned an invalid health response; credential intake stays blocked.">>;
error_message(<<"runtime_not_started">>) -> <<"Local runtime supervisor is not running. Compile and restart the updated ECAI application.">>;
error_message(<<"runtime_settings_changed">>) -> <<"Runtime settings changed. Waiting for the next local check; ecai_aws_setup_runtime:recheck() requests one now.">>;
error_message(_) -> <<"Local AWS helper initialization failed. Inspect node configuration and retry.">>.
