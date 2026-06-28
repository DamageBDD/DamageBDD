%%--------------------------------------------------------------------
%% DamageBDD steps for Arch Linux AUR/eBPF supply-chain compromise checks.
%% Uses erlexec for OS command execution, following steps_cmd.erl style.
%%--------------------------------------------------------------------
-module(steps_arch_aur_ebpf).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6, step_dry/6]).

-define(NS, arch_aur_ebpf).
-define(DEFAULT_SINCE, <<"2026-06-11">>).
-define(DEFAULT_AFFECTED_LIST_URL, <<"https://md.archlinux.org/s/SxbqukK6IA">>).

%% erlfmt:ignore-begin
-define(S_AUDIT_WINDOW, ["the Arch AUR audit window starts at", Since]).
-define(S_AFFECTED_FILE, ["the affected AUR package list file is", Path]).
-define(S_AFFECTED_URL, ["the affected AUR package list URL is", Url]).
-define(S_FETCH_LATEST_AFFECTED_TO_IPFS, ["I fetch the latest affected AUR package list and store it in IPFS"]).
-define(S_FETCH_LATEST_AFFECTED_TO_IPFS_VAR, ["I fetch the latest affected AUR package list and store IPFS hash in", Variable]).
-define(S_FETCH_LATEST_AFFECTED_URL_TO_IPFS, ["I fetch the latest affected AUR package list from", Url, "and store it in IPFS"]).
-define(S_FETCH_LATEST_AFFECTED_URL_TO_IPFS_VAR, ["I fetch the latest affected AUR package list from", Url, "and store IPFS hash in", Variable]).
-define(S_STORE_LATEST_AFFECTED_CID, ["the affected AUR package list IPFS hash should be stored in", Variable]).
-define(S_AFFECTED_IPFS_LIST, ["the affected AUR package list IPFS hash is", Hash]).
-define(S_IPFS_BUNDLE_HASH, ["the Arch AUR eBPF artifact bundle IPFS hash is", Hash]).
-define(S_FETCH_IPFS_BUNDLE, ["I fetch the Arch AUR eBPF artifact bundle to", Directory]).
-define(S_FETCH_IPFS_HASH_TO_PATH, ["I fetch IPFS hash", Hash, "to Arch AUR artifact path", Path]).
-define(S_WRITE_REPORT_ARTIFACT, ["I write the Arch AUR eBPF vulnerability report artifact to", Path]).
-define(S_PUT_ARTIFACTS, ["I put the Arch AUR eBPF vulnerability artifacts from", Path, "to IPFS and store hash in", Variable]).
-define(S_PIN_IPFS_HASH, ["I pin the Arch AUR eBPF vulnerability IPFS hash", Hash]).
-define(S_ADD_AUR_SCAN_DIR, ["I add Arch AUR scan directory", Path]).
-define(S_ADD_CACHE_SCAN_DIR, ["I add npm or bun cache scan directory", Path]).
-define(S_COLLECT, ["I collect Arch AUR eBPF vulnerability evidence"]).
-define(S_NO_AFFECTED, ["no known affected AUR package is installed"]).
-define(S_NO_AUR_IOC, ["no Atomic Arch IOC appears in AUR build files"]).
-define(S_NO_CACHE_IOC, ["no Atomic Arch IOC appears in npm or bun caches"]).
-define(S_NO_SYSTEMD, ["no suspicious systemd persistence is present"]).
-define(S_NO_EBPF, ["no suspicious eBPF artifact is present"]).
-define(S_BPF_DISABLED, ["unprivileged BPF loading is disabled"]).
-define(S_FULL_PASS, ["the Arch AUR eBPF vulnerability check passes"]).
-define(S_PRINT_REPORT, ["I print the Arch AUR eBPF vulnerability report"]).
%% erlfmt:ignore-end

-spec step(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().
-spec step_dry(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().

step_dry(Config, Context, Keyword, LineNo, Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, _Keyword, _N, ?S_AUDIT_WINDOW, _Body) ->
    SinceBin = trim_quotes(to_bin(Since)),
    case valid_date(SinceBin) of
        true -> update_ns(Context, fun(NS) -> NS#{since => SinceBin} end);
        false -> fail(Context, "Invalid audit window date ~p; expected YYYY-MM-DD", [SinceBin])
    end;
step(_Config, Context, _Keyword, _N, ?S_AFFECTED_FILE, _Body) ->
    PathBin = trim_quotes(to_bin(Path)),
    case file:read_file(to_s(PathBin)) of
        {ok, Bin} ->
            Packages = parse_package_lines(Bin),
            update_ns(Context, fun(NS) -> NS#{affected_packages => Packages} end);
        {error, Reason} ->
            fail(Context, "Affected AUR package list file ~p is unreadable: ~p", [PathBin, Reason])
    end;
step(_Config, Context, _Keyword, _N, ?S_AFFECTED_URL, _Body) ->
    UrlBin = trim_quotes(to_bin(Url)),
    update_ns(Context, fun(NS) -> NS#{affected_packages_url => UrlBin} end);
step(_Config, Context, _Keyword, _N, ?S_FETCH_LATEST_AFFECTED_TO_IPFS, _Body) ->
    UrlBin = maps:get(affected_packages_url, ns(Context), ?DEFAULT_AFFECTED_LIST_URL),
    fetch_latest_affected_list_to_ipfs(Context, UrlBin, undefined);
step(_Config, Context, _Keyword, _N, ?S_FETCH_LATEST_AFFECTED_TO_IPFS_VAR, _Body) ->
    UrlBin = maps:get(affected_packages_url, ns(Context), ?DEFAULT_AFFECTED_LIST_URL),
    VariableBin = trim_quotes(to_bin(Variable)),
    fetch_latest_affected_list_to_ipfs(Context, UrlBin, VariableBin);
step(_Config, Context, _Keyword, _N, ?S_FETCH_LATEST_AFFECTED_URL_TO_IPFS, _Body) ->
    UrlBin = trim_quotes(to_bin(Url)),
    fetch_latest_affected_list_to_ipfs(Context, UrlBin, undefined);
step(_Config, Context, _Keyword, _N, ?S_FETCH_LATEST_AFFECTED_URL_TO_IPFS_VAR, _Body) ->
    UrlBin = trim_quotes(to_bin(Url)),
    VariableBin = trim_quotes(to_bin(Variable)),
    fetch_latest_affected_list_to_ipfs(Context, UrlBin, VariableBin);
step(_Config, Context, _Keyword, _N, ?S_STORE_LATEST_AFFECTED_CID, _Body) ->
    VariableBin = trim_quotes(to_bin(Variable)),
    case maps:get(affected_packages_ipfs_hash, ns(Context), undefined) of
        undefined ->
            fail(Context, "No affected AUR package list IPFS hash has been stored", []);
        HashBin ->
            store_var(VariableBin, HashBin, Context)
    end;
step(_Config, Context, _Keyword, _N, ?S_AFFECTED_IPFS_LIST, _Body) ->
    HashBin = trim_quotes(to_bin(Hash)),
    case ipfs_cat(HashBin) of
        {ok, Bin} ->
            Packages = parse_package_lines(Bin),
            update_ns(Context, fun(NS) ->
                NS#{
                    affected_packages => Packages,
                    affected_packages_ipfs_hash => HashBin
                }
            end);
        {error, Reason} ->
            fail(Context, "Affected AUR package list IPFS hash ~p could not be read: ~p", [
                HashBin, Reason
            ])
    end;
step(_Config, Context, _Keyword, _N, ?S_IPFS_BUNDLE_HASH, _Body) ->
    HashBin = trim_quotes(to_bin(Hash)),
    update_ns(Context, fun(NS) -> NS#{ipfs_bundle_hash => HashBin} end);
step(_Config, Context, _Keyword, _N, ?S_FETCH_IPFS_BUNDLE, _Body) ->
    DirectoryBin = trim_quotes(to_bin(Directory)),
    DirectoryPath = to_s(DirectoryBin),
    NS0 = ns(Context),
    case maps:get(ipfs_bundle_hash, NS0, undefined) of
        undefined ->
            fail(Context, "Arch AUR eBPF artifact bundle IPFS hash was not configured", []);
        HashBin ->
            case ipfs_fetch_to(HashBin, DirectoryPath) of
                {ok, _} ->
                    update_ns(Context, fun(NS1) ->
                        load_package_list_from_artifact_dir(
                            DirectoryPath,
                            NS1#{
                                artifact_dir => DirectoryPath,
                                ipfs_bundle_fetch => #{hash => HashBin, path => DirectoryBin}
                            }
                        )
                    end);
                {error, Reason} ->
                    fail(Context, "IPFS bundle fetch failed hash=~p path=~p reason=~p", [
                        HashBin, DirectoryBin, Reason
                    ])
            end
    end;
step(_Config, Context, _Keyword, _N, ?S_FETCH_IPFS_HASH_TO_PATH, _Body) ->
    HashBin = trim_quotes(to_bin(Hash)),
    PathBin = trim_quotes(to_bin(Path)),
    case ipfs_fetch_to(HashBin, to_s(PathBin)) of
        {ok, _} ->
            update_ns(Context, fun(NS) ->
                Artifacts0 = maps:get(ipfs_fetched_artifacts, NS, []),
                NS#{ipfs_fetched_artifacts => [#{hash => HashBin, path => PathBin} | Artifacts0]}
            end);
        {error, Reason} ->
            fail(Context, "IPFS artifact fetch failed hash=~p path=~p reason=~p", [
                HashBin, PathBin, Reason
            ])
    end;
step(_Config, Context, _Keyword, _N, ?S_WRITE_REPORT_ARTIFACT, _Body) ->
    PathBin = trim_quotes(to_bin(Path)),
    PathString = to_s(PathBin),
    Report = report(ensure_collected(Context)),
    case write_artifact(PathString, Report) of
        ok ->
            update_ns(Context, fun(NS) ->
                Artifacts0 = maps:get(local_artifacts, NS, []),
                NS#{local_artifacts => [PathBin | Artifacts0]}
            end);
        {error, Reason} ->
            fail(Context, "Could not write Arch AUR eBPF report artifact ~p: ~p", [
                PathBin, Reason
            ])
    end;
step(_Config, Context, _Keyword, _N, ?S_PUT_ARTIFACTS, _Body) ->
    PathBin = trim_quotes(to_bin(Path)),
    VariableName = trim_quotes(to_bin(Variable)),
    case ipfs_add_path(PathBin) of
        {ok, HashBin, AddResult} ->
            Context1 =
                update_ns(Context, fun(NS) ->
                    Published0 = maps:get(ipfs_published_artifacts, NS, []),
                    NS#{
                        ipfs_published_artifacts =>
                            [#{path => PathBin, hash => HashBin, result => AddResult} | Published0]
                    }
                end),
            store_var(VariableName, HashBin, Context1);
        {error, Reason} ->
            fail(Context, "Could not put Arch AUR eBPF artifacts to IPFS from ~p: ~p", [
                PathBin, Reason
            ])
    end;
step(_Config, Context, _Keyword, _N, ?S_PIN_IPFS_HASH, _Body) ->
    HashBin = trim_quotes(to_bin(Hash)),
    case ipfs_pin(HashBin) of
        ok ->
            Context;
        {ok, _} ->
            Context;
        {error, Reason} ->
            fail(Context, "Could not pin Arch AUR eBPF IPFS hash ~p: ~p", [HashBin, Reason])
    end;
step(_Config, Context, _Keyword, _N, ?S_ADD_AUR_SCAN_DIR, _Body) ->
    PathBin = trim_quotes(to_bin(Path)),
    update_ns(Context, fun(NS) ->
        NS#{aur_dirs => lists:usort([to_s(PathBin) | maps:get(aur_dirs, NS, default_aur_dirs())])}
    end);
step(_Config, Context, _Keyword, _N, ?S_ADD_CACHE_SCAN_DIR, _Body) ->
    PathBin = trim_quotes(to_bin(Path)),
    update_ns(Context, fun(NS) ->
        NS#{
            cache_dirs => lists:usort([
                to_s(PathBin) | maps:get(cache_dirs, NS, default_cache_dirs())
            ])
        }
    end);
step(_Config, Context, _Keyword, _N, ?S_COLLECT, _Body) ->
    collect(Context);
step(_Config, Context, _Keyword, _N, ?S_NO_AFFECTED, _Body) ->
    assert_no_affected_package(ensure_collected(Context));
step(_Config, Context, _Keyword, _N, ?S_NO_AUR_IOC, _Body) ->
    assert_empty_findings(
        ensure_collected(Context), aur_findings, "Atomic Arch IOC found in AUR build files"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_CACHE_IOC, _Body) ->
    assert_empty_findings(
        ensure_collected(Context), cache_findings, "Atomic Arch IOC found in npm/bun caches"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_SYSTEMD, _Body) ->
    assert_empty_findings(
        ensure_collected(Context), systemd_findings, "Suspicious systemd persistence found"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_EBPF, _Body) ->
    assert_no_ebpf_artifacts(ensure_collected(Context));
step(_Config, Context, _Keyword, _N, ?S_BPF_DISABLED, _Body) ->
    assert_bpf_hardened(ensure_collected(Context));
step(_Config, Context, _Keyword, _N, ?S_FULL_PASS, _Body) ->
    assert_full_pass(ensure_collected(Context));
step(_Config, Context, _Keyword, _N, ?S_PRINT_REPORT, _Body) ->
    ?LOG_INFO("~s", [report(Context)]),
    Context.

%% --------------------------------------------------------------------
%% IPFS artifact/list helpers
%% --------------------------------------------------------------------

fetch_latest_affected_list_to_ipfs(Context, UrlBin0, StoreVar) ->
    UrlBin = trim_quotes(to_bin(UrlBin0)),
    FetchCmd = fetch_url(UrlBin),
    case cmd_ok(FetchCmd) of
        false ->
            fail(Context, "Could not fetch affected AUR package list from ~p: ~p", [
                UrlBin, summarize_cmd(FetchCmd)
            ]);
        true ->
            Raw = maps:get(stdout, FetchCmd, <<>>),
            Packages = parse_affected_packages_report(Raw),
            case Packages of
                [] ->
                    fail(
                        Context,
                        "Fetched affected AUR package list from ~p but parsed 0 packages",
                        [UrlBin]
                    );
                _ ->
                    Canonical = canonical_package_list(Packages),
                    FileName = "arch-aur-affected-packages.txt",
                    case ipfs_add_data(Canonical, FileName) of
                        {ok, HashBin, AddResult} ->
                            Context1 = update_ns(Context, fun(NS) ->
                                NS#{
                                    affected_packages => Packages,
                                    affected_packages_url => UrlBin,
                                    affected_packages_fetch_cmd => FetchCmd,
                                    affected_packages_count => length(Packages),
                                    affected_packages_sha256 => sha256_hex(Canonical),
                                    affected_packages_ipfs_hash => HashBin,
                                    affected_packages_ipfs_add => AddResult
                                }
                            end),
                            case StoreVar of
                                undefined -> Context1;
                                _ -> store_var(StoreVar, HashBin, Context1)
                            end;
                        {error, Reason} ->
                            fail(
                                Context,
                                "Fetched affected AUR package list but IPFS add failed: ~p",
                                [
                                    Reason
                                ]
                            )
                    end
            end
    end.

fetch_url(UrlBin) ->
    run_cmd("curl", ["-fsSL", to_s(UrlBin)]).

ipfs_add_data(Data, FileName) ->
    try damage_ipfs:add({data, Data, FileName}) of
        AddResult ->
            case extract_ipfs_hash(AddResult, FileName) of
                {ok, HashBin} -> {ok, HashBin, AddResult};
                {error, _} = Error -> Error
            end
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

ipfs_cat(HashBin) ->
    try damage_ipfs:cat(HashBin) of
        {ok, Bin} when is_binary(Bin) ->
            {ok, Bin};
        Bin when is_binary(Bin) ->
            {ok, Bin};
        Other ->
            {error, Other}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

ipfs_fetch_to(HashBin, OutPath0) ->
    OutPath = to_s(OutPath0),
    ok = damage_utils:ensure_dir(filename:dirname(OutPath) ++ "/"),
    try damage_ipfs:fetch_to(HashBin, OutPath) of
        ok ->
            {ok, OutPath};
        {ok, _} = Ok ->
            Ok;
        Other ->
            {error, Other}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

ipfs_pin(HashBin) ->
    try damage_ipfs:pin([HashBin]) of
        ok ->
            ok;
        {ok, _} = Ok ->
            Ok;
        Other ->
            {error, Other}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

ipfs_add_path(PathBin) ->
    Path = to_s(PathBin),
    AddArg =
        case filelib:is_dir(Path) of
            true ->
                {directory, Path};
            false ->
                case filelib:is_file(Path) of
                    true -> {file, Path};
                    false -> {missing, Path}
                end
        end,
    case AddArg of
        {missing, _} ->
            {error, {missing_path, PathBin}};
        _ ->
            try damage_ipfs:add(AddArg) of
                AddResult ->
                    case extract_ipfs_hash(AddResult, Path) of
                        {ok, HashBin} -> {ok, HashBin, AddResult};
                        {error, _} = Error -> Error
                    end
            catch
                Class:Reason:Stack ->
                    {error, {Class, Reason, Stack}}
            end
    end.

extract_ipfs_hash({ok, #{<<"Hash">> := Hash}}, _Path) ->
    {ok, to_bin(Hash)};
extract_ipfs_hash({ok, #{hash := Hash}}, _Path) ->
    {ok, to_bin(Hash)};
extract_ipfs_hash({ok, List}, Path) when is_list(List) ->
    Base = to_bin(filename:basename(Path)),
    Maps = [M || M <- List, is_map(M)],
    NamedHashes = [
        to_bin(maps:get(<<"Hash">>, M))
     || M <- Maps,
        maps:is_key(<<"Hash">>, M),
        maps:get(<<"Name">>, M, undefined) =:= Base
    ],
    AllHashes = [to_bin(maps:get(<<"Hash">>, M)) || M <- Maps, maps:is_key(<<"Hash">>, M)],
    case {NamedHashes, AllHashes} of
        {[Hash | _], _} -> {ok, Hash};
        {[], []} -> {error, {no_hash_in_ipfs_add_result, List}};
        {[], Hashes} -> {ok, lists:last(Hashes)}
    end;
extract_ipfs_hash(#{<<"Hash">> := Hash}, _Path) ->
    {ok, to_bin(Hash)};
extract_ipfs_hash(#{hash := Hash}, _Path) ->
    {ok, to_bin(Hash)};
extract_ipfs_hash(Other, _Path) ->
    {error, {bad_ipfs_add_result, Other}}.

load_package_list_from_artifact_dir(DirectoryPath, NS0) ->
    case first_existing_file(package_list_candidates(DirectoryPath)) of
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    NS0#{
                        affected_packages => parse_package_lines(Bin),
                        affected_packages_file => to_bin(Path)
                    };
                {error, _} ->
                    NS0
            end;
        not_found ->
            NS0
    end.

package_list_candidates(DirectoryPath) ->
    [
        filename:join(DirectoryPath, "affected-aur-packages.txt"),
        filename:join(DirectoryPath, "affected_packages.txt"),
        filename:join(DirectoryPath, "aur-affected-packages.txt"),
        filename:join(DirectoryPath, "packages.txt"),
        filename:join(DirectoryPath, "list.txt")
    ].

first_existing_file([]) ->
    not_found;
first_existing_file([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> {ok, Path};
        false -> first_existing_file(Rest)
    end.

write_artifact(Path, Data) ->
    case damage_utils:ensure_dir(filename:dirname(Path) ++ "/") of
        ok -> file:write_file(Path, Data);
        Error -> Error
    end.

store_var(VariableNameBin, Value, Context) ->
    maps:put(list_to_atom(to_s(VariableNameBin)), Value, Context).

%% --------------------------------------------------------------------
%% Collection
%% --------------------------------------------------------------------

collect(Context0) ->
    NS0 = ns(Context0),
    Since = maps:get(since, NS0, ?DEFAULT_SINCE),
    AURDirs = existing_dirs(maps:get(aur_dirs, NS0, default_aur_dirs())),
    CacheDirs = existing_dirs(maps:get(cache_dirs, NS0, default_cache_dirs())),
    SystemdDirs = existing_dirs(maps:get(systemd_dirs, NS0, default_systemd_dirs())),

    PacmanCmd = run_cmd("pacman", ["-Qmq"]),
    ForeignPackages = cmd_stdout_lines(PacmanCmd),

    AurGrep = grep_iocs(AURDirs, aur),
    CacheGrep = grep_iocs(CacheDirs, cache),
    SystemdGrep = grep_iocs(SystemdDirs, systemd),

    BpfPinCmds = bpf_pin_cmds(),
    BpfPins = bpf_pin_hits(BpfPinCmds),
    BpfProgCmd = sudo_run_cmd("bpftool", ["prog", "show"]),
    BpfMapCmd = sudo_run_cmd("bpftool", ["map", "show"]),
    SysctlCmd = run_cmd("sysctl", ["-n", "kernel.unprivileged_bpf_disabled"]),

    Evidence = #{
        since => Since,
        affected_packages => maps:get(affected_packages, NS0, []),
        affected_packages_url => maps:get(affected_packages_url, NS0, ?DEFAULT_AFFECTED_LIST_URL),
        affected_packages_count => length(maps:get(affected_packages, NS0, [])),
        affected_packages_ipfs_hash => maps:get(affected_packages_ipfs_hash, NS0, undefined),
        affected_packages_sha256 => maps:get(affected_packages_sha256, NS0, undefined),
        foreign_packages_cmd => PacmanCmd,
        foreign_packages => ForeignPackages,
        pacman_events_since => pacman_events_since(Since),
        aur_dirs => AURDirs,
        aur_grep_cmd => maps:get(cmd, AurGrep),
        aur_findings => maps:get(findings, AurGrep),
        cache_dirs => CacheDirs,
        cache_grep_cmd => maps:get(cmd, CacheGrep),
        cache_findings => maps:get(findings, CacheGrep),
        systemd_dirs => SystemdDirs,
        systemd_grep_cmd => maps:get(cmd, SystemdGrep),
        systemd_findings => maps:get(findings, SystemdGrep),
        bpf_pin_cmds => BpfPinCmds,
        bpf_pin_findings => BpfPins,
        bpf_prog_cmd => BpfProgCmd,
        bpf_prog_findings => lines_matching_iocs(cmd_stdout_lines(BpfProgCmd)),
        bpf_map_cmd => BpfMapCmd,
        bpf_map_findings => lines_matching_iocs(cmd_stdout_lines(BpfMapCmd)),
        bpf_hardening_cmd => SysctlCmd,
        bpf_hardening => first_line(SysctlCmd)
    },

    put_ns(Context0, NS0#{evidence => Evidence}).

%% --------------------------------------------------------------------
%% Assertions
%% --------------------------------------------------------------------

assert_no_affected_package(Context) ->
    E = evidence(Context),
    case cmd_ok(maps:get(foreign_packages_cmd, E, #{})) of
        false ->
            fail(Context, "pacman -Qmq failed: ~p", [maps:get(foreign_packages_cmd, E, #{})]);
        true ->
            Affected = maps:get(affected_packages, E, []),
            Foreign = maps:get(foreign_packages, E, []),
            case Affected of
                [] ->
                    fail(Context, "No affected AUR package list loaded", []);
                _ ->
                    Hits = [Pkg || Pkg <- Foreign, lists:member(Pkg, Affected)],
                    case Hits of
                        [] -> Context;
                        _ -> fail(Context, "Affected AUR packages are installed: ~p", [Hits])
                    end
            end
    end.

assert_empty_findings(Context, Key, Message) ->
    E = evidence(Context),
    Cmd = maps:get(scan_cmd_key(Key), E, #{ok => true, status => skipped}),
    case {grep_command_ok(Cmd), maps:get(Key, E, [])} of
        {false, _} ->
            fail(Context, "~s scan command failed: ~p", [Message, summarize_cmd(Cmd)]);
        {true, []} ->
            Context;
        {true, Findings} ->
            fail(Context, "~s: ~p", [Message, Findings])
    end.

grep_command_ok(#{status := 0}) -> true;
grep_command_ok(#{status := 1}) -> true;
grep_command_ok(#{status := skipped}) -> true;
grep_command_ok(#{ok := true}) -> true;
grep_command_ok(_) -> false.

scan_cmd_key(aur_findings) -> aur_grep_cmd;
scan_cmd_key(cache_findings) -> cache_grep_cmd;
scan_cmd_key(systemd_findings) -> systemd_grep_cmd;
scan_cmd_key(_) -> undefined.

assert_no_ebpf_artifacts(Context) ->
    E = evidence(Context),
    ToolErrors = ebpf_tool_errors(E),
    Findings =
        maps:get(bpf_pin_findings, E, []) ++
            maps:get(bpf_prog_findings, E, []) ++
            maps:get(bpf_map_findings, E, []),
    case {ToolErrors, Findings} of
        {[], []} ->
            Context;
        {Errors, []} ->
            fail(Context, "eBPF inspection was incomplete or failed closed: ~p", [Errors]);
        {_Errors, Hits} ->
            fail(Context, "Suspicious eBPF artifacts found: ~p", [Hits])
    end.

assert_bpf_hardened(Context) ->
    E = evidence(Context),
    Cmd = maps:get(bpf_hardening_cmd, E, #{}),
    case cmd_ok(Cmd) of
        false ->
            fail(Context, "Could not read kernel.unprivileged_bpf_disabled: ~p", [Cmd]);
        true ->
            case maps:get(bpf_hardening, E, undefined) of
                <<"1">> ->
                    Context;
                <<"2">> ->
                    Context;
                <<"0">> ->
                    fail(
                        Context,
                        "kernel.unprivileged_bpf_disabled is 0; unprivileged BPF loading is enabled",
                        []
                    );
                Other ->
                    fail(Context, "Unexpected kernel.unprivileged_bpf_disabled value: ~p", [Other])
            end
    end.

assert_full_pass(Context0) ->
    Checks = [
        fun assert_no_affected_package/1,
        fun(C) ->
            assert_empty_findings(C, aur_findings, "Atomic Arch IOC found in AUR build files")
        end,
        fun(C) ->
            assert_empty_findings(C, cache_findings, "Atomic Arch IOC found in npm/bun caches")
        end,
        fun(C) ->
            assert_empty_findings(C, systemd_findings, "Suspicious systemd persistence found")
        end,
        fun assert_no_ebpf_artifacts/1,
        fun assert_bpf_hardened/1
    ],
    lists:foldl(
        fun
            (_Check, #{fail := _} = Failed) -> Failed;
            (Check, Ctx) -> Check(Ctx)
        end,
        Context0,
        Checks
    ).

%% --------------------------------------------------------------------
%% erlexec command helpers
%% --------------------------------------------------------------------

run_cmd(Name, Args) ->
    case resolve_exe(Name) of
        {ok, Exe} ->
            Res =
                try
                    exec:run([Exe | [to_s(A) || A <- Args]], [sync, stdout, stderr, {cd, "/"}])
                catch
                    Class:Reason:Stack -> {exec_crash, Class, Reason, Stack}
                end,
            normalize_exec(Name, Args, Res);
        {error, Reason} ->
            #{
                ok => false,
                name => to_bin(Name),
                args => [to_bin(A) || A <- Args],
                status => 127,
                stdout => <<>>,
                stderr => to_bin(Reason)
            }
    end.

sudo_run_cmd(Name, Args) ->
    case {resolve_exe("sudo"), resolve_exe(Name)} of
        {{ok, Sudo}, {ok, Exe}} ->
            FullArgs = ["-n", Exe | [to_s(A) || A <- Args]],
            Res =
                try
                    exec:run([Sudo | FullArgs], [sync, stdout, stderr, {cd, "/"}])
                catch
                    Class:Reason:Stack -> {exec_crash, Class, Reason, Stack}
                end,
            normalize_exec("sudo", FullArgs, Res);
        {{error, Reason}, _} ->
            #{
                ok => false,
                name => <<"sudo">>,
                args => [to_bin(Name) | [to_bin(A) || A <- Args]],
                status => 127,
                stdout => <<>>,
                stderr => to_bin(Reason)
            };
        {_, {error, Reason}} ->
            #{
                ok => false,
                name => to_bin(Name),
                args => [to_bin(A) || A <- Args],
                status => 127,
                stdout => <<>>,
                stderr => to_bin(Reason)
            }
    end.

normalize_exec(Name, Args, {ok, Props}) ->
    #{
        ok => true,
        name => to_bin(Name),
        args => [to_bin(A) || A <- Args],
        status => 0,
        stdout => prop_iolist(stdout, Props),
        stderr => prop_iolist(stderr, Props)
    };
normalize_exec(Name, Args, {error, Props}) when is_list(Props) ->
    Status = proplists:get_value(exit_status, Props, 1),
    #{
        ok => false,
        name => to_bin(Name),
        args => [to_bin(A) || A <- Args],
        status => Status,
        stdout => prop_iolist(stdout, Props),
        stderr => prop_iolist(stderr, Props)
    };
normalize_exec(Name, Args, Other) ->
    #{
        ok => false,
        name => to_bin(Name),
        args => [to_bin(A) || A <- Args],
        status => unknown,
        stdout => <<>>,
        stderr => to_bin(io_lib:format("~p", [Other]))
    }.

prop_iolist(Key, Props) ->
    iolist_to_binary(proplists:get_value(Key, Props, [])).

cmd_ok(#{ok := true}) -> true;
cmd_ok(_) -> false.

cmd_stdout_lines(Cmd) when is_map(Cmd) ->
    split_lines(maps:get(stdout, Cmd, <<>>));
cmd_stdout_lines(_) ->
    [].

first_line(Cmd) ->
    case cmd_stdout_lines(Cmd) of
        [Line | _] -> Line;
        [] -> undefined
    end.

resolve_exe(Name0) ->
    Name = to_s(Name0),
    case os:find_executable(Name) of
        false -> resolve_exe_candidates(Name, exe_candidates(Name));
        Path -> {ok, Path}
    end.

resolve_exe_candidates(_Name, []) ->
    {error, "missing executable"};
resolve_exe_candidates(Name, [Path | Rest]) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> resolve_exe_candidates(Name, Rest)
    end.

exe_candidates(Name) ->
    [filename:join(Dir, Name) || Dir <- ["/usr/bin", "/usr/sbin", "/bin", "/sbin"]].

%% --------------------------------------------------------------------
%% Grep/find evidence helpers
%% --------------------------------------------------------------------

grep_iocs([], _Mode) ->
    #{cmd => #{ok => true, status => skipped, stdout => <<>>, stderr => <<>>}, findings => []};
grep_iocs(Dirs, aur) ->
    Args =
        [
            "-RInE",
            aur_regex(),
            "--include=PKGBUILD",
            "--include=*.install",
            "--include=package.json",
            "--include=package-lock.json",
            "--include=bun.lock",
            "--"
        ] ++ Dirs,
    Cmd = run_cmd("grep", Args),
    #{cmd => Cmd, findings => grep_findings(Cmd)};
grep_iocs(Dirs, cache) ->
    Cmd = run_cmd("grep", ["-RInE", cache_regex(), "--"] ++ Dirs),
    #{cmd => Cmd, findings => grep_findings(Cmd)};
grep_iocs(Dirs, systemd) ->
    Cmd = run_cmd(
        "grep",
        [
            "-RInE",
            systemd_regex(),
            "--include=*.service",
            "--include=*.timer",
            "--include=*.socket",
            "--include=*.path",
            "--"
        ] ++ Dirs
    ),
    #{cmd => Cmd, findings => grep_findings(Cmd)}.

grep_findings(Cmd) ->
    %% grep returns 0 when it finds matches and 1 when it finds no matches.
    %% exec marks non-zero as {error, ...}; for detection we only care stdout lines.
    cmd_stdout_lines(Cmd).

aur_regex() ->
    "atomic-lockfile|js-digest|lockfile-js|npm[[:space:]]+install|bun[[:space:]]+(add|install)".

cache_regex() ->
    "atomic-lockfile|js-digest|lockfile-js".

systemd_regex() ->
    "atomic-lockfile|js-digest|lockfile-js|npm|bun|node|/tmp/\\.|/dev/shm|hidden_pids|hidden_names|hidden_inodes".

bpf_pin_cmds() ->
    [
        sudo_run_cmd("find", ["/sys/fs/bpf", "-maxdepth", "5", "-type", "f"]),
        sudo_run_cmd("find", ["/sys/fs/bpf", "-maxdepth", "5", "-type", "l"])
    ].

bpf_pin_hits(Cmds) ->
    lines_matching_iocs(lists:flatmap(fun cmd_stdout_lines/1, Cmds)).

lines_matching_iocs(Lines) ->
    Iocs = [
        <<"atomic-lockfile">>,
        <<"js-digest">>,
        <<"lockfile-js">>,
        <<"hidden_pids">>,
        <<"hidden_names">>,
        <<"hidden_inodes">>
    ],
    [Line || Line <- Lines, lists:any(fun(Ioc) -> contains(Line, Ioc) end, Iocs)].

ebpf_tool_errors(E) ->
    PinErrors = [Cmd || Cmd <- maps:get(bpf_pin_cmds, E, []), not cmd_ok(Cmd)],
    ProgCmd = maps:get(bpf_prog_cmd, E, #{}),
    MapCmd = maps:get(bpf_map_cmd, E, #{}),
    Errors0 = PinErrors ++ [C || C <- [ProgCmd, MapCmd], not cmd_ok(C)],
    [summarize_cmd(C) || C <- Errors0].

summarize_cmd(Cmd) ->
    #{
        name => maps:get(name, Cmd, undefined),
        args => maps:get(args, Cmd, []),
        status => maps:get(status, Cmd, undefined),
        stderr => maps:get(stderr, Cmd, <<>>)
    }.

%% --------------------------------------------------------------------
%% Pacman log helpers
%% --------------------------------------------------------------------

pacman_events_since(Since) ->
    case file:read_file("/var/log/pacman.log") of
        {ok, Bin} ->
            [
                Line
             || Line <- split_lines(Bin),
                pacman_line_since(Line, Since),
                pacman_install_or_upgrade(Line)
            ];
        {error, _} ->
            []
    end.

pacman_line_since(<<"[", Date:10/binary, _/binary>>, Since) ->
    Date >= Since;
pacman_line_since(_, _) ->
    false.

pacman_install_or_upgrade(Line) ->
    contains(Line, <<"[ALPM] installed">>) orelse contains(Line, <<"[ALPM] upgraded">>).

%% --------------------------------------------------------------------
%% Context/report helpers
%% --------------------------------------------------------------------

ensure_collected(Context) ->
    case maps:get(evidence, ns(Context), undefined) of
        undefined -> collect(Context);
        _ -> Context
    end.

ns(Context) ->
    maps:merge(default_ns(), maps:get(?NS, Context, #{})).

put_ns(Context, NS) ->
    maps:put(?NS, NS, Context).

update_ns(Context, Fun) ->
    put_ns(Context, Fun(ns(Context))).

evidence(Context) ->
    maps:get(evidence, ns(Context), #{}).

default_ns() ->
    #{
        since => ?DEFAULT_SINCE,
        affected_packages_url => ?DEFAULT_AFFECTED_LIST_URL,
        affected_packages => [],
        aur_dirs => default_aur_dirs(),
        cache_dirs => default_cache_dirs(),
        systemd_dirs => default_systemd_dirs(),
        evidence => undefined
    }.

report(Context) ->
    Ctx = ensure_collected(Context),
    E = evidence(Ctx),
    iolist_to_binary(
        io_lib:format(
            "Arch AUR/eBPF vulnerability report~n"
            "since=~p~n"
            "foreign_packages=~p~n"
            "pacman_events_since=~p~n"
            "aur_findings=~p~n"
            "cache_findings=~p~n"
            "systemd_findings=~p~n"
            "bpf_pin_findings=~p~n"
            "bpf_prog_findings=~p~n"
            "bpf_map_findings=~p~n"
            "bpf_hardening=~p~n"
            "affected_packages_url=~p~n"
            "affected_packages_count=~p~n"
            "affected_packages_ipfs_hash=~p~n"
            "affected_packages_sha256=~p~n",
            [
                maps:get(since, E, undefined),
                maps:get(foreign_packages, E, []),
                maps:get(pacman_events_since, E, []),
                maps:get(aur_findings, E, []),
                maps:get(cache_findings, E, []),
                maps:get(systemd_findings, E, []),
                maps:get(bpf_pin_findings, E, []),
                maps:get(bpf_prog_findings, E, []),
                maps:get(bpf_map_findings, E, []),
                maps:get(bpf_hardening, E, undefined),
                maps:get(affected_packages_url, ns(Ctx), undefined),
                length(maps:get(affected_packages, E, [])),
                maps:get(affected_packages_ipfs_hash, ns(Ctx), undefined),
                maps:get(affected_packages_sha256, ns(Ctx), undefined)
            ]
        )
    ).

fail(Context, Fmt, Args) ->
    maps:put(fail, damage_utils:strf(Fmt, Args), Context).

%% --------------------------------------------------------------------
%% Generic helpers
%% --------------------------------------------------------------------

default_aur_dirs() ->
    Home = home_dir(),
    [
        filename:join([Home, ".cache", "yay"]),
        filename:join([Home, ".cache", "paru"]),
        filename:join([Home, ".cache", "pikaur"]),
        filename:join([Home, ".cache", "aurutils"])
    ].

default_cache_dirs() ->
    Home = home_dir(),
    [filename:join([Home, ".npm"]), filename:join([Home, ".bun"])].

default_systemd_dirs() ->
    Home = home_dir(),
    ["/etc/systemd/system", filename:join([Home, ".config", "systemd", "user"])].

existing_dirs(Dirs) ->
    [D || D <- [to_s(D0) || D0 <- Dirs], filelib:is_dir(D)].

home_dir() ->
    case os:getenv("HOME") of
        false -> "/tmp";
        Home -> Home
    end.

parse_package_lines(Bin) ->
    [Line || Line <- split_lines(Bin), Line =/= <<>>, not starts_with(Line, <<"#">>)].

parse_affected_packages_report(Raw) ->
    %% Matches the shell reference:
    %%   sed 's/<[^>]*>//g' | grep -E '^[a-z0-9][a-z0-9_.+-]*[a-z0-9]$' | sort -u
    Stripped = strip_html(Raw),
    lists:usort([Line || Line <- split_lines(Stripped), sane_pkgname(Line)]).

strip_html(Bin) ->
    re:replace(to_bin(Bin), <<"<[^>]*>">>, <<>>, [global, {return, binary}]).

sane_pkgname(Line) ->
    case re:run(Line, <<"^[a-z0-9][a-z0-9_.+-]*[a-z0-9]$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

canonical_package_list(Packages) ->
    iolist_to_binary([[Pkg, <<"\n">>] || Pkg <- lists:usort(Packages)]).

sha256_hex(Bin) ->
    lower_hex(crypto:hash(sha256, to_bin(Bin))).

lower_hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

valid_date(Bin) ->
    case re:run(Bin, <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

split_lines(Bin) when is_binary(Bin) ->
    [
        Line
     || Line <- [trim(Line0) || Line0 <- binary:split(Bin, <<"\n">>, [global])], Line =/= <<>>
    ].

contains(Haystack, Needle) ->
    binary:match(to_bin(Haystack), to_bin(Needle)) =/= nomatch.

starts_with(Bin, Prefix) ->
    Size = byte_size(Prefix),
    byte_size(Bin) >= Size andalso binary:part(Bin, 0, Size) =:= Prefix.

trim_quotes(<<"\"", Rest/binary>>) ->
    Size = byte_size(Rest),
    case Size > 0 andalso binary:at(Rest, Size - 1) =:= $" of
        true -> binary:part(Rest, 0, Size - 1);
        false -> Rest
    end;
trim_quotes(Bin) ->
    Bin.

trim(Bin) ->
    trim_right(trim_left(to_bin(Bin))).

trim_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trim_left(Rest);
trim_left(Bin) ->
    Bin.

trim_right(Bin) ->
    Size = byte_size(Bin),
    case Size of
        0 ->
            Bin;
        _ ->
            Last = binary:at(Bin, Size - 1),
            case Last of
                $\s -> trim_right(binary:part(Bin, 0, Size - 1));
                $\t -> trim_right(binary:part(Bin, 0, Size - 1));
                $\n -> trim_right(binary:part(Bin, 0, Size - 1));
                $\r -> trim_right(binary:part(Bin, 0, Size - 1));
                _ -> Bin
            end
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> unicode:characters_to_binary(io_lib:format("~p", [T])).

to_s(B) when is_binary(B) -> unicode:characters_to_list(B);
to_s(L) when is_list(L) -> L;
to_s(A) when is_atom(A) -> atom_to_list(A);
to_s(I) when is_integer(I) -> integer_to_list(I);
to_s(T) -> unicode:characters_to_list(to_bin(T)).
