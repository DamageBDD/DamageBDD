%% -------------------------------------------------------------------
%% damage_sys_tune.erl
%% Auto-calculates sane limits from machine specs and applies them.
%% - NOFILE scales with cores and RAM
%% - somaxconn scales with NOFILE
%% - fs.file-max scales with NOFILE
%% Uses damage_priv:sudo_ui/1 to elevate if sysctl needs privileges.
%% -------------------------------------------------------------------
-module(damage_sys_tune).
-include_lib("kernel/include/logger.hrl").

-export([
    tune/0,
    tune/1,
    raise_nofile/1,
    maybe_sysctl/2,
    log_current_limits/0,
    get_env_int/2,
    recommended_limits/0
]).

%% ========== Public API ==========

%% @doc Convenience: compute + apply recommended limits
tune() ->
    %% Allow override via env if user insists
    case os:getenv("DAMAGE_NOFILE") of
        false ->
            Limits = recommended_limits(),
            ?LOG_INFO("Auto OS tuning: ~p", [Limits]),
            apply_limits(Limits);
        _ ->
            %% Keep backwards compat: if env is present, use explicit numeric
            Desired = get_env_int("DAMAGE_NOFILE", 100000),
            ?LOG_INFO("OS tuning (env override). Target nofile=~p", [Desired]),
            apply_limits(#{nofile => Desired,
                           somaxconn => min(max(4096, Desired div 4), 65535),
                           file_max => Desired * 2})
    end.

%% @doc Direct call with explicit nofile target (rarely needed)
tune(DesiredNOFILE) when is_integer(DesiredNOFILE), DesiredNOFILE > 0 ->
    apply_limits(#{nofile => DesiredNOFILE,
                   somaxconn => min(max(4096, DesiredNOFILE div 4), 65535),
                   file_max => DesiredNOFILE * 2}).

%% ========== Core logic ==========

apply_limits(#{nofile := NoFile, somaxconn := Somax, file_max := FileMax} = _L) ->
    _ = raise_nofile(NoFile),
    %% Best-effort; may need elevation. We never crash on failure.
    _ = maybe_sysctl("net.core.somaxconn", integer_to_list(Somax)),
    _ = maybe_sysctl("fs.file-max", integer_to_list(FileMax)),
    log_current_limits(),
    ok.

%% @doc Compute recommended limits based on cores and RAM.
-spec recommended_limits() -> #{nofile := integer(), somaxconn := integer(), file_max := integer()}.
recommended_limits() ->
    Cores = get_cpu_cores(),
    RamMB = get_total_mem_mb(),
    %% Target NOFILE: (4000 * cores * 2) + 20% buffer
    Target = Cores * 4000 * 2,
    Buffer = round(Target * 0.20),
    RawNoFile = Target + Buffer,
    %% Safety: ensure FD memory (≈2KB per FD) stays small vs RAM
    MaxByRam = max_for_ram(RamMB),
    NoFile = min(RawNoFile, MaxByRam),
    Somax = min(max(4096, NoFile div 4), 65535),
    FileMax = NoFile * 2,
    #{nofile => NoFile, somaxconn => Somax, file_max => FileMax}.

%% ~2 KB kernel memory per FD; keep << RAM
max_for_ram(RamMB) ->
    %% Allow up to 10% of RAM for FD metadata: (RamMB * 1024 KB * 0.10) / 2 KB
    (RamMB * 1024) div 20.

%% ========== Privileged ops (reuse your previous helpers) ==========

%% @doc Raise RLIMIT_NOFILE for the running BEAM using prlimit
raise_nofile(DesiredNOFILE) ->
    PidStr = os:getpid(),
    case os:find_executable("prlimit") of
        false ->
            ?LOG_WARNING(
              "prlimit not found. Can't raise RLIMIT_NOFILE for pid ~s. "
              "Consider systemd LimitNOFILE= or wrapper ulimit before exec.",
              [PidStr]),
            {error, prlimit_not_found};
        Pr ->
            Cmd = io_lib:format("~s --pid ~s --nofile=~p:~p",
                                [Pr, PidStr, DesiredNOFILE, DesiredNOFILE]),
            case exec:run(lists:flatten(Cmd), [sync, stdout, stderr]) of
                {ok, _Out} ->
                    ?LOG_INFO("Raised RLIMIT_NOFILE for pid ~s to ~p.", [PidStr, DesiredNOFILE]),
                    ok;
                {error, {_Status, Out}} ->
                    ?LOG_ERROR("Failed to raise RLIMIT_NOFILE via prlimit: ~s", [Out]),
                    {error, prlimit_failed}
            end
    end.

%% @doc Best-effort sysctl set. Auto-escalates via damage_priv if permission denied.
maybe_sysctl(Key, Val) ->
    case os:find_executable("sysctl") of
        false ->
            ?LOG_DEBUG("sysctl not found; skipping ~s", [Key]),
            ok;
        Sysctl ->
            Cmd = io_lib:format("~s -w ~s=~s", [Sysctl, Key, Val]),
            Flat = lists:flatten(Cmd),
            case exec:run(Flat, [sync, stdout, stderr]) of
                {ok, _} ->
                    ?LOG_INFO("sysctl set ~s=~s", [Key, Val]),
                    ok;
                {error, {_Status, Out}} ->
                    case catch damage_priv:permission_denied(Out) of
                        true ->
                            ?LOG_WARNING("sysctl ~s=~s permission denied; attempting elevation…",
                                         [Key, Val]),
                            case damage_priv:sudo_ui(Flat) of
                                {ok, _} ->
                                    ?LOG_INFO("sysctl (elevated) set ~s=~s", [Key, Val]),
                                    ok;
                                Err ->
                                    ?LOG_WARNING("Elevated sysctl failed: ~p", [Err]),
                                    {error, sysctl_failed}
                            end;
                        _ ->
                            ?LOG_WARNING("sysctl ~s=~s failed: ~s", [Key, Val, Out]),
                            {error, sysctl_failed}
                    end
            end
    end.

%% ========== Introspection ==========

log_current_limits() ->
    case file:read_file("/proc/self/limits") of
        {ok, Bin} ->
            case find_nofile_line(binary_to_list(Bin)) of
                undefined -> ?LOG_DEBUG("Could not parse /proc/self/limits for NOFILE."), ok;
                {Soft, Hard} ->
                    ?LOG_INFO("Current NOFILE soft=~p hard=~p (from /proc/self/limits).",
                              [Soft, Hard]),
                    ok
            end;
        _ -> ok
    end.

find_nofile_line(Text) ->
    Lines = string:split(Text, "\n", all),
    case lists:filter(fun(L) -> lists:prefix("Max open files", string:trim(L)) end, Lines) of
        [Line|_] ->
            Norm = re:replace(Line, "\\s+", " ", [global, {return, list}]),
            case string:tokens(Norm, " ") of
                ["Max","open","files",SoftStr,HardStr|_] ->
                    {to_int(SoftStr), to_int(HardStr)};
                _ -> undefined
            end;
        _ -> undefined
    end.

to_int(S) ->
    case catch list_to_integer(S) of
        I when is_integer(I) -> I;
        _ -> 0
    end.

get_env_int(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Val ->
            case (catch list_to_integer(Val)) of
                I when is_integer(I), I > 0 -> I;
                _ -> Default
            end
    end.

%% ========== Platform facts ==========

get_cpu_cores() ->
    case os:type() of
        {unix, linux} ->
            case file:read_file("/proc/cpuinfo") of
                {ok, Bin} ->
                    length([L || L <- string:split(binary_to_list(Bin), "\n", all),
                                 string:prefix(L, "processor")]);
                _ -> getenv_int_default("NUMBER_OF_PROCESSORS", 4)
            end;
        {unix, darwin} ->
            run_int_or_default("sysctl -n hw.logicalcpu", 4);
        {win32, _} ->
            getenv_int_default("NUMBER_OF_PROCESSORS", 4);
        _ -> 4
    end.

get_total_mem_mb() ->
    case os:type() of
        {unix, linux} ->
            case file:read_file("/proc/meminfo") of
                {ok, Bin} ->
                    %% MemTotal: <kB>
                    case re:run(Bin, "MemTotal:\\s+([0-9]+)\\s+kB",
                                [{capture, [1], list}]) of
                        {match, [NumStr]} -> list_to_integer(NumStr) div 1024;
                        _ -> 4096
                    end;
                _ -> 4096
            end;
        {unix, darwin} ->
            run_int_or_default("sysctl -n hw.memsize", 4*1024*1024*1024) div (1024*1024);
        {win32, _} ->
            %% Not typical for your deployment; safe default
            4096;
        _ -> 4096
    end.

run_int_or_default(Cmd, Default) ->
    case exec:run(Cmd, [sync, stdout]) of
        {ok, Out} ->
            Str = string:trim(Out),
            case catch list_to_integer(Str) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        _ -> Default
    end.

getenv_int_default(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        V ->
            case catch list_to_integer(V) of
                I when is_integer(I) -> I;
                _ -> Default
            end
    end.

