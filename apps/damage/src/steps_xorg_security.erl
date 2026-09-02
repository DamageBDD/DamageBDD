%%%-------------------------------------------------------------------
%%% steps_xorg_security.erl
%%%
%%% DamageBDD verification steps for a hardened X.Org/Xwayland runtime.
%%%
%%% This module is intentionally read-only.  It inspects the active server,
%%% its /proc state, Xauthority metadata, X11 sockets, Xorg/Xwayland versions,
%%% X extensions, Xorg configuration, Xorg.wrap policy, and sshd X11 policy.
%%%
%%% It never reads or prints Xauthority cookies and it never invokes a shell.
%%% External tools are launched with erlexec's argv form so user/context values
%%% are not interpreted as shell syntax.
%%%
%%% Strict profile notes:
%%%   * Xorg >= 21.1.24
%%%   * Xwayland >= 24.1.13 when present
%%%   * rootless server and no setuid Xorg executable
%%%   * no TCP/inet listener and no XDMCP
%%%   * no -ac / +iglx / +byteswappedclients / -background none / -core
%%%   * byte-swapped clients explicitly disabled
%%%   * private Xauthority with restrictive ownership/mode
%%%   * X access control enabled; no broad xhost entries
%%%   * XTEST, RECORD and XFree86-DGA not advertised
%%%   * AllowNonLocalXvidtune, IndirectGLX, IgnoreABI disabled
%%%   * Xorg configuration/module paths are not group/world writable
%%%   * /tmp/.X11-unix is root-owned and sticky
%%%   * Xorg.wrap does not permit anybody / force root rights
%%%   * sshd X11Forwarding disabled when sshd is installed
%%%   * SELinux enforcing when SELinux is present
%%%-------------------------------------------------------------------
-module(steps_xorg_security).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([step/6, step_dry/6]).
-export([audit/1, strict_errors/1]).

-define(MIN_XORG, {21, 1, 24}).
-define(MIN_XWAYLAND, {24, 1, 13}).

-define(S_AUDIT_ACTIVE, ["I audit the active Xorg server"]).
-define(S_AUDIT_DISPLAY, ["I audit Xorg display", Display]).
-define(S_AUTH_FILE, ["I use Xorg authority file", Path]).
-define(S_STRICT, ["Xorg should satisfy the strict security profile"]).
-define(S_ROOTLESS, ["Xorg should be rootless"]).
-define(S_NETWORK, ["Xorg network transports should be hardened"]).
-define(S_AUTH, ["Xorg authorization should be hardened"]).
-define(S_EXTENSIONS, ["Xorg dangerous extensions should be disabled"]).
-define(S_COMPAT, ["Xorg unsafe compatibility modes should be disabled"]).
-define(S_XDMCP, ["Xorg XDMCP should be disabled"]).
-define(S_SSH, ["Xorg SSH X11 forwarding should be disabled"]).
-define(S_PATHS, ["Xorg configuration and module paths should be root controlled"]).
-define(S_PATCHED, ["Xorg should include current upstream security fixes"]).
-define(S_PRINT, ["I print the Xorg security audit"]).

-type severity() :: error | warning | info.
-type finding() :: #{
    severity := severity(),
    check := atom(),
    message := binary()
}.

%%%===================================================================
%%% DamageBDD steps
%%%===================================================================

%% Keep dry-run matching explicit.  A catch-all step_dry/6 here would claim
%% unrelated steps and break DamageBDD's module pre-check/matching semantics.
step_dry(Config, Context, Keyword, LineNo, ["I audit the active Xorg server"] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["I audit Xorg display", _Display] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["I use Xorg authority file", _Path] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["Xorg should satisfy the strict security profile"] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["Xorg should be rootless"] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config, Context, Keyword, LineNo, ["Xorg network transports should be hardened"] = Args, Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["Xorg authorization should be hardened"] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config, Context, Keyword, LineNo, ["Xorg dangerous extensions should be disabled"] = Args, Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["Xorg unsafe compatibility modes should be disabled"] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["Xorg XDMCP should be disabled"] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config, Context, Keyword, LineNo, ["Xorg SSH X11 forwarding should be disabled"] = Args, Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["Xorg configuration and module paths should be root controlled"] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["Xorg should include current upstream security fixes"] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ["I print the Xorg security audit"] = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, _Keyword, _N, ?S_AUDIT_ACTIVE, _Body) ->
    run_audit(Context);
step(_Config, Context, _Keyword, _N, ?S_AUDIT_DISPLAY, _Body) ->
    run_audit(Context#{xorg_display => to_bin(Display)});
step(_Config, Context, _Keyword, _N, ?S_AUTH_FILE, _Body) ->
    maps:put(xorg_authority, to_bin(Path), Context);
step(_Config, Context0, <<"Then">>, _N, ?S_STRICT, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, all);
step(_Config, Context0, <<"Then">>, _N, ?S_ROOTLESS, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [runtime_identity, executable]);
step(_Config, Context0, <<"Then">>, _N, ?S_NETWORK, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [network, abstract_socket]);
step(_Config, Context0, <<"Then">>, _N, ?S_AUTH, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [authorization, xhost, socket_dir]);
step(_Config, Context0, <<"Then">>, _N, ?S_EXTENSIONS, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [extensions]);
step(_Config, Context0, <<"Then">>, _N, ?S_COMPAT, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [server_args, xorg_config]);
step(_Config, Context0, <<"Then">>, _N, ?S_XDMCP, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [xdmcp]);
step(_Config, Context0, <<"Then">>, _N, ?S_SSH, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [sshd, ssh_client]);
step(_Config, Context0, <<"Then">>, _N, ?S_PATHS, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [paths, wrapper]);
step(_Config, Context0, <<"Then">>, _N, ?S_PATCHED, _Body) ->
    Context = ensure_audited(Context0),
    assert_categories(Context, [version]);
step(_Config, Context0, <<"Then">>, _N, ?S_PRINT, _Body) ->
    Context = ensure_audited(Context0),
    Report = maps:get(xorg_security_report, Context, <<>>),
    ?LOG_NOTICE("Xorg security audit:\n~s", [Report]),
    Context.

%%%===================================================================
%%% Public audit API
%%%===================================================================

-spec audit(map()) -> map().
audit(Context) ->
    Processes0 = find_x_servers(),
    Processes = select_processes(Processes0, maps:get(xorg_display, Context, undefined)),
    Base =
        case Processes of
            [] ->
                [
                    err(
                        runtime_identity,
                        <<"No active Xorg/Xwayland process could be identified in /proc">>
                    )
                ];
            _ ->
                []
        end,
    ProcFindings = lists:append([audit_process(P, Context) || P <- Processes]),
    GlobalFindings =
        audit_socket_dir() ++
            audit_xorg_config(Processes) ++
            audit_xwrapper() ++
            audit_sshd() ++
            audit_ssh_client() ++
            audit_selinux(),
    Findings = dedupe_findings(Base ++ ProcFindings ++ GlobalFindings),
    #{
        generated_at => erlang:system_time(second),
        profile => strict,
        minimum_xorg => version_bin(?MIN_XORG),
        minimum_xwayland => version_bin(?MIN_XWAYLAND),
        processes => [public_process(P) || P <- Processes],
        findings => Findings,
        errors => [F || #{severity := error} = F <- Findings],
        warnings => [F || #{severity := warning} = F <- Findings]
    }.

-spec strict_errors(map()) -> [finding()].
strict_errors(#{findings := Findings}) ->
    [F || #{severity := error} = F <- Findings];
strict_errors(_) ->
    [err(runtime_identity, <<"Xorg audit data is missing">>)].

run_audit(Context) ->
    Audit = audit(Context),
    Report = format_report(Audit),
    maps:put(xorg_security_report, Report, maps:put(xorg_security_audit, Audit, Context)).

ensure_audited(#{xorg_security_audit := _} = Context) ->
    Context;
ensure_audited(Context) ->
    run_audit(Context).

assert_categories(Context, all) ->
    Audit = maps:get(xorg_security_audit, Context),
    apply_assertion(Context, strict_errors(Audit));
assert_categories(Context, Categories) ->
    Audit = maps:get(xorg_security_audit, Context),
    Errors = [
        F
     || #{severity := error, check := Check} = F <- maps:get(findings, Audit, []),
        lists:member(Check, Categories)
    ],
    apply_assertion(Context, Errors).

apply_assertion(Context, []) ->
    Context;
apply_assertion(Context, Errors) ->
    maps:put(fail, format_errors(Errors), Context).

%%%===================================================================
%%% Per-process checks
%%%===================================================================

audit_process(Proc, Context) ->
    audit_runtime_identity(Proc) ++
        audit_executable(Proc) ++
        audit_version(Proc) ++
        audit_server_args(Proc) ++
        audit_network(Proc) ++
        audit_abstract_socket(Proc) ++
        audit_xdmcp(Proc) ++
        audit_authorization(Proc, Context) ++
        audit_host_file(Proc) ++
        audit_xhost(Proc, Context) ++
        audit_extensions(Proc, Context).

audit_runtime_identity(#{pid := Pid, kind := Kind} = Proc) ->
    Uid = maps:get(uid, Proc, undefined),
    Identity =
        case Uid of
            0 ->
                [
                    err(
                        runtime_identity,
                        fmt("~s pid ~B is running as root; require a rootless X server", [
                            kind_s(Kind), Pid
                        ])
                    )
                ];
            I when is_integer(I) ->
                [info(runtime_identity, fmt("~s pid ~B runs as uid ~B", [kind_s(Kind), Pid, I]))];
            _ ->
                [err(runtime_identity, fmt("Could not determine uid for X server pid ~B", [Pid]))]
        end,
    CapEff = maps:get(cap_eff, Proc, undefined),
    Caps =
        case CapEff of
            0 ->
                [info(runtime_identity, <<"X server has no effective Linux capabilities">>)];
            C when is_integer(C) ->
                [
                    err(
                        runtime_identity,
                        fmt("X server retains effective Linux capabilities: 0x~.16B", [C])
                    )
                ];
            _ ->
                [warn(runtime_identity, <<"Could not verify X server effective capability mask">>)]
        end,
    NoNewPrivs =
        case maps:get(no_new_privs, Proc, undefined) of
            1 ->
                [info(runtime_identity, <<"X server has NoNewPrivs enabled">>)];
            0 ->
                [
                    warn(
                        runtime_identity,
                        <<"X server does not have NoNewPrivs enabled; consider service-level sandbox hardening">>
                    )
                ];
            _ ->
                []
        end,
    Seccomp =
        case maps:get(seccomp, Proc, undefined) of
            2 ->
                [info(runtime_identity, <<"X server is running under a seccomp filter">>)];
            0 ->
                [
                    warn(
                        runtime_identity,
                        <<"X server has no seccomp filter; consider a tested display-manager/systemd sandbox profile">>
                    )
                ];
            1 ->
                [
                    warn(
                        runtime_identity,
                        <<"X server is in strict seccomp mode; verify graphics/input compatibility">>
                    )
                ];
            _ ->
                []
        end,
    Identity ++ Caps ++ NoNewPrivs ++ Seccomp.

audit_executable(#{exe := undefined, pid := Pid}) ->
    [err(executable, fmt("Cannot resolve executable for X server pid ~B", [Pid]))];
audit_executable(#{exe := Exe}) ->
    case secure_system_file(Exe, require_root) of
        {ok, Info} ->
            Mode = Info#file_info.mode,
            Setuid = (Mode band 8#4000) =/= 0,
            Writable = (Mode band 8#0022) =/= 0,
            F0 =
                case Setuid of
                    true ->
                        [
                            err(
                                executable,
                                fmt("X server executable ~s has the setuid bit set", [Exe])
                            )
                        ];
                    false ->
                        []
                end,
            F1 =
                case Writable of
                    true ->
                        [
                            err(
                                executable,
                                fmt("X server executable ~s is group/world writable", [Exe])
                            )
                            | F0
                        ];
                    false ->
                        F0
                end,
            case F1 of
                [] ->
                    [
                        info(
                            executable,
                            fmt("X server executable ~s is not setuid or group/world writable", [
                                Exe
                            ])
                        )
                    ];
                _ ->
                    lists:reverse(F1)
            end;
        {error, Reason} ->
            [err(executable, fmt("Cannot verify X server executable ~s: ~p", [Exe, Reason]))]
    end.

audit_version(#{kind := Kind, exe := Exe}) when Exe =/= undefined ->
    Min = min_version(Kind),
    case read_x_version(Exe) of
        {ok, Version, Raw} ->
            case version_at_least(Version, Min) of
                true ->
                    [
                        info(
                            version,
                            fmt("~s version ~s satisfies minimum ~s", [
                                kind_s(Kind), version_s(Version), version_s(Min)
                            ])
                        )
                    ];
                false ->
                    [
                        err(
                            version,
                            fmt("~s version ~s is below security baseline ~s (~s)", [
                                kind_s(Kind), version_s(Version), version_s(Min), truncate(Raw, 180)
                            ])
                        )
                    ]
            end;
        {error, Reason} ->
            [
                err(
                    version,
                    fmt("Cannot verify ~s security patch level from ~s: ~p", [
                        kind_s(Kind), Exe, Reason
                    ])
                )
            ]
    end;
audit_version(#{kind := Kind}) ->
    [
        err(
            version,
            fmt("Cannot verify ~s version because executable is unresolved", [kind_s(Kind)])
        )
    ].

audit_server_args(#{kind := xwayland}) ->
    %% Xwayland has a different option surface.  Network and version checks still
    %% apply; Xorg-only command-line hardening is not required here.
    [info(server_args, <<"Xwayland detected; Xorg-only server flag checks skipped">>)];
audit_server_args(#{argv := Args}) ->
    Checks = [
        {has_arg(Args, <<"-ac">>), <<"-ac disables X access control">>},
        {
            has_arg(Args, <<"+iglx">>),
            <<"+iglx enables indirect GLX and its protocol parsing attack surface">>
        },
        {
            has_arg(Args, <<"+byteswappedclients">>),
            <<"+byteswappedclients permits opposite-endian clients">>
        },
        {
            has_arg(Args, <<"-allowNonLocalXvidtune">>),
            <<"-allowNonLocalXvidtune exposes the VidMode tuning interface to non-local clients">>
        },
        {
            has_arg(Args, <<"-ignoreABI">>),
            <<"-ignoreABI allows potentially incompatible Xorg modules to load">>
        },
        {
            has_arg_pair(Args, <<"-background">>, <<"none">>),
            <<"-background none may expose contents from a previous session during reset/startup">>
        },
        {
            has_arg(Args, <<"-core">>),
            <<"-core enables server core dumps which may disclose display/session memory">>
        },
        {
            has_any_arg(Args, [<<"-query">>, <<"-broadcast">>, <<"-multicast">>, <<"-indirect">>]),
            <<"XDMCP command-line mode is enabled">>
        },
        {has_listen_inet(Args), <<"X server command line explicitly enables TCP/INET transport">>}
    ],
    Errors = [err(server_args, Msg) || {true, Msg} <- Checks],
    ByteSwapDisabled = has_arg(Args, <<"-byteswappedclients">>) orelse config_byteswap_disabled(),
    ByteSwapFinding =
        case ByteSwapDisabled of
            true ->
                [info(server_args, <<"Byte-swapped X11 clients are explicitly disabled">>)];
            false ->
                [
                    err(
                        server_args,
                        <<"Byte-swapped X11 clients are not explicitly disabled; use -byteswappedclients or Option \"AllowByteSwappedClients\" \"false\"">>
                    )
                ]
        end,
    case Errors of
        [] -> [info(server_args, <<"No insecure Xorg server flags were found">>) | ByteSwapFinding];
        _ -> Errors ++ ByteSwapFinding
    end.

audit_network(#{pid := Pid, display := Display}) ->
    Ports = listening_tcp_ports(Pid),
    case display_number(Display) of
        N when is_integer(N), N >= 0, N =< 59535 ->
            Port = 6000 + N,
            case lists:member(Port, Ports) of
                true ->
                    [
                        err(
                            network,
                            fmt("X display ~s has TCP transport exposed on port ~B", [Display, Port])
                        )
                    ];
                false ->
                    [
                        info(
                            network,
                            fmt("X display ~s has no TCP listener on port ~B", [Display, Port])
                        )
                    ]
            end;
        _ ->
            XPorts = [P || P <- Ports, P >= 6000, P =< 6063],
            case XPorts of
                [] ->
                    [info(network, <<"No common X11 TCP listener was found on ports 6000-6063">>)];
                _ ->
                    [
                        err(
                            network,
                            fmt("X server namespace has common X11 TCP listener(s): ~p", [
                                lists:usort(XPorts)
                            ])
                        )
                    ]
            end
    end.

audit_abstract_socket(#{pid := Pid, display := Display}) ->
    case display_number(Display) of
        undefined ->
            [
                warn(
                    abstract_socket,
                    <<"Could not derive display number to verify Linux abstract X11 socket exposure">>
                )
            ];
        N ->
            Names = unix_socket_names(Pid),
            Expected = to_bin(io_lib:format("@/tmp/.X11-unix/X~B", [N])),
            case lists:member(Expected, Names) of
                true ->
                    [
                        err(
                            abstract_socket,
                            fmt(
                                "Linux abstract X11 socket ~s is enabled; strict namespace isolation requires -nolisten local",
                                [Expected]
                            )
                        )
                    ];
                false ->
                    [
                        info(
                            abstract_socket,
                            fmt("Linux abstract X11 socket ~s is not exposed", [Expected])
                        )
                    ]
            end
    end.

audit_xdmcp(#{pid := Pid, argv := Args}) ->
    ArgEnabled = has_any_arg(Args, [
        <<"-query">>, <<"-broadcast">>, <<"-multicast">>, <<"-indirect">>
    ]),
    Udp177 = lists:member(177, listening_udp_ports(Pid)),
    case ArgEnabled orelse Udp177 of
        true -> [err(xdmcp, <<"XDMCP is enabled by command line or UDP/177 exposure">>)];
        false -> [info(xdmcp, <<"No XDMCP mode or UDP/177 listener was detected">>)]
    end.

audit_authorization(Proc, Context) ->
    Auth = authority_file(Proc, Context),
    case Auth of
        undefined ->
            [
                err(
                    authorization,
                    <<"No Xauthority file could be established; strict profile requires -auth or an explicit authority path">>
                )
            ];
        Path ->
            audit_authority_file(Path, maps:get(uid, Proc, undefined))
    end.

audit_authority_file(PathBin, ServerUid) ->
    Path = to_list(PathBin),
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            [err(authorization, fmt("Xauthority file ~s is a symlink", [Path]))];
        {ok, #file_info{type = regular, size = Size, mode = Mode, uid = Uid}} ->
            ModeBad = (Mode band 8#0077) =/= 0,
            OwnerBad = not (Uid =:= 0 orelse Uid =:= ServerUid),
            F0 =
                case Size > 0 of
                    true -> [];
                    false -> [err(authorization, fmt("Xauthority file ~s is empty", [Path]))]
                end,
            F1 =
                case ModeBad of
                    true ->
                        [
                            err(
                                authorization,
                                fmt("Xauthority file ~s has group/other permissions ~.8B", [
                                    Path, Mode band 8#0777
                                ])
                            )
                            | F0
                        ];
                    false ->
                        F0
                end,
            F2 =
                case OwnerBad of
                    true ->
                        [
                            err(
                                authorization,
                                fmt(
                                    "Xauthority file ~s is owned by uid ~B, not root/X server uid ~p",
                                    [Path, Uid, ServerUid]
                                )
                            )
                            | F1
                        ];
                    false ->
                        F1
                end,
            case F2 of
                [] ->
                    [
                        info(
                            authorization,
                            fmt("Xauthority file ~s is private and non-empty", [Path])
                        )
                    ];
                _ ->
                    lists:reverse(F2)
            end;
        {ok, #file_info{type = Type}} ->
            [
                err(
                    authorization,
                    fmt("Xauthority path ~s is not a regular file (~p)", [Path, Type])
                )
            ];
        {error, Reason} ->
            [err(authorization, fmt("Cannot stat Xauthority file ~s: ~p", [Path, Reason]))]
    end.

audit_host_file(#{display := Display}) ->
    case display_number(Display) of
        undefined ->
            [warn(xhost, <<"Cannot derive /etc/Xn.hosts path because display number is unknown">>)];
        N ->
            Path = lists:flatten(io_lib:format("/etc/X~B.hosts", [N])),
            case file:read_file(Path) of
                {error, enoent} ->
                    [info(xhost, fmt("Legacy host ACL file ~s is absent", [Path]))];
                {ok, Bin} ->
                    Clean = trim_bin(strip_comments(Bin)),
                    case Clean of
                        <<>> ->
                            [
                                info(
                                    xhost,
                                    fmt("Legacy host ACL file ~s contains no active hosts", [Path])
                                )
                            ];
                        _ ->
                            [
                                err(
                                    xhost,
                                    fmt(
                                        "Legacy host ACL file ~s contains active host-based access entries",
                                        [Path]
                                    )
                                )
                            ]
                    end;
                {error, Reason} ->
                    [err(xhost, fmt("Cannot inspect legacy host ACL file ~s: ~p", [Path, Reason]))]
            end
    end.

audit_xhost(Proc, Context) ->
    Display = maps:get(display, Proc, undefined),
    Auth = authority_file(Proc, Context),
    case {Display, Auth, first_executable(["/usr/bin/xhost", "/bin/xhost"])} of
        {undefined, _, _} ->
            [warn(xhost, <<"Cannot run xhost because DISPLAY is unknown">>)];
        {_, undefined, _} ->
            [warn(xhost, <<"Cannot run xhost because XAUTHORITY is unknown">>)];
        {_, _, undefined} ->
            [warn(xhost, <<"xhost is not installed; runtime host ACL could not be verified">>)];
        {Display0, Auth0, Xhost} ->
            Env = display_env(Display0, Auth0),
            case run_exec([Xhost], Env) of
                {ok, Out, _Err} ->
                    audit_xhost_output(Out);
                {error, Why, Out, Err} ->
                    [
                        err(
                            xhost,
                            fmt(
                                "xhost failed; cannot verify active access control: ~p stdout=~s stderr=~s",
                                [Why, truncate(Out, 120), truncate(Err, 120)]
                            )
                        )
                    ]
            end
    end.

audit_xhost_output(Out0) ->
    Out = lower_bin(Out0),
    Disabled = binary:match(Out, <<"access control disabled">>) =/= nomatch,
    Lines = [trim_bin(L) || L <- binary:split(Out0, <<"\n">>, [global])],
    Entries = [L || L <- Lines, is_xhost_acl_entry(L)],
    Broad = [L || L <- Entries, is_broad_xhost_entry(L)],
    F0 =
        case Disabled of
            true -> [err(xhost, <<"xhost reports access control disabled">>)];
            false -> []
        end,
    F1 =
        case Broad of
            [] -> F0;
            _ -> [err(xhost, fmt("Broad xhost ACL entries are present: ~p", [Broad])) | F0]
        end,
    case F1 of
        [] ->
            [
                info(
                    xhost,
                    <<"X access control is enabled and no broad xhost ACL entry was detected">>
                )
            ];
        _ ->
            lists:reverse(F1)
    end.

audit_extensions(Proc, Context) ->
    Display = maps:get(display, Proc, undefined),
    Auth = authority_file(Proc, Context),
    case {Display, Auth, first_executable(["/usr/bin/xdpyinfo", "/bin/xdpyinfo"])} of
        {undefined, _, _} ->
            [err(extensions, <<"Cannot inspect X extensions because DISPLAY is unknown">>)];
        {_, undefined, _} ->
            [err(extensions, <<"Cannot inspect X extensions because XAUTHORITY is unknown">>)];
        {_, _, undefined} ->
            [
                err(
                    extensions,
                    <<"xdpyinfo is not installed; strict profile cannot verify dangerous extensions">>
                )
            ];
        {Display0, Auth0, Xdpyinfo} ->
            case run_exec([Xdpyinfo, "-queryExtensions"], display_env(Display0, Auth0)) of
                {ok, Out, _Err} ->
                    ext_findings(Out);
                {error, Why, Out, Err} ->
                    [
                        err(
                            extensions,
                            fmt("xdpyinfo failed: ~p stdout=~s stderr=~s", [
                                Why, truncate(Out, 120), truncate(Err, 120)
                            ])
                        )
                    ]
            end
    end.

ext_findings(Out) ->
    Dangerous = [<<"XTEST">>, <<"RECORD">>, <<"XFree86-DGA">>, <<"XFree86-VidModeExtension">>],
    Present = [E || E <- Dangerous, extension_present(Out, E)],
    case Present of
        [] ->
            [
                info(
                    extensions,
                    <<"XTEST, RECORD, XFree86-DGA and XFree86-VidModeExtension are not advertised">>
                )
            ];
        _ ->
            [
                err(
                    extensions,
                    fmt(
                        "Dangerous/legacy X extensions are advertised: ~p; use -tst, disable XFree86-DGA and enable DisableVidModeExtension",
                        [Present]
                    )
                )
            ]
    end.

%%%===================================================================
%%% Global checks
%%%===================================================================

audit_socket_dir() ->
    Path = "/tmp/.X11-unix",
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory, uid = 0, mode = Mode}} ->
            Sticky = (Mode band 8#1000) =/= 0,
            case Sticky of
                true ->
                    [info(socket_dir, fmt("~s is root-owned and sticky", [Path]))];
                false ->
                    [
                        err(
                            socket_dir,
                            fmt("~s is not sticky (mode ~.8B)", [Path, Mode band 8#07777])
                        )
                    ]
            end;
        {ok, #file_info{type = directory, uid = Uid}} ->
            [err(socket_dir, fmt("~s is owned by uid ~B instead of root", [Path, Uid]))];
        {ok, #file_info{type = Type}} ->
            [err(socket_dir, fmt("~s is not a directory (~p)", [Path, Type]))];
        {error, enoent} ->
            [warn(socket_dir, <<"/tmp/.X11-unix does not exist">>)];
        {error, Reason} ->
            [err(socket_dir, fmt("Cannot inspect /tmp/.X11-unix: ~p", [Reason]))]
    end.

audit_xorg_config(Processes) ->
    Paths = lists:usort(default_config_paths() ++ arg_paths(Processes)),
    Existing = [P || P <- Paths, filelib:is_file(P) orelse filelib:is_dir(P)],
    Content = iolist_to_binary([read_config_tree(P) || P <- Existing]),
    Lower = lower_bin(Content),
    Findings0 =
        bool_option_findings(Lower, [
            {<<"allownonlocalxvidtune">>, xorg_config, <<"AllowNonLocalXvidtune is enabled">>},
            {<<"indirectglx">>, xorg_config, <<"IndirectGLX is enabled">>},
            {<<"ignoreabi">>, xorg_config, <<"IgnoreABI is enabled">>}
        ]),
    ByteSwap = option_bool(Lower, <<"allowbyteswappedclients">>),
    Findings1 =
        case ByteSwap of
            true ->
                [
                    err(xorg_config, <<"AllowByteSwappedClients is enabled in Xorg configuration">>)
                    | Findings0
                ];
            _ ->
                Findings0
        end,
    PathFindings = lists:append([audit_config_path(P) || P <- Existing]),
    Success =
        case Findings1 of
            [] ->
                [
                    info(
                        xorg_config,
                        <<"No insecure Xorg boolean compatibility option was found in known active configuration paths">>
                    )
                ];
            _ ->
                []
        end,
    Success ++ lists:reverse(Findings1) ++ PathFindings.

audit_config_path(Path) ->
    case audit_tree_permissions(Path) of
        [] ->
            [
                info(
                    paths,
                    fmt(
                        "Xorg configuration/module path ~s is root-controlled and not group/world writable",
                        [Path]
                    )
                )
            ];
        Errors ->
            Errors
    end.

audit_xwrapper() ->
    Path = "/etc/X11/Xwrapper.config",
    case file:read_file(Path) of
        {ok, Bin} ->
            Lower = lower_bin(strip_comments(Bin)),
            Anybody = re_match(Lower, <<"(?m)^\\s*allowed_users\\s*=\\s*anybody\\s*$">>),
            ForceRoot = re_match(Lower, <<"(?m)^\\s*needs_root_rights\\s*=\\s*yes\\s*$">>),
            F0 =
                case Anybody of
                    true -> [err(wrapper, <<"Xorg.wrap allows anybody to start Xorg">>)];
                    false -> []
                end,
            F1 =
                case ForceRoot of
                    true ->
                        [
                            err(
                                wrapper,
                                <<"Xorg.wrap forces root rights with needs_root_rights=yes">>
                            )
                            | F0
                        ];
                    false ->
                        F0
                end,
            case F1 of
                [] -> [info(wrapper, <<"Xorg.wrap does not allow anybody or force root rights">>)];
                _ -> lists:reverse(F1)
            end;
        {error, enoent} ->
            [
                info(
                    wrapper,
                    <<"Xorg.wrap configuration is absent; actual runtime uid/setuid checks remain authoritative">>
                )
            ];
        {error, Reason} ->
            [err(wrapper, fmt("Cannot read ~s: ~p", [Path, Reason]))]
    end.

audit_sshd() ->
    case first_executable(["/usr/sbin/sshd", "/usr/bin/sshd", "/sbin/sshd"]) of
        undefined ->
            [info(sshd, <<"sshd is not installed in a standard path">>)];
        Sshd ->
            case run_exec([Sshd, "-T"], []) of
                {ok, Out, _Err} ->
                    Lower = lower_bin(Out),
                    case re_match(Lower, <<"(?m)^x11forwarding\\s+no\\s*$">>) of
                        true ->
                            [info(sshd, <<"sshd effective configuration has X11Forwarding no">>)];
                        false ->
                            [
                                err(
                                    sshd,
                                    <<"sshd effective configuration does not have X11Forwarding no">>
                                )
                            ]
                    end;
                {error, Why, Out, Err} ->
                    [
                        err(
                            sshd,
                            fmt("Cannot verify sshd effective X11 policy: ~p stdout=~s stderr=~s", [
                                Why, truncate(Out, 100), truncate(Err, 160)
                            ])
                        )
                    ]
            end
    end.

audit_ssh_client() ->
    case first_executable(["/usr/bin/ssh", "/bin/ssh"]) of
        undefined ->
            [info(ssh_client, <<"OpenSSH client is not installed in a standard path">>)];
        Ssh ->
            %% -G only prints effective configuration; it does not open a network connection.
            case run_exec([Ssh, "-G", "localhost"], []) of
                {ok, Out, _Err} ->
                    Lower = lower_bin(Out),
                    Forward = re_match(Lower, <<"(?m)^forwardx11\s+yes\s*$">>),
                    Trusted = re_match(Lower, <<"(?m)^forwardx11trusted\s+yes\s*$">>),
                    case {Forward, Trusted} of
                        {false, _} ->
                            [
                                info(
                                    ssh_client,
                                    <<"OpenSSH client effective configuration has ForwardX11 disabled">>
                                )
                            ];
                        {true, true} ->
                            [
                                err(
                                    ssh_client,
                                    <<"OpenSSH client enables trusted X11 forwarding; disable ForwardX11/ForwardX11Trusted">>
                                )
                            ];
                        {true, false} ->
                            [
                                err(
                                    ssh_client,
                                    <<"OpenSSH client enables X11 forwarding by default; strict profile requires ForwardX11 no">>
                                )
                            ]
                    end;
                {error, Why, Out, Err} ->
                    [
                        warn(
                            ssh_client,
                            fmt(
                                "Cannot verify OpenSSH client X11 defaults: ~p stdout=~s stderr=~s",
                                [Why, truncate(Out, 100), truncate(Err, 140)]
                            )
                        )
                    ]
            end
    end.

audit_selinux() ->
    case file:read_file("/sys/fs/selinux/enforce") of
        {ok, Bin} ->
            case trim_bin(Bin) of
                <<"1">> -> [info(mac, <<"SELinux is present and enforcing">>)];
                Other -> [err(mac, fmt("SELinux is present but not enforcing (~s)", [Other]))]
            end;
        {error, enoent} ->
            [
                info(
                    mac,
                    <<"SELinux is not present; SELinux-specific X controls are not applicable">>
                )
            ];
        {error, Reason} ->
            [warn(mac, fmt("Cannot inspect SELinux enforcement state: ~p", [Reason]))]
    end.

%%%===================================================================
%%% Process discovery and /proc parsing
%%%===================================================================

find_x_servers() ->
    case file:list_dir("/proc") of
        {ok, Entries} ->
            [
                Proc
             || Name <- Entries,
                is_digits(Name),
                {ok, Proc} <- [read_proc(Name)],
                maps:get(kind, Proc, other) =/= other
            ];
        {error, _} ->
            []
    end.

read_proc(PidStr) ->
    Base = filename:join("/proc", PidStr),
    case file:read_file(filename:join(Base, "cmdline")) of
        {ok, Cmdline} ->
            Args = split_nul(Cmdline),
            Exe = read_link(filename:join(Base, "exe")),
            Comm = read_trimmed(filename:join(Base, "comm")),
            Kind = classify_x_server(Args, Exe, Comm),
            case Kind of
                other ->
                    {ok, #{kind => other}};
                _ ->
                    Status = read_trimmed(filename:join(Base, "status")),
                    Uid = status_uid(Status),
                    {ok, #{
                        pid => list_to_integer(PidStr),
                        kind => Kind,
                        uid => Uid,
                        exe => Exe,
                        argv => Args,
                        display => find_display(Args),
                        auth => arg_value(Args, <<"-auth">>),
                        cap_eff => status_hex_field(Status, <<"CapEff">>),
                        no_new_privs => status_int_field(Status, <<"NoNewPrivs">>),
                        seccomp => status_int_field(Status, <<"Seccomp">>)
                    }}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

classify_x_server(Args, Exe, Comm) ->
    Names0 =
        [
            basename_bin(first_or(Args, <<>>)),
            basename_bin(to_bin_or_empty(Exe)),
            basename_bin(to_bin_or_empty(Comm))
        ],
    Names = [lower_bin(N) || N <- Names0],
    case lists:any(fun(N) -> N =:= <<"xorg">> orelse N =:= <<"xorg.bin">> end, Names) of
        true ->
            xorg;
        false ->
            case lists:any(fun(N) -> N =:= <<"xwayland">> end, Names) of
                true -> xwayland;
                false -> other
            end
    end.

select_processes(Processes, undefined) ->
    Processes;
select_processes(Processes, Display0) ->
    Display = normalize_display(Display0),
    [P || #{display := D} = P <- Processes, normalize_display(D) =:= Display].

public_process(Proc) ->
    maps:with([pid, kind, uid, exe, display, auth], Proc).

status_uid(undefined) ->
    undefined;
status_uid(Bin) ->
    case re:run(Bin, <<"(?m)^Uid:\\s+([0-9]+)">>, [{capture, [1], binary}]) of
        {match, [UidBin]} -> binary_to_integer(UidBin);
        nomatch -> undefined
    end.

status_hex_field(undefined, _Name) ->
    undefined;
status_hex_field(Bin, Name) ->
    Pat = iolist_to_binary([<<"(?m)^">>, Name, <<":\\s+([0-9A-Fa-f]+)">>]),
    case re:run(Bin, Pat, [{capture, [1], binary}]) of
        {match, [Hex]} ->
            case hex_to_int(Hex) of
                {ok, I} -> I;
                error -> undefined
            end;
        nomatch ->
            undefined
    end.

status_int_field(undefined, _Name) ->
    undefined;
status_int_field(Bin, Name) ->
    Pat = iolist_to_binary([<<"(?m)^">>, Name, <<":\\s+([0-9]+)">>]),
    case re:run(Bin, Pat, [{capture, [1], binary}]) of
        {match, [IntBin]} -> binary_to_integer(IntBin);
        nomatch -> undefined
    end.

find_display(Args) ->
    case [A || A <- Args, is_display_arg(A)] of
        [Display | _] -> normalize_display(Display);
        [] -> undefined
    end.

is_display_arg(<<$:, Rest/binary>>) ->
    re_match(Rest, <<"^[0-9]+(?:\\.[0-9]+)?$">>);
is_display_arg(_) ->
    false.

display_number(undefined) ->
    undefined;
display_number(Display0) ->
    Display = normalize_display(Display0),
    case re:run(Display, <<"^:([0-9]+)">>, [{capture, [1], binary}]) of
        {match, [N]} -> binary_to_integer(N);
        nomatch -> undefined
    end.

normalize_display(undefined) ->
    undefined;
normalize_display(Display0) ->
    Display = to_bin(Display0),
    case binary:split(Display, <<".">>, [global]) of
        [Base | _] -> Base;
        [] -> Display
    end.

authority_file(Proc, Context) ->
    case maps:get(xorg_authority, Context, undefined) of
        undefined -> maps:get(auth, Proc, undefined);
        Path -> to_bin(Path)
    end.

%%%===================================================================
%%% Socket inspection
%%%===================================================================

listening_tcp_ports(Pid) ->
    lists:usort(parse_inet_ports(Pid, "tcp", <<"0A">>) ++ parse_inet_ports(Pid, "tcp6", <<"0A">>)).

listening_udp_ports(Pid) ->
    %% UDP sockets in /proc generally show state 07 (UNCONN).  Treat any bound
    %% UDP/177 socket in the server's network namespace as exposure.
    lists:usort(parse_inet_ports(Pid, "udp", any) ++ parse_inet_ports(Pid, "udp6", any)).

parse_inet_ports(Pid, Kind, WantedState) ->
    Path = filename:join(["/proc", integer_to_list(Pid), "net", Kind]),
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = tl_safe(binary:split(Bin, <<"\n">>, [global])),
            lists:filtermap(fun(Line) -> parse_inet_line(Line, WantedState) end, Lines);
        {error, _} ->
            []
    end.

parse_inet_line(Line, WantedState) ->
    Fields = re:split(trim_bin(Line), <<"\\s+">>, [{return, binary}, trim]),
    case Fields of
        [_Slot, Local, _Remote, State | _] ->
            StateOk = (WantedState =:= any) orelse (State =:= WantedState),
            case {StateOk, binary:split(Local, <<":">>, [global])} of
                {true, [_Addr, PortHex]} ->
                    case hex_to_int(PortHex) of
                        {ok, Port} -> {true, Port};
                        error -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.

unix_socket_names(Pid) ->
    Path = filename:join(["/proc", integer_to_list(Pid), "net", "unix"]),
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = tl_safe(binary:split(Bin, <<"\n">>, [global])),
            lists:filtermap(fun unix_socket_name/1, Lines);
        {error, _} ->
            []
    end.

unix_socket_name(Line0) ->
    Line = trim_bin(Line0),
    Fields = re:split(Line, <<"\\s+">>, [{return, binary}, trim]),
    case Fields of
        [_Num, _Ref, _Protocol, _Flags, _Type, _State, _Inode, Path | _] -> {true, Path};
        _ -> false
    end.

%%%===================================================================
%%% Xorg configuration/path inspection
%%%===================================================================

default_config_paths() ->
    [
        "/etc/X11/xorg.conf",
        "/etc/X11/xorg.conf.d",
        "/etc/xorg.conf",
        "/usr/share/X11/xorg.conf.d",
        "/usr/lib/xorg/modules",
        "/usr/lib64/xorg/modules"
    ].

arg_paths(Processes) ->
    lists:append([
        [
            to_list(V)
         || K <- [<<"-config">>, <<"-configdir">>, <<"-modulepath">>, <<"-xkbdir">>],
            V <- maybe_value(maps:get(argv, P, []), K),
            filename:pathtype(to_list(V)) =:= absolute
        ]
     || P <- Processes
    ]).

maybe_value(Args, Key) ->
    case arg_value(Args, Key) of
        undefined -> [];
        V -> [V]
    end.

read_config_tree(Path) ->
    case filelib:is_dir(Path) of
        true ->
            Files = filelib:wildcard(filename:join(Path, "*.conf")),
            [read_config_file(F) || F <- Files];
        false ->
            read_config_file(Path)
    end.

read_config_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> strip_comments(Bin);
        {error, _} -> <<>>
    end.

strip_comments(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    iolist_to_binary([strip_comment_line(L) || L <- Lines]).

strip_comment_line(Line) ->
    case binary:split(Line, <<"#">>) of
        [Head | _] -> [Head, <<"\n">>];
        _ -> [Line, <<"\n">>]
    end.

bool_option_findings(Lower, Specs) ->
    [err(Check, Msg) || {Name, Check, Msg} <- Specs, option_bool(Lower, Name) =:= true].

option_bool(Content, Name) ->
    Pat = iolist_to_binary([
        <<"(?im)^\\s*option\\s+\\\"">>,
        Name,
        <<"\\\"\\s+\\\"?(true|yes|on|1)\\\"?\\s*$">>
    ]),
    case re:run(Content, Pat, [{capture, none}]) of
        match ->
            true;
        nomatch ->
            PatFalse = iolist_to_binary([
                <<"(?im)^\\s*option\\s+\\\"">>,
                Name,
                <<"\\\"\\s+\\\"?(false|no|off|0)\\\"?\\s*$">>
            ]),
            case re:run(Content, PatFalse, [{capture, none}]) of
                match -> false;
                nomatch -> undefined
            end
    end.

config_byteswap_disabled() ->
    Content = iolist_to_binary([read_config_tree(P) || P <- default_config_paths()]),
    option_bool(lower_bin(Content), <<"allowbyteswappedclients">>) =:= false.

audit_tree_permissions(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            [err(paths, fmt("Security-sensitive Xorg path ~s is a symlink", [Path]))];
        {ok, #file_info{uid = Uid, mode = Mode, type = Type}} ->
            BaseErrors = path_meta_errors(Path, Uid, Mode),
            case Type of
                directory ->
                    Children =
                        case file:list_dir(Path) of
                            {ok, Names} -> [filename:join(Path, N) || N <- Names];
                            {error, _} -> []
                        end,
                    BaseErrors ++
                        lists:append([audit_tree_permissions(C) || C <- Children, relevant_path(C)]);
                _ ->
                    BaseErrors
            end;
        {error, Reason} ->
            [err(paths, fmt("Cannot inspect security-sensitive Xorg path ~s: ~p", [Path, Reason]))]
    end.

path_meta_errors(Path, Uid, Mode) ->
    E0 =
        case Uid =:= 0 of
            true -> [];
            false -> [err(paths, fmt("Xorg path ~s is owned by uid ~B, not root", [Path, Uid]))]
        end,
    case (Mode band 8#0022) =/= 0 of
        true ->
            [
                err(
                    paths,
                    fmt("Xorg path ~s is group/world writable (mode ~.8B)", [
                        Path, Mode band 8#07777
                    ])
                )
                | E0
            ];
        false ->
            E0
    end.

relevant_path(Path) ->
    Base = filename:basename(Path),
    not lists:member(Base, [".cache", "__pycache__"]).

secure_system_file(Path, require_root) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            {error, symlink};
        {ok, #file_info{type = regular, uid = 0, mode = Mode} = Info} when
            (Mode band 8#0022) =:= 0
        ->
            {ok, Info};
        {ok, #file_info{type = regular, uid = Uid, mode = Mode}} ->
            {error, {unsafe_owner_or_mode, Uid, Mode band 8#07777}};
        {ok, #file_info{type = Type}} ->
            {error, {unexpected_type, Type}};
        Error ->
            Error
    end.

%%%===================================================================
%%% External command helpers (erlexec argv mode; no shell)
%%%===================================================================

read_x_version(Exe0) ->
    Exe = to_list(Exe0),
    case secure_system_file(Exe, require_root) of
        {ok, #file_info{mode = Mode}} when (Mode band 8#0022) =:= 0 ->
            case run_exec([Exe, "-version"], []) of
                {ok, Out, Err} ->
                    parse_version_output(<<Out/binary, "\n", Err/binary>>);
                {error, _Why, Out, Err} ->
                    %% Xorg commonly exits non-zero after printing -version; parse output anyway.
                    parse_version_output(<<Out/binary, "\n", Err/binary>>)
            end;
        {ok, _} ->
            {error, executable_writable_by_non_root};
        Error ->
            Error
    end.

parse_version_output(Bin) ->
    Patterns = [
        <<"X.Org X Server[[:space:]]+([0-9]+)\\.([0-9]+)\\.([0-9]+)">>,
        <<"Xwayland[[:space:]]+([0-9]+)\\.([0-9]+)\\.([0-9]+)">>,
        <<"Xwayland version:[[:space:]]*([0-9]+)\\.([0-9]+)\\.([0-9]+)">>
    ],
    parse_version_patterns(Bin, Patterns).

parse_version_patterns(_Bin, []) ->
    {error, version_not_found};
parse_version_patterns(Bin, [Pat | Rest]) ->
    case re:run(Bin, Pat, [{capture, [1, 2, 3], binary}, caseless]) of
        {match, [A, B, C]} ->
            {ok, {binary_to_integer(A), binary_to_integer(B), binary_to_integer(C)}, Bin};
        nomatch ->
            parse_version_patterns(Bin, Rest)
    end.

run_exec([Exe | _] = Cmd, Env) ->
    case filelib:is_regular(Exe) of
        false ->
            {error, enoent, <<>>, <<>>};
        true ->
            Opts0 = [sync, stdout, stderr],
            Opts =
                case Env of
                    [] -> Opts0;
                    _ -> Opts0 ++ [{env, Env}]
                end,
            try exec:run(Cmd, Opts) of
                {ok, Result} ->
                    {ok, result_stream(stdout, Result), result_stream(stderr, Result)};
                {error, Result} when is_list(Result) ->
                    {error, exit_status(Result), result_stream(stdout, Result),
                        result_stream(stderr, Result)};
                Other ->
                    {error, {unexpected_exec_result, Other}, <<>>, <<>>}
            catch
                Class:Reason ->
                    {error, {exec_exception, Class, Reason}, <<>>, <<>>}
            end
    end.

result_stream(Key, Result) ->
    case lists:keyfind(Key, 1, Result) of
        {Key, Parts} when is_list(Parts) -> iolist_to_binary(Parts);
        {Key, Bin} when is_binary(Bin) -> Bin;
        false -> <<>>
    end.

exit_status(Result) ->
    case lists:keyfind(exit_status, 1, Result) of
        {exit_status, Status} -> {exit_status, Status};
        false -> exec_failed
    end.

display_env(Display0, Auth0) ->
    [
        {"DISPLAY", to_list(Display0)},
        {"XAUTHORITY", to_list(Auth0)}
    ].

first_executable([Path | Rest]) ->
    case secure_system_file(Path, require_root) of
        {ok, _} -> Path;
        _ -> first_executable(Rest)
    end;
first_executable([]) ->
    undefined.

%%%===================================================================
%%% Argument and ACL helpers
%%%===================================================================

has_arg(Args, Arg) -> lists:member(Arg, Args).

has_any_arg(Args, Needles) -> lists:any(fun(N) -> has_arg(Args, N) end, Needles).

has_arg_pair([A, B | _], A, B) -> true;
has_arg_pair([_ | Rest], A, B) -> has_arg_pair(Rest, A, B);
has_arg_pair([], _A, _B) -> false.

has_listen_inet(Args) ->
    has_arg_pair(Args, <<"-listen">>, <<"tcp">>) orelse
        has_arg_pair(Args, <<"-listen">>, <<"inet">>) orelse
        has_arg_pair(Args, <<"-listen">>, <<"inet6">>).

arg_value([Key, Value | _], Key) -> Value;
arg_value([_ | Rest], Key) -> arg_value(Rest, Key);
arg_value([], _Key) -> undefined.

is_xhost_acl_entry(<<>>) ->
    false;
is_xhost_acl_entry(Line0) ->
    Line = lower_bin(Line0),
    not (binary:match(Line, <<"access control enabled">>) =/= nomatch orelse
        binary:match(Line, <<"access control disabled">>) =/= nomatch).

is_broad_xhost_entry(Line0) ->
    Line = lower_bin(trim_bin(Line0)),
    case Line of
        <<"local:">> ->
            true;
        <<"+">> ->
            true;
        <<"inet:", _/binary>> ->
            true;
        <<"inet6:", _/binary>> ->
            true;
        _ ->
            %% SI:localuser:<name> is scoped to a local OS identity and is
            %% allowed by this strict profile.  Any other unresolved entry is
            %% conservatively treated as broad.
            case Line of
                <<"si:localuser:", _/binary>> -> false;
                <<"localuser:", _/binary>> -> false;
                _ -> true
            end
    end.

extension_present(Out, Name) ->
    Pat = iolist_to_binary([<<"(?m)^\\s*">>, re_escape(Name), <<"\\s+">>]),
    re_match(Out, Pat) orelse binary:match(Out, <<Name/binary, " ">>) =/= nomatch.

re_escape(Bin) ->
    %% Extension names used here contain only alnum and '-'.
    Bin.

%%%===================================================================
%%% Version, formatting and generic helpers
%%%===================================================================

min_version(xorg) -> ?MIN_XORG;
min_version(xwayland) -> ?MIN_XWAYLAND.

version_at_least({A, B, C}, {MA, MB, MC}) ->
    {A, B, C} >= {MA, MB, MC}.

version_bin(V) -> to_bin(version_s(V)).
version_s({A, B, C}) -> lists:flatten(io_lib:format("~B.~B.~B", [A, B, C])).
kind_s(xorg) -> "Xorg";
kind_s(xwayland) -> "Xwayland";
kind_s(Other) -> atom_to_list(Other).

format_report(Audit) ->
    Processes = maps:get(processes, Audit, []),
    Findings = maps:get(findings, Audit, []),
    Errors = length(maps:get(errors, Audit, [])),
    Warnings = length(maps:get(warnings, Audit, [])),
    Header = io_lib:format(
        "DamageBDD Xorg strict security audit\nminimum Xorg=~s minimum Xwayland=~s processes=~B errors=~B warnings=~B\n",
        [
            maps:get(minimum_xorg, Audit),
            maps:get(minimum_xwayland, Audit),
            length(Processes),
            Errors,
            Warnings
        ]
    ),
    ProcLines = [io_lib:format("process: ~p\n", [P]) || P <- Processes],
    FindingLines = [format_finding(F) || F <- Findings],
    iolist_to_binary([Header, ProcLines, FindingLines]).

format_finding(#{severity := Severity, check := Check, message := Message}) ->
    io_lib:format("[~s] ~s: ~s\n", [
        string:uppercase(atom_to_list(Severity)), atom_to_list(Check), Message
    ]).

format_errors(Errors) ->
    iolist_to_binary([
        <<"Xorg strict security profile failed:\n">>,
        [
            io_lib:format(" - ~s: ~s\n", [atom_to_list(Check), Message])
         || #{check := Check, message := Message} <- Errors
        ]
    ]).

err(Check, Msg) -> #{severity => error, check => Check, message => to_bin(Msg)}.
warn(Check, Msg) -> #{severity => warning, check => Check, message => to_bin(Msg)}.
info(Check, Msg) -> #{severity => info, check => Check, message => to_bin(Msg)}.

fmt(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).

dedupe_findings(Findings) ->
    {_Seen, OutRev} = lists:foldl(
        fun(F, {Seen, Acc}) ->
            Key = {maps:get(severity, F), maps:get(check, F), maps:get(message, F)},
            case maps:is_key(Key, Seen) of
                true -> {Seen, Acc};
                false -> {Seen#{Key => true}, [F | Acc]}
            end
        end,
        {#{}, []},
        Findings
    ),
    lists:reverse(OutRev).

re_match(Bin, Pattern) ->
    case re:run(Bin, Pattern, [{capture, none}, caseless]) of
        match -> true;
        nomatch -> false
    end.

truncate(Bin0, Max) ->
    Bin = to_bin(Bin0),
    case byte_size(Bin) =< Max of
        true ->
            Bin;
        false ->
            <<Prefix:Max/binary, _/binary>> = Bin,
            <<Prefix/binary, "...">>
    end.

lower_bin(Bin0) ->
    list_to_binary(string:lowercase(binary_to_list(to_bin(Bin0)))).

basename_bin(<<>>) -> <<>>;
basename_bin(Bin) -> to_bin(filename:basename(to_list(Bin))).

split_nul(Bin) ->
    [Part || Part <- binary:split(Bin, <<0>>, [global]), Part =/= <<>>].

%% OTP-portable binary whitespace trim. binary:trim/3 is not an Erlang/OTP
%% binary API, so keep this local and avoid relying on string return types.
trim_bin(Bin) when is_binary(Bin) ->
    trim_bin_right(trim_bin_left(Bin));
trim_bin(Value) ->
    trim_bin(to_bin(Value)).

trim_bin_left(<<C, Rest/binary>>) when
    C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n
->
    trim_bin_left(Rest);
trim_bin_left(Bin) ->
    Bin.

trim_bin_right(<<>>) ->
    <<>>;
trim_bin_right(Bin) ->
    case binary:last(Bin) of
        C when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
            trim_bin_right(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ ->
            Bin
    end.

read_link(Path) ->
    case file:read_link(Path) of
        {ok, Value} -> Value;
        {error, _} -> undefined
    end.

read_trimmed(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> trim_bin(Bin);
        {error, _} -> undefined
    end.

is_digits([]) -> false;
is_digits(Str) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Str).

hex_to_int(Bin) ->
    try
        {ok, list_to_integer(binary_to_list(Bin), 16)}
    catch
        _:_ -> error
    end.

tl_safe([_ | Rest]) -> Rest;
tl_safe([]) -> [].

first_or([H | _], _Default) -> H;
first_or([], Default) -> Default.

to_bin_or_empty(undefined) -> <<>>;
to_bin_or_empty(V) -> to_bin(V).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(Other) -> binary_to_list(to_bin(Other)).
