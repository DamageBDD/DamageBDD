%%%-------------------------------------------------------------------
%%% DamageBDD parental-control steps for Arch Linux.
%%%
%%% Enforcement model:
%%%   * A dedicated Squid instance listens only on 127.0.0.1.
%%%   * Controlled Unix UIDs may use loopback but are denied every other
%%%     output interface by nftables.
%%%   * A conditional /etc/profile.d file advertises the proxy only to the
%%%     controlled users.
%%%
%%% This is deliberately fail-closed for the controlled users: an application
%%% that ignores the proxy environment cannot access the network directly.
%%%
%%% HTTPS is filtered by the hostname in the CONNECT request. This module does
%%% not install a TLS interception CA and does not perform TLS bumping.
%%%-------------------------------------------------------------------
-module(steps_parental_control).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6, step_dry/6]).

-import(steps_utils, [set_fail/3]).

-define(DEFAULT_PROXY_PORT, 3128).
-define(DEFAULT_MIN_UID, 1000).

-define(CONFIG_DIR, "/etc/damagebdd").
-define(SQUID_CONFIG, "/etc/damagebdd/parental-squid.conf").
-define(BLOCK_FILE, "/etc/damagebdd/parental-block.txt").
-define(ALLOW_FILE, "/etc/damagebdd/parental-allow.txt").
-define(USERS_FILE, "/etc/damagebdd/parental-users.txt").
-define(NFT_FILE, "/etc/damagebdd/parental-control.nft").
-define(PROXY_ENV_FILE, "/etc/profile.d/damage-parental-proxy.sh").
-define(SYSTEMD_UNIT, "/etc/systemd/system/damage-parental-control.service").
-define(SERVICE, "damage-parental-control.service").

%% ------------------------------------------------------------------
%% Runtime step patterns
%% ------------------------------------------------------------------

-define(S_USER, [
    "I manage parental controls for user", User
]).

-define(S_PORT, [
    "the parental proxy port is", Port
]).

-define(S_POLICY, [
    "the parental control policy is", Policy
]).

-define(S_BLOCK_DOMAIN, [
    "I block parental domain", Domain
]).

-define(S_ALLOW_DOMAIN, [
    "I allow parental domain", Domain
]).

-define(S_APPLY, [
    "I apply the parental controls"
]).

-define(S_REMOVE, [
    "I remove the parental controls"
]).

-define(S_ACTIVE, [
    "the parental controls should be active"
]).

-define(S_PROXY_ONLY, [
    "user", User, "internet access should be proxy only"
]).

-define(S_DOMAIN_BLOCKED, [
    "parental domain", Domain, "should be blocked"
]).

-define(S_DOMAIN_ALLOWED, [
    "parental domain", Domain, "should be allowed"
]).

%% ------------------------------------------------------------------
%% Dry-run matching
%%
%% Keep every clause explicit. The underscore-prefixed argument bindings fix
%% the compiler warnings caused by expanding the runtime macros here, while
%% retaining parameterised matching and avoiding a catch-all step_dry/6.
%% ------------------------------------------------------------------

step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["I manage parental controls for user", _User] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["the parental proxy port is", _Port] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["the parental control policy is", _Policy] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["I block parental domain", _Domain] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["I allow parental domain", _Domain] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["I apply the parental controls"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["I remove the parental controls"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["the parental controls should be active"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["user", _User, "internet access should be proxy only"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["parental domain", _Domain, "should be blocked"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    ["parental domain", _Domain, "should be allowed"] = Parts,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Parts).

%% ------------------------------------------------------------------
%% Context setup
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_USER, _Body) ->
    case normalize_username(User) of
        {ok, Username} ->
            Users0 = maps:get(parental_users, Context, []),
            Context#{parental_users => lists:usort([Username | Users0])};
        {error, Why} ->
            set_fail(Context, "Invalid parental-control username ~p: ~p", [User, Why])
    end;
step(_Config, Context, _Keyword, _N, ?S_PORT, _Body) ->
    case parse_port(Port) of
        {ok, PortInt} ->
            Context#{parental_proxy_port => PortInt};
        {error, Why} ->
            set_fail(Context, "Invalid parental proxy port ~p: ~p", [Port, Why])
    end;
step(_Config, Context, _Keyword, _N, ?S_POLICY, _Body) ->
    case normalize_policy(Policy) of
        {ok, PolicyAtom} ->
            Context#{parental_policy => PolicyAtom};
        {error, Why} ->
            set_fail(
                Context,
                "Parental policy must be blocklist or allowlist, got ~p: ~p",
                [Policy, Why]
            )
    end;
step(_Config, Context, _Keyword, _N, ?S_BLOCK_DOMAIN, _Body) ->
    add_domain(parental_block_domains, Domain, Context);
step(_Config, Context, _Keyword, _N, ?S_ALLOW_DOMAIN, _Body) ->
    add_domain(parental_allow_domains, Domain, Context);
%% ------------------------------------------------------------------
%% Mutations
%% ------------------------------------------------------------------

step(_Config, Context0, _Keyword, _N, ?S_APPLY, _Body) ->
    case ensure_admin(Context0) of
        ok ->
            apply_parental_controls(Context0);
        {error, not_admin} ->
            set_fail(Context0, "Admin privileges required to apply parental controls", [])
    end;
step(_Config, Context0, _Keyword, _N, ?S_REMOVE, _Body) ->
    case ensure_admin(Context0) of
        ok ->
            remove_parental_controls(Context0);
        {error, not_admin} ->
            set_fail(Context0, "Admin privileges required to remove parental controls", [])
    end;
%% ------------------------------------------------------------------
%% Assertions
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_ACTIVE, _Body) ->
    Port = maps:get(parental_proxy_port, Context, ?DEFAULT_PROXY_PORT),
    Listener = "127.0.0.1:" ++ integer_to_list(Port),
    Command =
        "/usr/bin/systemctl is-active --quiet " ++ ?SERVICE ++
            " && /usr/bin/nft list table inet damage_parental >/dev/null" ++
            " && /usr/bin/ss -H -ltn" ++
            " | /usr/bin/grep -F -- " ++ shell_quote(Listener),
    case run_ok(Context, Command) of
        ok ->
            Context;
        {error, Why} ->
            set_fail(
                Context,
                "Parental-control service, proxy listener, or nftables policy is inactive: ~p",
                [Why]
            )
    end;
step(_Config, Context, _Keyword, _N, ?S_PROXY_ONLY, _Body) ->
    case uid_for_user(Context, User) of
        {ok, Uid} ->
            Port = maps:get(parental_proxy_port, Context, ?DEFAULT_PROXY_PORT),
            UidText = integer_to_list(Uid),
            AcceptNeedle =
                "meta skuid " ++ UidText ++
                    " oifname \"lo\" tcp dport " ++ integer_to_list(Port) ++ " accept",
            RejectNeedle = "meta skuid " ++ UidText ++ " reject",
            Rules = "/usr/bin/nft -n list chain inet damage_parental output 2>/dev/null",
            Command =
                Rules ++ " | /usr/bin/grep -F -- " ++ shell_quote(AcceptNeedle) ++
                    " >/dev/null && " ++
                    Rules ++ " | /usr/bin/grep -F -- " ++ shell_quote(RejectNeedle) ++
                    " >/dev/null",
            case run_ok(Context, Command) of
                ok ->
                    Context;
                {error, Why} ->
                    set_fail(
                        Context,
                        "User ~p is not restricted to local proxy port ~p: ~p",
                        [User, Port, Why]
                    )
            end;
        {error, Why} ->
            set_fail(Context, "Cannot resolve controlled user ~p: ~p", [User, Why])
    end;
step(_Config, Context, _Keyword, _N, ?S_DOMAIN_BLOCKED, _Body) ->
    assert_domain_in_file(Context, Domain, ?BLOCK_FILE);
step(_Config, Context, _Keyword, _N, ?S_DOMAIN_ALLOWED, _Body) ->
    assert_domain_in_file(Context, Domain, ?ALLOW_FILE).

%% ==================================================================
%% Apply/remove orchestration
%% ==================================================================

apply_parental_controls(Context0) ->
    Users = maps:get(parental_users, Context0, []),
    Port = maps:get(parental_proxy_port, Context0, ?DEFAULT_PROXY_PORT),
    Policy = maps:get(parental_policy, Context0, blocklist),
    BlockDomains = maps:get(parental_block_domains, Context0, []),
    AllowDomains = maps:get(parental_allow_domains, Context0, []),

    case validate_apply_input(Users, Policy, AllowDomains) of
        ok ->
            case resolve_uids(Context0, Users) of
                {ok, UserUids} ->
                    Files = [
                        {?BLOCK_FILE, domain_file(BlockDomains), "0644"},
                        {?ALLOW_FILE, domain_file(AllowDomains), "0644"},
                        {?USERS_FILE, users_file(UserUids), "0644"},
                        {?SQUID_CONFIG, squid_policy(Port, Policy), "0644"},
                        {?NFT_FILE, nft_policy(UserUids, Port), "0644"},
                        {?PROXY_ENV_FILE, proxy_environment(Port, Users), "0644"},
                        {?SYSTEMD_UNIT, systemd_unit(), "0644"}
                    ],
                    case install_files(Context0, Files) of
                        ok ->
                            activate_parental_controls(
                                Context0#{
                                    parental_proxy_port => Port,
                                    parental_policy => Policy,
                                    parental_user_uids => UserUids
                                }
                            );
                        {error, Why} ->
                            set_fail(
                                Context0,
                                "Failed to install parental-control configuration: ~p",
                                [Why]
                            )
                    end;
                {error, Why} ->
                    set_fail(Context0, "Cannot resolve parental-control users: ~p", [Why])
            end;
        {error, Why} ->
            set_fail(Context0, "Invalid parental-control configuration: ~p", [Why])
    end.

validate_apply_input([], _Policy, _AllowDomains) ->
    {error, no_controlled_users};
validate_apply_input(_Users, allowlist, []) ->
    {error, empty_allowlist_would_block_all_web_access};
validate_apply_input(_Users, Policy, _AllowDomains) when
    Policy =:= blocklist; Policy =:= allowlist
->
    ok;
validate_apply_input(_Users, Policy, _AllowDomains) ->
    {error, {unsupported_policy, Policy}}.

activate_parental_controls(Context0) ->
    ValidationScript =
        lists:flatten([
            "set -e; ",
            "/usr/bin/test -x /usr/bin/squid; ",
            "/usr/bin/test -x /usr/bin/nft; ",
            "/usr/bin/test -x /usr/bin/ss; ",
            "/usr/bin/id -u proxy >/dev/null; ",
            "/usr/bin/squid -k parse -f ",
            shell_quote(?SQUID_CONFIG),
            "; ",
            "/usr/bin/nft -c -f ",
            shell_quote(?NFT_FILE),
            "; ",
            "/usr/bin/systemctl daemon-reload; ",
            "/usr/bin/systemctl enable ",
            ?SERVICE,
            "; ",
            "/usr/bin/systemctl restart ",
            ?SERVICE
        ]),

    case run_privileged_ok(Context0, ValidationScript) of
        ok ->
            Context0#{parental_controls_applied => true};
        {error, Why} ->
            set_fail(Context0, "Failed to activate parental controls: ~p", [Why])
    end.

remove_parental_controls(Context0) ->
    Script =
        lists:flatten([
            "set -e; ",
            "/usr/bin/systemctl disable --now ",
            ?SERVICE,
            " 2>/dev/null || true; ",
            "/usr/bin/nft delete table inet damage_parental 2>/dev/null || true; ",
            "/usr/bin/rm -f -- ",
            shell_quote(?SQUID_CONFIG),
            " ",
            shell_quote(?BLOCK_FILE),
            " ",
            shell_quote(?ALLOW_FILE),
            " ",
            shell_quote(?USERS_FILE),
            " ",
            shell_quote(?NFT_FILE),
            " ",
            shell_quote(?PROXY_ENV_FILE),
            " ",
            shell_quote(?SYSTEMD_UNIT),
            "; ",
            "/usr/bin/systemctl daemon-reload; ",
            "/usr/bin/systemctl reset-failed ",
            ?SERVICE,
            " 2>/dev/null || true"
        ]),

    case run_privileged_ok(Context0, Script) of
        ok ->
            maps:remove(parental_controls_applied, Context0);
        {error, Why} ->
            set_fail(Context0, "Failed to remove parental controls: ~p", [Why])
    end.

%% ==================================================================
%% Squid configuration
%% ==================================================================

squid_policy(Port, Policy) ->
    PolicyRules = squid_policy_rules(Policy),
    iolist_to_binary([
        "# Managed by DamageBDD - do not edit\n",
        "visible_hostname damage-parental\n",
        "http_port 127.0.0.1:",
        integer_to_list(Port),
        "\n",
        "pid_filename none\n",
        "cache_effective_user proxy\n",
        "coredump_dir /tmp\n",
        "access_log stdio:/dev/stdout\n",
        "cache_log /dev/stderr\n",
        "cache_store_log none\n",
        "logfile_rotate 0\n",
        "cache deny all\n",
        "shutdown_lifetime 1 seconds\n",
        "forwarded_for delete\n",
        "\n",
        "acl damage_local src 127.0.0.1/32 ::1\n",
        "acl SSL_ports port 443\n",
        "acl Safe_ports port 80\n",
        "acl Safe_ports port 443\n",
        "acl CONNECT method CONNECT\n",
        "acl manager proto cache_object\n",
        "acl damage_ip_literal dstdom_regex -n ",
        "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$\n",
        "acl damage_ip_literal dstdom_regex -n ^[0-9A-Fa-f]*:[0-9A-Fa-f:]+$\n",
        "\n",
        "http_access deny manager\n",
        "http_access deny damage_ip_literal\n",
        "http_access deny !damage_local\n",
        "http_access deny !Safe_ports\n",
        "http_access deny CONNECT !SSL_ports\n",
        PolicyRules,
        "http_access deny all\n"
    ]).

squid_policy_rules(blocklist) ->
    [
        "acl damage_parental_block dstdomain \"",
        ?BLOCK_FILE,
        "\"\n",
        "http_access deny damage_parental_block\n",
        "http_access allow damage_local\n"
    ];
squid_policy_rules(allowlist) ->
    [
        "acl damage_parental_allow dstdomain \"",
        ?ALLOW_FILE,
        "\"\n",
        "http_access allow damage_local damage_parental_allow\n"
    ].

domain_file(Domains) ->
    iolist_to_binary([
        [normalize_squid_domain(Domain), "\n"]
     || Domain <- lists:usort(Domains)
    ]).

normalize_squid_domain(Domain0) ->
    Domain = normalize_domain(Domain0),
    <<".", Domain/binary>>.

%% ==================================================================
%% nftables configuration
%% ==================================================================

nft_policy(UserUids, Port) ->
    Rules =
        lists:flatmap(
            fun({_User, Uid}) ->
                [
                    io_lib:format(
                        "        meta skuid ~B oifname \"lo\" tcp dport ~B accept " ++
                            "comment \"DamageBDD parental proxy endpoint\"~n",
                        [Uid, Port]
                    ),
                    io_lib:format(
                        "        meta skuid ~B reject " ++
                            "comment \"DamageBDD parental proxy only\"~n",
                        [Uid]
                    )
                ]
            end,
            UserUids
        ),
    iolist_to_binary([
        "# Managed by DamageBDD\n",
        "add table inet damage_parental\n",
        "add chain inet damage_parental output { ",
        "type filter hook output priority filter; policy accept; }\n",
        "flush chain inet damage_parental output\n",
        [
            [
                "add rule inet damage_parental output ",
                string:trim(lists:flatten(Rule), leading)
            ]
         || Rule <- Rules
        ]
    ]).

%% ==================================================================
%% systemd and user proxy environment
%% ==================================================================

systemd_unit() ->
    iolist_to_binary([
        "[Unit]\n",
        "Description=DamageBDD parental-control proxy and network enforcement\n",
        "After=network-online.target\n",
        "Wants=network-online.target\n",
        "\n",
        "[Service]\n",
        "Type=simple\n",
        "ExecStartPre=/usr/bin/test -x /usr/bin/squid\n",
        "ExecStartPre=/usr/bin/test -x /usr/bin/nft\n",
        "ExecStartPre=/usr/bin/nft -f /etc/damagebdd/parental-control.nft\n",
        "ExecStart=/usr/bin/squid -N -f /etc/damagebdd/parental-squid.conf\n",
        "# Keep nftables loaded if Squid exits; explicit removal is handled by DamageBDD.\n",
        "Restart=on-failure\n",
        "RestartSec=2\n",
        "TimeoutStartSec=30\n",
        "TimeoutStopSec=15\n",
        "\n",
        "[Install]\n",
        "WantedBy=multi-user.target\n"
    ]).

proxy_environment(Port, Users0) ->
    Users = [to_list(User) || User <- Users0],
    UserPattern = string:join(Users, "|"),
    Proxy = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/",
    iolist_to_binary([
        "# Managed by DamageBDD\n",
        "# A new login session is required after this file changes.\n",
        "case \"${USER:-${LOGNAME:-}}\" in\n",
        "    ",
        UserPattern,
        ")\n",
        "        export http_proxy=",
        shell_quote(Proxy),
        "\n",
        "        export https_proxy=",
        shell_quote(Proxy),
        "\n",
        "        export ftp_proxy=",
        shell_quote(Proxy),
        "\n",
        "        export HTTP_PROXY=",
        shell_quote(Proxy),
        "\n",
        "        export HTTPS_PROXY=",
        shell_quote(Proxy),
        "\n",
        "        export FTP_PROXY=",
        shell_quote(Proxy),
        "\n",
        "        export no_proxy='localhost,127.0.0.1,::1'\n",
        "        export NO_PROXY='localhost,127.0.0.1,::1'\n",
        "        ;;\n",
        "esac\n"
    ]).

users_file(UserUids) ->
    iolist_to_binary([
        io_lib:format("~s:~B~n", [User, Uid])
     || {User, Uid} <- UserUids
    ]).

%% ==================================================================
%% File installation
%% ==================================================================

install_files(Context, Files) ->
    case
        run_privileged_ok(
            Context,
            "/usr/bin/install -d -m 0755 -- " ++ shell_quote(?CONFIG_DIR)
        )
    of
        ok ->
            install_files0(Context, Files);
        {error, Why} ->
            {error, {create_config_dir_failed, Why}}
    end.

install_files0(_Context, []) ->
    ok;
install_files0(Context, [{Destination, Data, Mode} | Rest]) ->
    case write_secure_temp(Data) of
        {ok, Tmp} ->
            Script =
                "/usr/bin/install -m " ++ Mode ++ " -- " ++
                    shell_quote(Tmp) ++ " " ++ shell_quote(Destination),
            Result = run_privileged_ok(Context, Script),
            _ = file:delete(Tmp),
            case Result of
                ok ->
                    install_files0(Context, Rest);
                {error, Why} ->
                    {error, {install_failed, Destination, Why}}
            end;
        {error, Why} ->
            {error, {temp_write_failed, Destination, Why}}
    end.

write_secure_temp(Data) ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Tmp = filename:join("/tmp", "damage-parental-" ++ Suffix),
    case file:open(Tmp, [write, exclusive, binary, raw]) of
        {ok, IoDevice} ->
            Result = file:write(IoDevice, Data),
            CloseResult = file:close(IoDevice),
            case {Result, CloseResult} of
                {ok, ok} ->
                    {ok, Tmp};
                {{error, Why}, _} ->
                    _ = file:delete(Tmp),
                    {error, Why};
                {ok, {error, Why}} ->
                    _ = file:delete(Tmp),
                    {error, Why}
            end;
        {error, Why} ->
            {error, Why}
    end.

%% ==================================================================
%% Assertions and user resolution
%% ==================================================================

assert_domain_in_file(Context, Domain0, File) ->
    case valid_domain(Domain0) of
        true ->
            Domain = binary_to_list(normalize_squid_domain(Domain0)),
            Command =
                "/usr/bin/grep -Fx -- " ++ shell_quote(Domain) ++ " " ++ shell_quote(File),
            case run_ok(Context, Command) of
                ok ->
                    Context;
                {error, Why} ->
                    set_fail(
                        Context,
                        "Domain ~p is not present in ~p: ~p",
                        [Domain0, File, Why]
                    )
            end;
        false ->
            set_fail(Context, "Invalid parental-control domain ~p", [Domain0])
    end.

add_domain(Key, Domain0, Context) ->
    case valid_domain(Domain0) of
        true ->
            Domain = binary_to_list(normalize_domain(Domain0)),
            Domains0 = maps:get(Key, Context, []),
            Context#{Key => lists:usort([Domain | Domains0])};
        false ->
            set_fail(Context, "Invalid parental-control domain ~p", [Domain0])
    end.

resolve_uids(Context, Users) ->
    resolve_uids(Context, Users, []).

resolve_uids(_Context, [], Acc) ->
    {ok, lists:reverse(Acc)};
resolve_uids(Context, [User | Rest], Acc) ->
    case uid_for_user(Context, User) of
        {ok, Uid} ->
            resolve_uids(Context, Rest, [{User, Uid} | Acc]);
        {error, Why} ->
            {error, {User, Why}}
    end.

uid_for_user(Context, User0) ->
    case normalize_username(User0) of
        {ok, User} ->
            Result = run(Context, "/usr/bin/id -u -- " ++ shell_quote(User)),
            case exec_success(Result) of
                true ->
                    case command_stdout(Result) of
                        undefined ->
                            {error, {no_uid_output, Result}};
                        Out ->
                            parse_controlled_uid(User, Out)
                    end;
                false ->
                    {error, {id_failed, Result}}
            end;
        {error, Why} ->
            {error, Why}
    end.

parse_controlled_uid(User, Out) ->
    Text = string:trim(binary_to_list(Out)),
    try
        Uid = list_to_integer(Text),
        MinUid = min_controlled_uid(),
        RunnerUid = current_uid(),
        ProxyUid = proxy_uid(),
        case Uid of
            _ when Uid < MinUid ->
                {error, {protected_system_uid, User, Uid, minimum_uid, MinUid}};
            RunnerUid when is_integer(RunnerUid) ->
                {error, {refusing_damagebdd_runner_uid, User, Uid}};
            ProxyUid when is_integer(ProxyUid) ->
                {error, {refusing_squid_proxy_uid, User, Uid}};
            _ ->
                {ok, Uid}
        end
    catch
        _:_ ->
            {error, {invalid_uid, Out}}
    end.

current_uid() ->
    command_uid("/usr/bin/id -u").

proxy_uid() ->
    command_uid("/usr/bin/id -u proxy 2>/dev/null").

command_uid(Command) ->
    try
        list_to_integer(string:trim(os:cmd(Command)))
    catch
        _:_ -> undefined
    end.

min_controlled_uid() ->
    case application:get_env(damage, parental_control_min_uid) of
        {ok, Value} when is_integer(Value), Value >= 1 -> Value;
        {ok, Value} when is_binary(Value) -> parse_min_uid(Value);
        {ok, Value} when is_list(Value) -> parse_min_uid(Value);
        _ -> ?DEFAULT_MIN_UID
    end.

parse_min_uid(Value) ->
    try
        Parsed = list_to_integer(to_list(Value)),
        case Parsed >= 1 of
            true -> Parsed;
            false -> ?DEFAULT_MIN_UID
        end
    catch
        _:_ -> ?DEFAULT_MIN_UID
    end.

ensure_admin(Context) ->
    case steps_utils:is_admin(Context) of
        true -> ok;
        false -> {error, not_admin}
    end.

%% ==================================================================
%% Command execution
%% ==================================================================

run_privileged_ok(Context, Script) ->
    Command = privileged_shell_command(Context, Script),
    run_ok(Context, Command).

privileged_shell_command(Context, Script0) ->
    Script = to_list(Script0),
    ShellCommand = "/bin/sh -c " ++ shell_quote(Script),
    case needs_sudo(Context) of
        true -> "/usr/bin/sudo -n -- " ++ ShellCommand;
        false -> ShellCommand
    end.

needs_sudo(#{sudo := true}) ->
    true;
needs_sudo(#{sudo := false}) ->
    false;
needs_sudo(_) ->
    current_uid() =/= 0.

run_ok(Context, Command) ->
    Result = run(Context, Command),
    case exec_success(Result) of
        true -> ok;
        false -> {error, Result}
    end.

run(Context, Command0) ->
    Command = to_list(Command0),
    Cwd = filename:absname(maps:get(cmd_cwd, Context, "/tmp")),
    ?LOG_INFO("parental-control exec: ~s", [Command]),
    try
        exec:run(Command, [sync, stderr, stdout, {cd, Cwd}])
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(
                "parental-control command crashed class=~p reason=~p stack=~p command=~p",
                [Class, Reason, Stack, Command]
            ),
            {error, {exec_exception, Class, Reason}}
    end.

exec_success({ok, _Result}) -> true;
exec_success({ok, _Pid, _Result}) -> true;
exec_success(_) -> false.

command_stdout({ok, Result}) ->
    command_stdout(Result);
command_stdout({ok, _Pid, Result}) ->
    command_stdout(Result);
command_stdout(#{stdout := Out}) ->
    output_binary(Out);
command_stdout(Result) when is_list(Result) ->
    case lists:keyfind(stdout, 1, Result) of
        {stdout, Out} ->
            output_binary(Out);
        false ->
            case io_lib:printable_unicode_list(Result) of
                true -> output_binary(Result);
                false -> undefined
            end
    end;
command_stdout(Result) when is_binary(Result) ->
    Result;
command_stdout(_) ->
    undefined.

output_binary(Out) when is_binary(Out) ->
    Out;
output_binary(Out) when is_list(Out) ->
    try
        iolist_to_binary(Out)
    catch
        _:_ -> unicode:characters_to_binary(Out)
    end;
output_binary(Out) ->
    to_bin(Out).

%% ==================================================================
%% Validation and conversion helpers
%% ==================================================================

normalize_username(User0) ->
    User = to_bin(User0),
    case re:run(User, <<"^[a-z_][a-z0-9_-]{0,31}$">>, [{capture, none}]) of
        match -> {ok, binary_to_list(User)};
        nomatch -> {error, invalid_username_syntax}
    end.

normalize_policy(Policy0) ->
    Policy = lower_ascii(to_bin(Policy0)),
    case Policy of
        <<"blocklist">> -> {ok, blocklist};
        <<"allowlist">> -> {ok, allowlist};
        _ -> {error, unsupported_policy}
    end.

parse_port(Port) when is_integer(Port), Port > 0, Port < 65536 ->
    {ok, Port};
parse_port(Port) when is_binary(Port); is_list(Port) ->
    try
        parse_port(list_to_integer(string:trim(to_list(Port))))
    catch
        _:_ -> {error, invalid_integer}
    end;
parse_port(_) ->
    {error, invalid_type}.

valid_domain(Domain0) ->
    Domain = normalize_domain(Domain0),
    Size = byte_size(Domain),
    Size > 0 andalso Size =< 253 andalso
        valid_domain_labels(binary:split(Domain, <<".">>, [global])).

valid_domain_labels([]) ->
    false;
valid_domain_labels(Labels) ->
    lists:all(fun valid_domain_label/1, Labels).

valid_domain_label(Label) ->
    Size = byte_size(Label),
    Size > 0 andalso
        Size =< 63 andalso
        re:run(
            Label,
            <<"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$">>,
            [{capture, none}]
        ) =:= match.

normalize_domain(Domain0) ->
    Domain1 = lower_ascii(to_bin(Domain0)),
    trim_trailing_dot(trim_leading_dot(Domain1)).

trim_leading_dot(<<".", Rest/binary>>) ->
    trim_leading_dot(Rest);
trim_leading_dot(Bin) ->
    Bin.

trim_trailing_dot(<<>>) ->
    <<>>;
trim_trailing_dot(Bin) ->
    case binary:last(Bin) of
        $. -> trim_trailing_dot(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

lower_ascii(Bin) when is_binary(Bin) ->
    <<<<(lower_char(C))>> || <<C>> <= Bin>>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

shell_quote(Value0) ->
    Value = to_list(Value0),
    "'" ++
        lists:flatten([
            case C of
                $' -> "'\\''";
                _ -> [C]
            end
         || C <- Value
        ]) ++
        "'".

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I);
to_list(Other) -> binary_to_list(to_bin(Other)).
